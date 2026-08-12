local ADDON, FL = ...

local UI = {}
FL.UI = UI

-- One window, no options panel. Right-justified number columns instead of a
-- fixed-width font, which is the only way to get digits to line up when the
-- client ships no monospace face.

local PAD, ROW_H = 10, 13
local COL_NAME, COL_CPU, COL_MSF, COL_KBS = 0, 150, 206, 262
local W_NAME, W_CPU, W_MSF, W_KBS = 148, 52, 52, 58
local CONTENT_W = 320
local FRAME_W = CONTENT_W + PAD * 2
local FRAME_MS = 16.67 -- one frame at 60 fps

local HEADER_Y = -30
local TOTAL_Y  = -46   -- the totals sit in the grid, as a row, above the rule
-- The rule sits tight under the totals and well clear of the rows below it, so
-- it reads as belonging to the total rather than floating between the two.
local RULE_Y   = TOTAL_Y - ROW_H - 1
local ROWS_TOP = -65

local format = string.format
local floor = math.floor

-- Colour is a band, not a gradient, so a cell can compare bands and skip the
-- SetTextColor entirely -- which is most repaints, since a row rarely crosses
-- a threshold between two samples.
local BANDS = {
    { 1.00, 0.35, 0.35 },   -- 1: >= 5% of a core
    { 1.00, 0.82, 0.00 },   -- 2: >= 2%
    { 0.90, 0.90, 0.90 },   -- 3: >= 0.5%
    { 0.55, 0.55, 0.55 },   -- 4: below that
}

local function BandFor(pct)
    if pct >= 5.0 then return 1 end
    if pct >= 2.0 then return 2 end
    if pct >= 0.5 then return 3 end
    return 4
end

local function FormatKB(kb)
    if kb >= 1024 then return format("%.1f MB", kb / 1024) end
    return format("%.0f KB", kb)
end

-- The KB/s cell has 58px, so megabytes lose the space and the unit.
local function ChurnCell(kb)
    if kb >= 1024 then return format("%.1fM", kb / 1024) end
    return format("%.0f", kb)
end

-- A dash when the scan is switched off, which is not the same statement as a
-- zero would be.
local DASH = "|cff707070-|r"

----------------------------------------------------------------------
-- Cells
----------------------------------------------------------------------

-- SetText re-runs the font layout for that string whether or not the string
-- differs from the one already there, and a table of thirteen rows is fifty-odd
-- of those landing in a single frame. So every cell remembers the VALUE behind
-- its text and repaints only when that value moves. Comparing the value rather
-- than the finished string also skips the string.format, which is the other
-- half of the cost and the half that makes garbage.

local function Str(fs, text)
    if fs.value == text then return end
    fs.value = text
    fs:SetText(text)
end

-- Rounded to the precision the cell actually prints, so a number jittering in
-- digits nobody can see does not force a repaint.
local function Num(fs, value, mult, fmt)
    value = floor(value * mult + 0.5) / mult
    if fs.value == value then return end
    fs.value = value
    fs:SetText(format(fmt, value))
end

local function Churn(fs, kb, tracking)
    local key = tracking and floor(kb + 0.5) or false
    if fs.value == key then return end
    fs.value = key
    fs:SetText(tracking and ChurnCell(kb) or DASH)
end

local function Band(fs, band)
    if fs.band == band then return end
    fs.band = band
    local c = BANDS[band]
    fs:SetTextColor(c[1], c[2], c[3])
end

local function Text(parent, font, x, y, width, justify)
    local fs = parent:CreateFontString(nil, "ARTWORK", font)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetWidth(width)
    fs:SetJustifyH(justify)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end

local function SetSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
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

local BLUE = "|cff80c0ff"
local ON, OFF = "|cff40ff40ON|r", "|cffff6060OFF|r"

-- A column whose numbers depend on a switch says so on its first line, before
-- it explains anything: whether the switch is on is the thing you came to the
-- tooltip to find out, and it is not worth reading the rest if it is off.
local COLUMN_HELP = {
    [COL_NAME] = {
        title = "Addon",
        body = {
            "Every addon the client has loaded, worst first, including Freeloader itself.",
            "An addon only gets a row if at least one of its three columns has a non-zero number to show. The totals row still counts everything, including the addons too quiet to list.",
        },
    },
    [COL_CPU] = {
        title = "CPU",
        status = function()
            if FL.profilingActive then
                return ("Script profiling is %s. It costs a few percent CPU for as long as it runs, so %s/free off|r when you are done.")
                    :format(ON, BLUE)
            end
            return ("Script profiling is %s, so these numbers are zero. %s/free on|r starts it, which needs a reload.")
                :format(OFF, BLUE)
        end,
        body = {
            "Share of one CPU core spent running this addon's Lua, averaged over the sample window.",
            "Useful for ranking, but it does not tell you whether the cost lands in one ugly spike or spread evenly. That is what ms/f is for.",
        },
    },
    [COL_MSF] = {
        title = "ms/f -- milliseconds per frame",
        body = {
            "How long this addon's Lua runs during an average frame.",
            "At 60 fps the whole frame is 16.7 ms, and everything else -- the game world, your other addons, the client itself -- shares it. An addon at 2.00 here is taking 12% of that budget away from drawing.",
            "This is the column that turns into a framerate drop.",
        },
    },
    [COL_KBS] = {
        title = "KB/s -- allocation rate",
        status = function()
            return ("Allocation tracking is %s.  %s/free memory|r toggles it.")
                :format(FL.db.memory and ON or OFF, BLUE)
        end,
        body = {
            "Kilobytes of Lua memory this addon allocates per second: new tables, strings and closures.",
            "This is not memory it is holding. An addon can sit on 20 MB at 0 KB/s and cost you nothing.",
            "Allocation is what feeds the garbage collector, and a collection pass is a frame that does not get drawn. Sustained hundreds of KB/s from one addon usually means it rebuilds something every frame instead of reusing it.",
            "Off by default, and shown as a dash rather than a zero when off. The scan behind it hitches, and because it is a C call the client bills that hitch to nobody -- not even to Freeloader.",
        },
    },
}

