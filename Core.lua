local ADDON, FL = ...
_G.Freeloader = FL

-- Freeloader -- which addon isn't paying its way.
--
-- The client does all the measuring; this addon is a sampler and a table. Two
-- numbers matter and neither is the one people quote at each other:
--
--   * ms/frame. An addon burning 2 ms every frame is eating 12% of the 16.7 ms
--     you have at 60 fps. This is the number that becomes a framerate drop.
--   * KB/s allocated. Absolute memory is close to meaningless -- an addon
--     sitting on 8 MB costs nothing to sit there. Allocation RATE is what
--     drives the garbage collector, and the collector is what stutters.
--
-- Everything here reads cumulative counters, so every displayed figure is a
-- delta over the sample window. Deliberately no libraries: a profiler that
-- drags a 30-file library folder into the client it is measuring has already
-- lost the argument.

-- The profiling API sits on globals in 2.5.5 and has been migrating into
-- C_AddOns on newer clients. Resolve each name once so the same file loads on
-- either; the trailing global is still visible here because a local is not in
-- scope until after its own statement.
local GetNumAddOns           = C_AddOns and C_AddOns.GetNumAddOns           or GetNumAddOns
local GetAddOnInfo           = C_AddOns and C_AddOns.GetAddOnInfo           or GetAddOnInfo
local GetAddOnCPUUsage       = C_AddOns and C_AddOns.GetAddOnCPUUsage       or GetAddOnCPUUsage
local GetAddOnMemoryUsage    = C_AddOns and C_AddOns.GetAddOnMemoryUsage    or GetAddOnMemoryUsage
local UpdateAddOnCPUUsage    = C_AddOns and C_AddOns.UpdateAddOnCPUUsage    or UpdateAddOnCPUUsage
local UpdateAddOnMemoryUsage = C_AddOns and C_AddOns.UpdateAddOnMemoryUsage or UpdateAddOnMemoryUsage
local ResetCPUUsage          = C_AddOns and C_AddOns.ResetCPUUsage          or ResetCPUUsage
local GetCVar                = C_CVar   and C_CVar.GetCVar                  or GetCVar
local SetCVar                = C_CVar   and C_CVar.SetCVar                  or SetCVar
local GetAddOnMetadata       = C_AddOns and C_AddOns.GetAddOnMetadata       or GetAddOnMetadata

-- Retail-engine clients, Forever included, also carry the addon profiler the
-- default AddOn list reads from. It is always running, so it needs no reload
-- and adds no script profiling cost. Absent on anniversary and Era, where
-- scriptProfile is the only CPU source there is.
local Profiler = C_AddOnProfiler
local METRIC   = Enum and Enum.AddOnProfilerMetric
FL.hasProfiler = (Profiler and Profiler.GetAddOnMetric and METRIC) and true or false

