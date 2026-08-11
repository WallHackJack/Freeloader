local ADDON, FL = ...

local UI = {}
FL.UI = UI

-- One window, no options panel. Right-justified number columns instead of a
-- fixed-width font, which is the only way to get digits to line up when the
-- client ships no monospace face.

local GetAddOnInfo  = C_AddOns and C_AddOns.GetAddOnInfo  or GetAddOnInfo
local IsAddOnLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded

local PAD, ROW_H = 10, 13
local COL_NAME, COL_CPU, COL_MSF, COL_KBS = 0, 150, 206, 262
local W_NAME, W_CPU, W_MSF, W_KBS = 148, 52, 52, 58
local CONTENT_W = 320
local FRAME_W = CONTENT_W + PAD * 2
local ROWS_TOP = -46   -- first row's y, below the title and column headers
local FRAME_MS = 16.67 -- one frame at 60 fps

local function ColorFor(pct)
    if pct >= 5.0 then return 1.00, 0.35, 0.35 end
    if pct >= 2.0 then return 1.00, 0.82, 0.00 end
    if pct >= 0.5 then return 0.90, 0.90, 0.90 end
    return 0.55, 0.55, 0.55
end

local function FormatKB(kb)
    if kb >= 1024 then return ("%.1f MB"):format(kb / 1024) end
    return ("%.0f KB"):format(kb)
end

local function Text(parent, font, x, y, width, justify)
    local fs = parent:CreateFontString(nil, "ARTWORK", font)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetWidth(width)
    fs:SetJustifyH(justify)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end

----------------------------------------------------------------------
-- Dragging
----------------------------------------------------------------------

-- Every mouse-enabled child swallows drags over its own area, and once rows
-- and column headers take the mouse for tooltips that is most of the window.
-- So they all forward to the same two handlers and the window stays
-- draggable by any part of itself.

local function StartDrag()
    if not FL.db.locked then UI.frame:StartMoving() end
end

local function StopDrag()
    local f = UI.frame
    f:StopMovingOrSizing()
    local point, _, relPoint, x, y = f:GetPoint(1)
    FL.db.point = { point, relPoint, x, y }
end

local function MakeDraggable(region)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", StartDrag)
    region:SetScript("OnDragStop", StopDrag)
end

----------------------------------------------------------------------
-- Tooltips
----------------------------------------------------------------------

-- Anchored to the window rather than to the hovered region, so it does not
-- jump around the screen as you run down a column of rows.
local function OpenTooltip(title)
    GameTooltip:SetOwner(UI.frame, "ANCHOR_RIGHT")
    GameTooltip:AddLine(title)
end

local function HideTooltip()
    GameTooltip:Hide()
end

local COLUMN_HELP = {
    [COL_NAME] = { "Addon", {
        "Every addon the client has loaded, worst first, including Freeloader itself.",
        "Rows that are costing nothing measurable are left out rather than padded in as zeroes.",
    } },
    [COL_CPU] = { "CPU", {
        "Share of one CPU core spent running this addon's Lua, averaged over the sample window.",
        "Useful for ranking, but it does not tell you whether the cost lands in one ugly spike or spread evenly. That is what ms/f is for.",
    } },
    [COL_MSF] = { "ms/f -- milliseconds per frame", {
        "How long this addon's Lua runs during an average frame.",
        "At 60 fps the whole frame is 16.7 ms, and everything else -- the game world, your other addons, the client itself -- shares it. An addon at 2.00 here is taking 12% of that budget away from drawing.",
        "This is the column that turns into a framerate drop.",
    } },
    [COL_KBS] = { "KB/s -- allocation rate", {
        "Kilobytes of Lua memory this addon allocates per second: new tables, strings and closures.",
        "This is not memory it is holding. An addon can sit on 20 MB at 0 KB/s and cost you nothing.",
        "Allocation is what feeds the garbage collector, and a collection pass is a frame that does not get drawn. Sustained hundreds of KB/s from one addon usually means it rebuilds something every frame instead of reusing it.",
    } },
}

