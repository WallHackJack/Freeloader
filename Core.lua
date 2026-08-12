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
    minimap = true,
    minimapAngle = 200,
    -- Off by default. The scan behind the KB/s column hitches hard enough to be
    -- worse than the problem it is describing, and it does not even bill itself
    -- to Freeloader -- see SetMemory below.
    memory  = false,
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

local addonCount = 0
local frames, lastSample, baselined = 0, 0, false
local lastMem, ticksSinceMem, totalChurn = 0, 0, 0

FL.rows  = {}
FL.total = { cpu = 0, msf = 0, churn = 0, fps = 0, window = 0 }

-- Read at load, before anything can change it: the CVar reflects what the
-- NEXT session will do, and only this snapshot says whether the profiler is
-- actually running right now.
FL.profilingActive = (GetCVar("scriptProfile") == "1")

function FL:Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff59d0ffFreeloader|r  " .. msg)
end

----------------------------------------------------------------------
-- Sampling
----------------------------------------------------------------------

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
    -- of this function is a walk over the addon list to collect nothing.
    local profiling = self.profilingActive

    local memory = self.db.memory

    if not baselined then
        if profiling then UpdateAddOnCPUUsage() end
        if memory then UpdateAddOnMemoryUsage() end
        for i = 1, addonCount do
            prevCPU[i] = profiling and GetAddOnCPUUsage(i) or 0
            prevMem[i] = memory and GetAddOnMemoryUsage(i) or 0
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
    total.cpu, total.msf = 0, 0
    total.window, total.frames = window, frames
    total.fps = frames / window

    local sumChurn = 0
    for i = 1, addonCount do
        local pct, msf = 0, 0
        if profiling then
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
        if pct >= CPU_FLOOR or msf >= MSF_FLOOR or kbs >= CHURN_FLOOR then
            local r = pool[i]
            if not r then r = {}; pool[i] = r end
            r.name = r.name or (GetAddOnInfo(i)) or ("addon " .. i)
            r.pct, r.msf, r.churn = pct, msf, kbs
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
    UpdateAddOnCPUUsage()
    -- Respects the memory toggle rather than sneaking the expensive scan in
    -- behind a command that reads like it only prints what is already known.
    local memory = self.db.memory
    if memory then UpdateAddOnMemoryUsage() end

    local elapsed = math.max(GetTime() - self.since, 0.001)
    local list, sumCPU = {}, 0
    for i = 1, addonCount do
        local cpu = GetAddOnCPUUsage(i)
        local mem = memory and GetAddOnMemoryUsage(i) or 0
        sumCPU = sumCPU + cpu
        if cpu > 0 or mem > 16 then
            list[#list + 1] = { name = (GetAddOnInfo(i)), cpu = cpu, mem = mem }
        end
    end
    table.sort(list, function(a, b)
        if a.cpu == b.cpu then return a.mem > b.mem end
        return a.cpu > b.cpu
    end)

    self:Print("Since %s -- %s, %d addons loaded, %.1f%% of one core total.",
        self.sinceLabel, FormatDuration(elapsed), addonCount, sumCPU / (elapsed * 10))
    if not self.profilingActive then
        self:Print("|cffff6060Script profiling starts after a reload, so every CPU figure below is zero.|r")
    end

    limit = math.min(limit or 10, #list)
    for i = 1, limit do
        local e = list[i]
        local mem = ""
        if memory then
            mem = e.mem >= 1024 and (", %.1f MB"):format(e.mem / 1024)
                                 or (", %.0f KB"):format(e.mem)
        end
        self:Print("  %d. %s -- |cffffd000%.0f ms|r (%.1f%%)%s",
            i, e.name, e.cpu, e.cpu / (elapsed * 10), mem)
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

StaticPopupDialogs["FREELOADER_RELOAD"] = {
    text = "Freeloader has switched on script profiling, which is what makes the CPU columns exist.\n\nIt only takes effect on a UI reload.\n\nReload now?",
    button1 = YES,
    button2 = NO,
    OnAccept = ReloadUI,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function Help()
    FL:Print("|cff80c0ff/free|r toggles the window |cff909090(/freeload and /freeloader work too)|r. Also:")
    FL:Print("  |cff80c0ffmemory|r -- the KB/s column, off by default because the scan behind it hitches")
    FL:Print("  |cff80c0ffreport|r |cff909090[n]|r -- cumulative worst offenders since login, printed here")
    FL:Print("  |cff80c0ffreset|r -- zero the counters and start a fresh window")
    FL:Print("  |cff80c0ffrows|r |cff909090n|r -- how many lines the window shows (%d-%d)", MIN_ROWS, MAX_ROWS)
    FL:Print("  |cff80c0ffrate|r |cff909090n|r -- seconds between samples (%.2f-%d)", MIN_RATE, MAX_RATE)
    FL:Print("  |cff80c0fflock|r -- stop the window being dragged")
    FL:Print("  |cff80c0ffminimap|r -- show or hide the minimap button")
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
        FL.UI:Toggle()
    elseif cmd == "report" then
        FL:Report(tonumber(arg))
    elseif cmd == "reset" then
        FL:Reset()
        FL:Print("Counters cleared.")
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
    elseif cmd == "minimap" then
        FL.db.minimap = not FL.db.minimap
        FL.MinimapButton:Update()
        FL:Print("Minimap button %s.", FL.db.minimap and "shown" or "hidden")
    else
        Help()
    end
end

----------------------------------------------------------------------
-- Load
----------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, name)
    -- Script profiling is not a feature to be offered, it is the precondition
    -- for three of the four columns. So Freeloader switches the CVar on and
    -- asks for the one reload that makes it take effect. The CVar persists in
    -- Config.wtf, so this happens once per client and never again.
    --
    -- Deferred to PLAYER_LOGIN because StaticPopup_Show during ADDON_LOADED is
    -- early enough that the popup can land before the frames it needs exist.
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        if not FL.profilingActive then
            SetCVar("scriptProfile", "1")
            FL:Print("Switched on script profiling -- without it the CPU columns "
                .. "read zero. It needs one reload, then stays on.")
            StaticPopup_Show("FREELOADER_RELOAD")
        end
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
    -- The addon list is fixed for the session, so this is read once instead of
    -- on every tick of the sample loop.
    addonCount = GetNumAddOns()

    FL.UI:Init()
    FL.MinimapButton:Init()
    if FL.db.shown then FL.UI:Show() end
end)