local function OnHeaderEnter(hit)
    local help = COLUMN_HELP[hit.column]
    OpenTooltip(help.title)

    local status = help.status and help.status()
    if status then
        GameTooltip:AddLine(status, 1, 1, 1, true)
    end
    for i, paragraph in ipairs(help.body) do
        -- Paragraphs, not a wall: a blank line before each one but the first.
        if i > 1 or status then GameTooltip:AddLine(" ") end
        GameTooltip:AddLine(paragraph, 0.85, 0.85, 0.85, true)
    end

    GameTooltip:Show()
end

local function OnHoverLeave(row)
    row.highlight:Hide()
    HideTooltip()
end

-- The addon rows deliberately take no mouse input. Their tooltips repeated
-- what the columns already showed, and every mouse-enabled frame is a region
-- the client hit-tests as the cursor moves across the window.
local function OnTotalEnter(row)
    local t = FL.total
    row.highlight:Show()

    OpenTooltip("All addons")
    GameTooltip:AddLine("Every loaded addon summed, including the ones too quiet to earn a row of their own.",
        0.85, 0.85, 0.85, true)

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Over the last %.2gs"):format(t.window), 1, 0.82, 0)
    GameTooltip:AddDoubleLine("CPU", ("%.2f%% of a core"):format(t.cpu), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Per frame", ("%.2f ms"):format(t.msf), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Frame budget",
        ("%.1f%% at 60 fps"):format(t.msf / FRAME_MS * 100), 1, 1, 1, 1, 1, 1)
    if FL.db.memory then
        GameTooltip:AddDoubleLine("Allocating", ("%s/s"):format(FormatKB(t.churn)), 1, 1, 1, 1, 1, 1)
    else
        GameTooltip:AddDoubleLine("Allocating", "not tracked", 1, 1, 1, 1, 0.38, 0.38)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("This counts Lua time only. An addon that spawns hundreds of frames costs draw time that never appears in any of these columns -- watch the fps figure below alongside it.",
        0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end

----------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------

-- onEnter is what makes a row interactive. Without it the row takes no mouse
-- input at all, which also means drags over it fall straight through to the
-- window and nothing has to forward them.
function UI:CreateRow(y, onEnter)
    local f = self.frame
    local row = CreateFrame("Frame", nil, f)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    row:SetSize(CONTENT_W, ROW_H)

    if onEnter then
        row:EnableMouse(true)
        row:SetScript("OnEnter", onEnter)
        row:SetScript("OnLeave", OnHoverLeave)
        MakeDraggable(row)

        local hl = row:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints()
        SetSolid(hl, 1, 1, 1, 0.09)
        hl:Hide()
        row.highlight = hl
    end

    row.name = Text(row, "GameFontHighlightSmall", COL_NAME, 0, W_NAME, "LEFT")
    row.cpu  = Text(row, "GameFontHighlightSmall", COL_CPU,  0, W_CPU,  "RIGHT")
    row.msf  = Text(row, "GameFontHighlightSmall", COL_MSF,  0, W_MSF,  "RIGHT")
    row.kbs  = Text(row, "GameFontHighlightSmall", COL_KBS,  0, W_KBS,  "RIGHT")
    return row
end

function UI:BuildHeader()
    local f = self.frame
    local columns = {
        { COL_NAME, W_NAME, "Addon", "LEFT" },
        { COL_CPU,  W_CPU,  "CPU",   "RIGHT" },
        { COL_MSF,  W_MSF,  "ms/f",  "RIGHT" },
        { COL_KBS,  W_KBS,  "KB/s",  "RIGHT" },
    }
    for _, c in ipairs(columns) do
        local x, width, label, justify = c[1], c[2], c[3], c[4]
        Text(f, "GameFontNormalSmall", PAD + x, HEADER_Y, width, justify):SetText(label)

        local hit = CreateFrame("Frame", nil, f)
        hit:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + x, HEADER_Y)
        hit:SetSize(width, 12)
        hit:EnableMouse(true)
        hit.column = x
        hit:SetScript("OnEnter", OnHeaderEnter)
        hit:SetScript("OnLeave", HideTooltip)
        MakeDraggable(hit)
    end