local function OnHeaderEnter(hit)
    local help = COLUMN_HELP[hit.column]
    OpenTooltip(help[1])
    for _, line in ipairs(help[2]) do
        GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
    end
    GameTooltip:Show()
end

local function OnRowEnter(row)
    local r = row.data
    if not r then return end
    row.highlight:Show()

    local _, title = GetAddOnInfo(r.index)
    OpenTooltip(r.name)
    if title and title ~= r.name then
        GameTooltip:AddLine(title, 0.7, 0.7, 0.7, true)
    end
    if not IsAddOnLoaded(r.index) then
        GameTooltip:AddLine("Not loaded.", 1, 0.4, 0.4)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Over the last %.2gs"):format(FL.total.window), 1, 0.82, 0)
    GameTooltip:AddDoubleLine("CPU", ("%.2f%% of a core"):format(r.pct), 1, 1, 1, ColorFor(r.pct))
    GameTooltip:AddDoubleLine("Per frame", ("%.2f ms"):format(r.msf), 1, 1, 1, ColorFor(r.pct))
    GameTooltip:AddDoubleLine("Frame budget",
        ("%.1f%% at 60 fps"):format(r.msf / FRAME_MS * 100), 1, 1, 1, ColorFor(r.pct))
    GameTooltip:AddDoubleLine("Allocating", ("%s/s"):format(FormatKB(r.churn)), 1, 1, 1, 1, 1, 1)

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Since %s"):format(FL.sinceLabel), 1, 0.82, 0)
    GameTooltip:AddDoubleLine("CPU total", ("%.0f ms"):format(r.cpu), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Memory held", FormatKB(r.mem), 1, 1, 1, 0.7, 0.7, 0.7)

    GameTooltip:Show()
end

local function OnRowLeave(row)
    row.highlight:Hide()
    HideTooltip()
end

----------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------

function UI:Init()
    if self.frame then return end

    local f = CreateFrame("Frame", "FreeloaderFrame", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    -- Before any scripts exist: frames are created shown, and letting OnHide
    -- fire here would clear the saved "was open" flag we are about to read.
    f:Hide()
    self.frame = f

    f:SetWidth(FRAME_W)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetPoint(FL.db.point[1], UIParent, FL.db.point[2], FL.db.point[3], FL.db.point[4])
    MakeDraggable(f)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0, 0, 0, 0.85)
    end

    f.title = Text(f, "GameFontNormal", PAD + COL_NAME, -PAD, 200, "LEFT")
    f.title:SetText("Freeloader")
    -- Stops short of the close button rather than running under it.
    f.rate = Text(f, "GameFontDisableSmall", PAD + COL_MSF, -PAD + 2, 92, "RIGHT")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() UI:Hide() end)

    self.lines = {}
    f.summary = Text(f, "GameFontHighlightSmall", PAD, 0, CONTENT_W, "LEFT")
    f.state   = Text(f, "GameFontHighlightSmall", PAD, 0, CONTENT_W, "LEFT")

    f:SetScript("OnShow", function()
        FL.db.shown = true
        FL:Rebase()
        UI:Refresh()
    end)
    f:SetScript("OnHide", function() FL.db.shown = false end)
    -- Hidden frames get no OnUpdate, so a closed window samples nothing and
    -- costs nothing. This is also where the frame count for ms/f comes from.
    f:SetScript("OnUpdate", function()
        if FL:Tick() then UI:Refresh() end
    end)

    -- Deliberately NOT in UISpecialFrames: this is a monitor you leave running
    -- while you play, and Escape is a key you hit constantly for other reasons.
    -- The close button and /free are the ways out.

    self:BuildHeader(ROWS_TOP + ROW_H + 3)
    self:Layout()
end

function UI:BuildHeader(y)
    local f = self.frame
    local columns = {
        { COL_NAME, W_NAME, "Addon", "LEFT" },
        { COL_CPU,  W_CPU,  "CPU",   "RIGHT" },
        { COL_MSF,  W_MSF,  "ms/f",  "RIGHT" },
        { COL_KBS,  W_KBS,  "KB/s",  "RIGHT" },
    }
    for _, c in ipairs(columns) do
        local x, width, label, justify = c[1], c[2], c[3], c[4]
        Text(f, "GameFontNormalSmall", PAD + x, y, width, justify):SetText(label)

        local hit = CreateFrame("Frame", nil, f)
        hit:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + x, y)
        hit:SetSize(width, 12)
        hit:EnableMouse(true)
        hit.column = x
        hit:SetScript("OnEnter", OnHeaderEnter)
        hit:SetScript("OnLeave", HideTooltip)
        MakeDraggable(hit)
    end
