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

local CPU_FLOOR   = 0.005  -- % of one core; under this it is timer noise, not cost
local CHURN_FLOOR = 0.5    -- KB/s
local MIN_RATE, MAX_RATE = 0.25, 10
local MIN_ROWS, MAX_ROWS = 3, 40

local defaults = {
    rate    = 1,      -- seconds between samples
    rows    = 12,
    locked  = false,
    shown   = false,
    point   = { "CENTER", "CENTER", 0, 0 },
    minimap = true,
    minimapAngle = 200,
}

-- Index -> last reading. The addon list cannot change mid-session, so the
-- index is a stable key and no name lookup is needed to pair up samples.
local prevCPU, prevMem = {}, {}
-- Index -> reusable row table. A profiler that allocates a fresh table per
-- addon per second would show up in its own KB/s column, which is funny once.
local pool = {}

local frames, lastSample, baselined = 0, 0, false

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
    local window = now - lastSample
    local n = GetNumAddOns()

    UpdateAddOnCPUUsage()
    UpdateAddOnMemoryUsage()

    if not baselined then
        for i = 1, n do
            prevCPU[i], prevMem[i] = GetAddOnCPUUsage(i), GetAddOnMemoryUsage(i)
        end
        baselined, lastSample, frames = true, now, 0
        return false
    end

    local rows, total = self.rows, self.total
    wipe(rows)
    total.cpu, total.msf, total.churn = 0, 0, 0
    total.window, total.frames = window, frames
    total.fps = frames / window

    for i = 1, n do
        local cpu, mem = GetAddOnCPUUsage(i), GetAddOnMemoryUsage(i)
        local dcpu = cpu - (prevCPU[i] or cpu)
        local dmem = mem - (prevMem[i] or mem)
        prevCPU[i], prevMem[i] = cpu, mem

        -- A negative memory delta means the collector ran, not that the addon
        -- handed memory back. Those allocations did happen, we just cannot see
        -- them any more -- floor at zero rather than report a negative rate.
        if dmem < 0 then dmem = 0 end

        -- ms over the window, as a share of one core: dcpu / (window * 1000) * 100.
        local pct   = dcpu / (window * 10)
        local churn = dmem / window
        local msf   = frames > 0 and dcpu / frames or 0

        total.cpu, total.churn, total.msf = total.cpu + pct, total.churn + churn, total.msf + msf

        if pct >= CPU_FLOOR or churn >= CHURN_FLOOR then
            local r = pool[i]
            if not r then r = {}; pool[i] = r end
            r.name  = r.name or (GetAddOnInfo(i)) or ("addon " .. i)
            r.pct, r.msf, r.churn = pct, msf, churn
            rows[#rows + 1] = r
        end
    end

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
    UpdateAddOnMemoryUsage()

    local elapsed = math.max(GetTime() - self.since, 0.001)
    local list, sumCPU = {}, 0
    for i = 1, GetNumAddOns() do
        local cpu, mem = GetAddOnCPUUsage(i), GetAddOnMemoryUsage(i)
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
        self.sinceLabel, FormatDuration(elapsed), GetNumAddOns(), sumCPU / (elapsed * 10))
    if not self.profilingActive then
        self:Print("|cffff6060Script profiling is off, so every CPU figure below is zero.|r Run |cff80c0ff/free on|r.")
    end

    limit = math.min(limit or 10, #list)
    for i = 1, limit do
        local e = list[i]
        local mem = e.mem >= 1024 and ("%.1f MB"):format(e.mem / 1024) or ("%.0f KB"):format(e.mem)
        self:Print("  %d. %s -- |cffffd000%.0f ms|r (%.1f%%), %s",
            i, e.name, e.cpu, e.cpu / (elapsed * 10), mem)
    end
    if #list > limit then
        self:Print("  |cff909090... and %d more. /free report %d for a longer list.|r", #list - limit, #list)
    end
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
    text = "Script profiling only changes on a UI reload.\n\nReload now?",
    button1 = YES,
    button2 = NO,
    OnAccept = ReloadUI,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function SetProfiling(on)
    SetCVar("scriptProfile", on and "1" or "0")
    if on == FL.profilingActive then
        FL:Print("Script profiling is already %s.", on and "|cff40ff40on|r" or "|cffff6060off|r")
        return
    end
    FL:Print("Script profiling will be %s after a reload.%s",
        on and "|cff40ff40on|r" or "|cffff6060off|r",
        on and " It costs a few percent CPU on its own, so turn it back off when you are done." or "")
    StaticPopup_Show("FREELOADER_RELOAD")
end

local function Help()
    FL:Print("|cff80c0ff/free|r toggles the window |cff909090(/freeload and /freeloader work too)|r. Also:")
    FL:Print("  |cff80c0ffon|r / |cffdd80ffoff|r -- script profiling, the CVar that makes CPU numbers exist (needs a reload)")
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
    elseif cmd == "on" or cmd == "off" then
        SetProfiling(cmd == "on")
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
loader:SetScript("OnEvent", function(self, _, name)
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

    FL.UI:Init()
    FL.MinimapButton:Init()
    if FL.db.shown then FL.UI:Show() end
end)