end

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

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() UI:Hide() end)

    self:BuildHeader()

    -- The totals belong in the grid: they are the same three quantities in the
    -- same three columns, and a reader comparing a row against the total should
    -- not have to re-find the numbers in a sentence at the bottom.
    self.totalRow = self:CreateRow(TOTAL_Y, OnTotalEnter)
    self.totalRow.name:SetText("All addons")
    self.totalRow.name:SetTextColor(1, 0.82, 0)
    self.totalRow.cpu:SetTextColor(1, 0.82, 0)
    self.totalRow.msf:SetTextColor(1, 0.82, 0)
    self.totalRow.kbs:SetTextColor(1, 0.82, 0)

    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, RULE_Y)
    rule:SetSize(CONTENT_W, 1)
    SetSolid(rule, 1, 1, 1, 0.18)

    self.lines = {}
    -- fps has no column of its own -- it is not a per-addon quantity -- so it
    -- keeps the footer line the totals used to occupy.
    f.state = Text(f, "GameFontHighlightSmall", PAD, 0, CONTENT_W, "LEFT")
    f.rate  = Text(f, "GameFontDisableSmall", PAD, 0, CONTENT_W, "LEFT")

    f:SetScript("OnShow", function()
        FL.db.shown = true
        FL:Rebase()
        UI:Refresh()
        -- Opening the window is the moment you have said you want CPU numbers,
        -- so it is the moment to ask for the reload that produces them.
        FL:OfferProfiling()
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

    self:Layout()
end

-- Rows are built on demand and never destroyed: /free rows is a display
-- preference, not a reason to churn frames.
function UI:Layout()
    local f, n = self.frame, FL.db.rows

    for i = 1, n do
        if not self.lines[i] then
            self.lines[i] = self:CreateRow(ROWS_TOP - (i - 1) * ROW_H)
        end
        self.lines[i]:Show()
    end
    for i = n + 1, #self.lines do
        self.lines[i]:Hide()
    end

    local footer = ROWS_TOP - n * ROW_H - 6
    f.state:ClearAllPoints()
    f.state:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, footer)
    f.rate:ClearAllPoints()
    f.rate:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, footer - 12)
    f:SetHeight(-footer + 12 + 12 + PAD)

    self:Refresh()
end

function UI:Refresh()
    local rows, total, db = FL.rows, FL.total, FL.db
    local f = self.frame

    local memory = db.memory

    -- Resolved before the loop so the first row is written once, rather than
    -- cleared by the loop and rewritten by the empty-state check right after.
    local placeholder
    if #rows == 0 then
        if not FL.profilingActive and not memory then
            placeholder = "|cff909090nothing to measure|r"
        else
            placeholder = format("|cff808080sampling, %.2gs window...|r", db.rate)
        end
    end

    local tr = self.totalRow
    Num(tr.cpu, total.cpu, 10, "%.1f%%")
    Num(tr.msf, total.msf, 100, "%.2f")
    Churn(tr.kbs, total.churn, memory)

    for i = 1, db.rows do
        local row, r = self.lines[i], rows[i]
        if r then
            local band = BandFor(r.pct)
            Str(row.name, r.name)
            Band(row.name, band)
            Band(row.cpu, band)
            Num(row.cpu, r.pct, 10, "%.1f%%")
            Num(row.msf, r.msf, 100, "%.2f")
            Churn(row.kbs, r.churn, memory)
        else
            Str(row.name, (i == 1 and placeholder) or "")
            Str(row.cpu, "")
            Str(row.msf, "")
            Str(row.kbs, "")
        end
    end

    -- fps moves every sample, so this line is the one repaint that always
    -- earns itself. Everything above it usually does not.
    local fps = floor(total.fps + 0.5)
    if FL.profilingActive then
        -- The share of one 60 fps frame is a much sharper number than "3.2 ms".
        local budget = floor(total.msf / FRAME_MS * 100 + 0.5)
        if f.state.value ~= fps or f.state.budget ~= budget then
            f.state.value, f.state.budget = fps, budget
            f.state:SetText(format(
                "|cffffffff%d fps|r   |cff909090addon Lua is taking %d%% of a 60 fps frame budget|r",
                fps, budget))
        end
    elseif f.state.value ~= fps or f.state.budget ~= false then
        f.state.value, f.state.budget = fps, false
        f.state:SetText(format(
            "|cffffffff%d fps|r   |cffff6060CPU is off.|r |cff80c0ff/free on|r |cff909090to enable it|r",
            fps))
    end

    -- Only moves when /free rate does.
    Num(f.rate, db.rate, 100,
        "|cff909090Refreshes every %.2gs, use |r|cff80c0ff/free rate|r|cff909090 to edit|r")
end

function UI:Show()   self.frame:Show() end
function UI:Hide()   self.frame:Hide() end
function UI:Toggle()
    if self.frame:IsShown() then self:Hide() else self:Show() end
end