end

-- Rows are built on demand and never destroyed: /free rows is a display
-- preference, not a reason to churn frames.
function UI:Layout()
    local f, n = self.frame, FL.db.rows

    for i = 1, n do
        if not self.lines[i] then
            local row = CreateFrame("Frame", nil, f)
            row:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, ROWS_TOP - (i - 1) * ROW_H)
            row:SetSize(CONTENT_W, ROW_H)
            row:EnableMouse(true)
            row:SetScript("OnEnter", OnRowEnter)
            row:SetScript("OnLeave", OnRowLeave)
            MakeDraggable(row)

            local hl = row:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints()
            if hl.SetColorTexture then
                hl:SetColorTexture(1, 1, 1, 0.09)
            else
                hl:SetTexture(1, 1, 1, 0.09)
            end
            hl:Hide()

            row.highlight = hl
            row.name = Text(row, "GameFontHighlightSmall", COL_NAME, 0, W_NAME, "LEFT")
            row.cpu  = Text(row, "GameFontHighlightSmall", COL_CPU,  0, W_CPU,  "RIGHT")
            row.msf  = Text(row, "GameFontHighlightSmall", COL_MSF,  0, W_MSF,  "RIGHT")
            row.kbs  = Text(row, "GameFontHighlightSmall", COL_KBS,  0, W_KBS,  "RIGHT")
            self.lines[i] = row
        end
        self.lines[i]:Show()
    end
    for i = n + 1, #self.lines do
        self.lines[i]:Hide()
    end

    local footer = ROWS_TOP - n * ROW_H - 6
    f.summary:ClearAllPoints()
    f.summary:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, footer)
    f.state:ClearAllPoints()
    f.state:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, footer - 12)
    f:SetHeight(-footer + 12 + 12 + PAD)

    self:Refresh()
end

function UI:Refresh()
    local rows, total, db = FL.rows, FL.total, FL.db
    local f = self.frame

    for i = 1, db.rows do
        local row, r = self.lines[i], rows[i]
        row.data = r
        if r then
            row.name:SetText(r.name)
            row.name:SetTextColor(ColorFor(r.pct))
            row.cpu:SetText(("%.1f%%"):format(r.pct))
            row.cpu:SetTextColor(ColorFor(r.pct))
            row.msf:SetText(("%.2f"):format(r.msf))
            row.kbs:SetText(r.churn >= 1024 and ("%.1fM"):format(r.churn / 1024)
                                             or ("%.0f"):format(r.churn))
        else
            row.name:SetText("")
            row.cpu:SetText("")
            row.msf:SetText("")
            row.kbs:SetText("")
        end
    end

    if #rows == 0 then
        self.lines[1].name:SetText(("|cff808080sampling, %.2gs window...|r"):format(db.rate))
    end

    f.rate:SetText(("every %.2gs"):format(db.rate))
    f.summary:SetText(("|cff909090all addons|r  %.1f%%   %.2f ms/f   %.0f KB/s   |cff909090at|r %d fps")
        :format(total.cpu, total.msf, total.churn, math.floor(total.fps + 0.5)))

    if FL.profilingActive then
        -- The share of one 60 fps frame is a much sharper number than "3.2 ms".
        f.state:SetText(("|cff909090%.0f%% of a 60 fps frame budget spent in addon Lua.|r")
            :format(total.msf / FRAME_MS * 100))
    else
        f.state:SetText("|cffff6060CPU is off.|r |cff80c0ff/free on|r |cff909090to enable script profiling.|r")
    end
end

function UI:Show()   self.frame:Show() end
function UI:Hide()   self.frame:Hide() end
function UI:Toggle()
    if self.frame:IsShown() then self:Hide() else self:Show() end
end