-- The profiler has no "worst frame lately", only running counts of frames an
-- addon spent over each of these. The highest one that climbed since the last
-- sample bounds that window's worst frame from below, which is the peak column.
-- Ascending, and only the ones this client actually has.
local SPIKE_BANDS = {}
if METRIC then
    for _, ms in ipairs({ 1, 5, 10, 50, 100, 500, 1000 }) do
        local metric = METRIC["CountTimeOver" .. ms .. "Ms"]
        if metric then SPIKE_BANDS[#SPIKE_BANDS + 1] = { ms = ms, metric = metric } end
    end
end
local NBANDS = #SPIKE_BANDS
FL.hasPeak = FL.hasProfiler and NBANDS > 0

-- How long a peak stays on screen. Independent of /free rate on purpose: a
-- spike is one frame, and at a 3 s refresh it would be gone before you found
-- the row. A bigger one replaces it at once; a smaller one waits this out.
FL.PEAK_HOLD = 10

-- The report's session count. 5 ms is 30% of a 60 fps frame from one addon,
-- which is a hitch you can feel.
FL.SPIKE_MS = 5
local SPIKE_METRIC = METRIC and METRIC.CountTimeOver5Ms

-- Floors are set by what the columns can actually PRINT, so a row survives
-- only if at least one of its three numbers renders as something other than
-- zero. Anything below all three would occupy a line to say "0.0  0.00  0",
-- which is a row of noise dressed as data. Keep these in step with the format
-- strings in UI.lua: %.1f%%, %.2f, %.0f.
local CPU_FLOOR   = 0.05   -- % of one core
local MSF_FLOOR   = 0.005  -- ms per frame
local CHURN_FLOOR = 0.5    -- KB/s
local MIN_RATE, MAX_RATE = 0.25, 10
local MIN_ROWS, MAX_ROWS = 3, 40

local defaults = {
    -- 3s rather than 1s: a one-second window is both hard to read and noisy,
    -- since a single GC pass or a stray event lands entirely inside it and
    -- throws the row to the top. Longer windows average that out.
    rate    = 3,      -- seconds between samples
    rows    = 12,
    locked  = false,
    shown   = false,
    point   = { "CENTER", "CENTER", 0, 0 },
    -- Off by default. The scan behind the KB/s column hitches hard enough to be
    -- worse than the problem it is describing, and it does not even bill itself
    -- to Freeloader -- see SetMemory below.
    memory  = false,
    -- Only read where FL.hasProfiler is true, so on by default means on by
    -- default for Forever and nowhere else.
    profiler = true,
}

-- UpdateAddOnMemoryUsage walks every addon's memory attribution and is by a
-- wide margin the most expensive call in this file -- enough on its own to
-- show as a hitch, which is not a cost a profiler gets to add. So memory runs
-- on its own slower cadence and the CPU columns keep the fast one.
local MEM_EVERY = 3   -- memory is sampled on every Nth tick

-- Index -> last reading. The addon list cannot change mid-session, so the
-- index is a stable key and no name lookup is needed to pair up samples.
local prevCPU, prevMem = {}, {}
-- Index -> KB/s, carried between memory samples so the column holds its last
-- real reading instead of blinking to zero on the ticks that skip the scan.
local churnRate = {}
-- Index -> reusable row table. A profiler that allocates a fresh table per
-- addon per second would show up in its own KB/s column, which is funny once.
local pool = {}
-- Index -> addon name, read once at load. The profiler is keyed by name where
-- the legacy getters take an index.
local names = {}
-- (index - 1) * NBANDS + band -> that band's count at the last sample.
local prevSpike = {}
-- Index -> the peak on show, in ms, and the GetTime() it was set.
local heldPeak, heldAt = {}, {}

local addonCount = 0
local frames, lastSample, baselined = 0, 0, false
local lastMem, ticksSinceMem, totalChurn = 0, 0, 0

FL.rows  = {}
FL.total = { cpu = 0, msf = 0, churn = 0, peak = 0, fps = 0, window = 0 }

-- Read at load, before anything can change it: the CVar reflects what the
-- NEXT session will do, and only this snapshot says whether the profiler is
-- actually running right now.
FL.profilingActive = (GetCVar("scriptProfile") == "1")

-- The client can switch its profiler off (addonProfilerEnabled), so this asks
-- every time rather than trusting the setting alone.
function FL:UsingProfiler()
    return self.hasProfiler and self.db.profiler and Profiler.IsEnabled() and true or false
end

-- Whether the CPU columns have a source at all, from either system.
function FL:CPUOn()
    return self:UsingProfiler() or self.profilingActive
end

function FL:Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff59d0ffFreeloader|r  " .. msg)
end

-- The same line without the name in front of it, for a block that has already
-- said whose it is. The menu prints one header and then its options, and
-- stamping every one of those buries the content behind the same word ten
-- times over.
function FL:PrintRaw(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage(select("#", ...) > 0 and fmt:format(...) or fmt)
end

----------------------------------------------------------------------
-- Sampling
----------------------------------------------------------------------

-- The highest band whose count rose since the last call, in ms, or 0. A frame
-- over 50 ms was also over 10, 5 and 1, so the bands can only rise from the
-- bottom up: the walk stops at the first that held still, and an addon with
-- no spikes at all costs one call. The baseline pass reads every band, since
-- the ones above a stop are otherwise never read until they first move.
local function WorstBand(i, baseline)
    local name, base, worst = names[i], (i - 1) * NBANDS, 0
    for b = 1, NBANDS do
        local n = Profiler.GetAddOnMetric(name, SPIKE_BANDS[b].metric) or 0
        local rose = n > (prevSpike[base + b] or n)
        prevSpike[base + b] = n
        if rose then
            worst = SPIKE_BANDS[b].ms
        elseif not baseline then
            break
        end
    end
    return worst
end

local function SortRows(a, b)
    -- Falls through to allocation rate when CPU ties, which is every row when
    -- script profiling is off. Keeps the list meaningful in that state instead
    -- of showing forty zeroes in load order.
    if a.pct == b.pct then return a.churn > b.churn end
    return a.pct > b.pct
end

-- Drop the baseline so the next tick starts a fresh window. Called whenever
-- the window opens: while hidden nothing samples, and a delta measured across
-- a ten minute gap is not a reading of anything.
function FL:Rebase()
    baselined, frames, lastSample = false, 0, 0
end

function FL:Sample()
    local now = GetTime()
    -- With profiling off every CPU getter returns zero, so the whole CPU half
    -- of this function is a walk over the addon list to collect nothing. The
    -- profiler reads averages rather than counters, so it needs no baseline
    -- and the legacy half stays off while it is in charge.
    local profiler = self:UsingProfiler()
    local profiling = not profiler and self.profilingActive

    local memory = self.db.memory

    if not baselined then
        if profiling then UpdateAddOnCPUUsage() end
        if memory then UpdateAddOnMemoryUsage() end
        local peaks = profiler and self.hasPeak
        wipe(heldPeak)
        wipe(heldAt)
        for i = 1, addonCount do
            prevCPU[i] = profiling and GetAddOnCPUUsage(i) or 0
            prevMem[i] = memory and GetAddOnMemoryUsage(i) or 0
            if peaks then WorstBand(i, true) end
        end
        wipe(churnRate)
        totalChurn, ticksSinceMem = 0, 0
        baselined, lastSample, lastMem, frames = true, now, now, 0
        return false
    end

    local window = now - lastSample
    ticksSinceMem = ticksSinceMem + 1
    local doMem = memory and ticksSinceMem >= MEM_EVERY
    local memWindow = now - lastMem

    if profiling then UpdateAddOnCPUUsage() end
    if doMem then UpdateAddOnMemoryUsage() end

    local rows, total = self.rows, self.total
    wipe(rows)
    total.cpu, total.msf, total.peak = 0, 0, 0
    local peaks = profiler and self.hasPeak
    total.window, total.frames = window, frames
    total.fps = frames / window

    local sumChurn = 0
    for i = 1, addonCount do
        local pct, msf, peak = 0, 0, 0
        if profiler then
            -- Already ms per frame, averaged over the profiler's own recent
            -- window rather than ours. Share of a core is that times our
            -- measured fps: ms per second, / 1000 * 100.
            msf = Profiler.GetAddOnMetric(names[i], METRIC.RecentAverageTime) or 0
            pct = msf * total.fps / 10
            total.cpu, total.msf = total.cpu + pct, total.msf + msf
            if peaks then
                peak = WorstBand(i)
                local held = heldPeak[i] or 0
                if peak >= held or now - heldAt[i] >= self.PEAK_HOLD then
                    heldPeak[i], heldAt[i] = peak, now
                else
                    peak = held
                end
                if peak > total.peak then total.peak = peak end
            end
        elseif profiling then
            local cpu = GetAddOnCPUUsage(i)
            local dcpu = cpu - (prevCPU[i] or cpu)
            prevCPU[i] = cpu
            -- ms over the window as a share of one core:
            -- dcpu / (window * 1000) * 100.
            pct = dcpu / (window * 10)
            msf = frames > 0 and dcpu / frames or 0
            total.cpu, total.msf = total.cpu + pct, total.msf + msf
        end

        if doMem then
            local mem = GetAddOnMemoryUsage(i)
            local dmem = mem - (prevMem[i] or mem)
            prevMem[i] = mem
            -- A negative delta means the collector ran, not that the addon
            -- handed memory back. Those allocations did happen, we just cannot
            -- see them any more -- floor at zero rather than report a negative.
            if dmem < 0 then dmem = 0 end
            churnRate[i] = dmem / memWindow
            sumChurn = sumChurn + churnRate[i]
        end

        local kbs = churnRate[i] or 0
        if pct >= CPU_FLOOR or msf >= MSF_FLOOR or kbs >= CHURN_FLOOR or peak > 0 then
            local r = pool[i]
            if not r then r = {}; pool[i] = r end
            r.name = names[i]
            r.pct, r.msf, r.churn, r.peak = pct, msf, kbs, peak
            rows[#rows + 1] = r
        end
    end

    if doMem then
        totalChurn, lastMem, ticksSinceMem = sumChurn, now, 0
    end
    total.churn = totalChurn

    table.sort(rows, SortRows)
    lastSample, frames = now, 0
    return true
end

-- Driven from the window's OnUpdate, which is also where the frame count comes
-- from. Hidden frames get no OnUpdate, so a closed window costs exactly zero.
function FL:Tick()
    frames = frames + 1
    if GetTime() - lastSample < self.db.rate then return false end
    return self:Sample()
end

----------------------------------------------------------------------
-- Cumulative report
----------------------------------------------------------------------

local function FormatDuration(seconds)
    if seconds < 90 then return ("%ds"):format(seconds) end
    return ("%dm%02ds"):format(seconds / 60, seconds % 60)
end

-- The live window answers "what is costing me right now". This answers the
-- other question -- "what has cost me the most all session" -- which is the
-- one you want after a raid, and the one you can paste into a chat channel.
function FL:Report(limit)
    -- With the profiler, cpu is its session average in ms/f; otherwise it is
    -- the legacy cumulative ms. Both rank the same way, only the print differs.
    local profiler = self:UsingProfiler()
    if not profiler and self.profilingActive then UpdateAddOnCPUUsage() end
    -- Respects the memory toggle rather than sneaking the expensive scan in
    -- behind a command that reads like it only prints what is already known.
    local memory = self.db.memory
    if memory then UpdateAddOnMemoryUsage() end

    local elapsed = math.max(GetTime() - self.since, 0.001)
    local list, sumCPU = {}, 0
    for i = 1, addonCount do
        local cpu
        if profiler then
            cpu = Profiler.GetAddOnMetric(names[i], METRIC.SessionAverageTime) or 0
        else
            cpu = self.profilingActive and GetAddOnCPUUsage(i) or 0
        end
        local mem = memory and GetAddOnMemoryUsage(i) or 0
        local spikes = profiler and SPIKE_METRIC and Profiler.GetAddOnMetric(names[i], SPIKE_METRIC) or 0
        sumCPU = sumCPU + cpu
        if cpu > 0 or mem > 16 then
            list[#list + 1] = { name = names[i], cpu = cpu, mem = mem, spikes = spikes }
        end
    end
    table.sort(list, function(a, b)
        if a.cpu == b.cpu then return a.mem > b.mem end
        return a.cpu > b.cpu
    end)

    -- The profiler's session cannot be reset from here, so its header names the
    -- session rather than our since-login-or-reset marker.
    if profiler then
        self:Print("Session averages from the addon profiler -- %d addons loaded, %.2f ms/f total.",
            addonCount, sumCPU)
    else
        self:Print("Since %s -- %s, %d addons loaded, %.1f%% of one core total.",
            self.sinceLabel, FormatDuration(elapsed), addonCount, sumCPU / (elapsed * 10))
        if not self.profilingActive then
            self:Print("|cffff6060Script profiling is off, so every CPU figure below is zero.|r")
        end
    end

    limit = math.min(limit or 10, #list)
    for i = 1, limit do
        local e = list[i]
        local mem = ""
        if memory then
            mem = e.mem >= 1024 and (", %.1f MB"):format(e.mem / 1024)
                                 or (", %.0f KB"):format(e.mem)
        end
        if profiler then
            local spikes = e.spikes > 0
                and (", |cffff6060%d spikes over %d ms|r"):format(e.spikes, self.SPIKE_MS) or ""
            self:Print("  %d. %s -- |cffffd000%.2f ms/f|r (%.0f%% of addon time)%s%s",
                i, e.name, e.cpu, sumCPU > 0 and e.cpu / sumCPU * 100 or 0, spikes, mem)
        else
            self:Print("  %d. %s -- |cffffd000%.0f ms|r (%.1f%%)%s",
                i, e.name, e.cpu, e.cpu / (elapsed * 10), mem)
        end
    end
    if #list > limit then
        self:Print("  |cff909090... and %d more. /free report %d for a longer list.|r", #list - limit, #list)
    end
end

-- Worth knowing before turning this on: UpdateAddOnMemoryUsage is a C call, so
-- the scan it performs is engine time, not script time. The profiler bills
-- addons for Lua, which means the hitch it causes lands on nobody's row --
-- Freeloader included. An addon that cannot account for its own cost has no
-- business running that cost by default.
function FL:SetMemory(on)
    self.db.memory = on and true or false
    wipe(churnRate)
    totalChurn = 0
    self:Rebase()
end

function FL:SetProfiler(on)
    self.db.profiler = on and true or false
    self:Rebase()
end

function FL:Reset()
    -- Only does anything with profiling on, and is harmless otherwise.
    ResetCPUUsage()
    wipe(prevCPU)
    wipe(prevMem)
    self.since, self.sinceLabel = GetTime(), "reset"
    self:Rebase()
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------

-- The CVar is set in OnAccept, not before the prompt: decline it and nothing
-- about the client has changed. An addon that is meant to cost nothing in the
-- background does not get to flip a client-wide switch on the way to asking.
StaticPopupDialogs["FREELOADER_RELOAD"] = {
    text = "",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        SetCVar("scriptProfile", FL.pendingProfile and "1" or "0")
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local ASK_ON = "The CPU columns need script profiling, and the client only starts it on a UI reload."
    .. "\n\nTurn it on and reload now?"
    .. "\n\nIt costs a few percent CPU for the rest of the session, so end it with /free toggle when you are done."
local ASK_OFF = "Script profiling only stops on a UI reload.\n\nReload now?"

local function AskProfiling(on)
    FL.pendingProfile = on
    StaticPopupDialogs["FREELOADER_RELOAD"].text = on and ASK_ON or ASK_OFF
    StaticPopup_Show("FREELOADER_RELOAD")
end

-- Asked when the window opens, because opening the window is the moment you
-- have said you want CPU numbers. Once per session: a prompt that returns every
-- time you open a monitor is a prompt you learn to dismiss without reading.
function FL:OfferProfiling()
    if self:CPUOn() or self.offered or not self.ready then return end
    self.offered = true
    AskProfiling(true)
end
-- TagTeam's palette for these, since the menu format is borrowed from /tag.
local ON, OFF = "|cff00ff00ON|r", "|cffff2020OFF|r"

-- The tail of the menu block, so these are unstamped and indented like the
-- option lines above them: the one-line answer to "is this thing on", which is
-- the part chat is still better at than the window.
local function Status()
    if FL:UsingProfiler() then
        -- Both on is the one state worth a nudge: the profiler already covers
        -- the CPU columns, so script profiling is pure cost.
        if FL.profilingActive then
            FL:PrintRaw("  |cffff8080script profiling is also on|r and no longer needed - "
                .. "|cffffff00/free toggle|r ends it.")
        end
    elseif FL.hasProfiler and not FL.profilingActive then
        FL:PrintRaw("  |cffff8080CPU is off|r - every CPU figure reads zero until "
            .. "|cffffff00/free profiler|r, which needs no reload.")
    elseif not FL.profilingActive then
        FL:PrintRaw("  |cffff8080script profiling is off|r - every CPU figure reads zero "
            .. "until |cffffff00/free toggle|r and a reload.")
    end
end

-- One block: a header that says whose it is, and no name stamped on any line
-- under it. Printed when /free OPENS the window, not when it closes one --
-- closing is not a moment anybody wants a wall of chat -- and on any input
-- that is not a command, typo or not.
--
-- No line for bare /free: you just typed it, and a menu whose first entry
-- explains the thing that printed it is a line nobody has ever needed.
--
-- Placeholders name the unit rather than saying <n> three times, because the
-- one thing a reader wants from an argument they have not used before is what
-- it is counted in.
local function Menu()
    FL:PrintRaw("|cff59d0ffFreeloader|r%s |cffffff00Options:|r",
        FL.version and (" |cff808080(v%s)|r"):format(FL.version) or "")
    if FL.hasProfiler then
        FL:PrintRaw("  |cffffff00/free profiler|r - Read CPU from the client's built-in addon "
            .. "profiler: always on, no reload. Currently %s", FL:UsingProfiler() and ON or OFF)
    end
    FL:PrintRaw("  |cffffff00/free toggle|r - Toggle Script profiling, the WoW setting that "
        .. "powers Freeloader. Currently %s", FL.profilingActive and ON or OFF)
    FL:PrintRaw("  |cffffff00/free memory|r - Track allocation rate, the KB/s column. Currently %s",
        FL.db.memory and ON or OFF)
    FL:PrintRaw("  |cffffff00/free report|r |cff808080<count>|r - Cumulative worst offenders "
        .. "since login, printed here")
    FL:PrintRaw("  |cffffff00/free reset|r - Zero the counters and start a fresh window")
    FL:PrintRaw("  |cffffff00/free rows|r |cff808080<count>|r - How many lines the window shows "
        .. "(%d-%d), currently |cff00ff00%d|r", MIN_ROWS, MAX_ROWS, FL.db.rows)
    FL:PrintRaw("  |cffffff00/free rate|r |cff808080<seconds>|r - How often the table refreshes "
        .. "(%.2g-%d), currently |cff00ff00%.2gs|r", MIN_RATE, MAX_RATE, FL.db.rate)
    FL:PrintRaw("  |cffffff00/free lock|r - Stop the window being dragged. Currently %s",
        FL.db.locked and ON or OFF)
    Status()
end

-- Three tokens, longest first as the guaranteed one. Slash registration is
-- last-writer-wins with no warning, so a short token like /free can silently
-- belong to another addon; /freeloader is the one nobody else will claim, and
-- it is what every message here tells you to type when something is wrong.
SLASH_FREELOADER1 = "/freeloader"
SLASH_FREELOADER2 = "/freeload"
SLASH_FREELOADER3 = "/free"
SlashCmdList.FREELOADER = function(input)
    local cmd, arg = input:lower():match("^%s*(%S*)%s*(.-)%s*$")

    if cmd == "" then
        -- Only when it OPENS. Closing a monitor is not a moment anybody wants
        -- ten lines of chat for.
        if FL.UI:Toggle() then Menu() end
    elseif cmd == "toggle" then
        -- A toggle always changes something, so there is no "already on" case to
        -- report the way a separate on and off had to.
        AskProfiling(not FL.profilingActive)
    elseif cmd == "profiler" then
        if not FL.hasProfiler then
            return FL:Print("This client has no built-in addon profiler. "
                .. "|cffffff00/free toggle|r is the CPU source here.")
        end
        FL:SetProfiler(not FL.db.profiler)
        if FL:UsingProfiler() then
            FL:Print("CPU from the built-in addon profiler |cff40ff40on|r.")
        elseif FL.db.profiler then
            FL:Print("Profiler selected, but the client has it switched off, so CPU falls "
                .. "back to script profiling.")
        else
            FL:Print("Built-in profiler |cffff6060off|r. CPU now comes from script profiling%s",
                FL.profilingActive and "." or ", which is off -- |cffffff00/free toggle|r to start it.")
        end
    elseif cmd == "report" then
        FL:Report(tonumber(arg))
    elseif cmd == "reset" then
        FL:Reset()
        FL:Print(FL:UsingProfiler()
            and "Window cleared. The profiler's session averages in /free report cannot be reset."
            or "Counters cleared.")
    elseif cmd == "rows" then
        local n = tonumber(arg)
        if not n then return FL:Print("Usage: /free rows <%d-%d>", MIN_ROWS, MAX_ROWS) end
        FL.db.rows = math.min(math.max(math.floor(n), MIN_ROWS), MAX_ROWS)
        FL.UI:Layout()
        FL:Print("Showing %d rows.", FL.db.rows)
    elseif cmd == "rate" then
        local n = tonumber(arg)
        if not n then return FL:Print("Usage: /free rate <%.2f-%d>", MIN_RATE, MAX_RATE) end
        FL.db.rate = math.min(math.max(n, MIN_RATE), MAX_RATE)
        FL:Rebase()
        FL:Print("Sampling every %.2fs.", FL.db.rate)
    elseif cmd == "lock" then
        FL.db.locked = not FL.db.locked
        FL:Print("Window %s.", FL.db.locked and "locked" or "unlocked")
    elseif cmd == "memory" then
        FL:SetMemory(not FL.db.memory)
        if FL.db.memory then
            FL:Print("Allocation tracking |cff40ff40on|r. The scan runs every %d samples and "
                .. "can cause a hitch of its own -- that hitch is the cost of the column, not "
                .. "of the addon at the top of it.", MEM_EVERY)
        else
            FL:Print("Allocation tracking |cffff6060off|r. The KB/s column will read |cff909090-|r.")
        end
    else
        Menu()
    end
end

----------------------------------------------------------------------
-- Load
----------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, name)
    -- Nothing is asked before login: a StaticPopup raised during ADDON_LOADED
    -- can land before the frames it needs exist. This gate is also what stops
    -- a window restored as open from prompting too early.
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        FL.ready = true
        if FL.UI.frame:IsShown() then FL:OfferProfiling() end
        return
    end

    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")

    FreeloaderDB = FreeloaderDB or {}
    for k, v in pairs(defaults) do
        if FreeloaderDB[k] == nil then
            FreeloaderDB[k] = type(v) == "table" and CopyTable(v) or v
        end
    end
    FL.db = FreeloaderDB
    FL.since, FL.sinceLabel = GetTime(), "login"
    -- Read from the TOC so the packager's @project-version@ substitution is the
    -- single source of it once this ships.
    FL.version = GetAddOnMetadata(ADDON, "Version")
    -- The addon list is fixed for the session, so this is read once instead of
    -- on every tick of the sample loop.
    addonCount = GetNumAddOns()
    for i = 1, addonCount do
        names[i] = (GetAddOnInfo(i)) or ("addon " .. i)
    end

    FL.UI:Init()
    if FL.db.shown then FL.UI:Show() end
end)
