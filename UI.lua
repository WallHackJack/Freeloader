local ADDON, FL = ...

local UI = {}
FL.UI = UI

-- One window, no options panel, no minimap button. Right-justified number
-- columns instead of a fixed-width font, which is the only way to get digits
-- to line up when the client ships no monospace face.

local PAD, ROW_H = 10, 13
local COL_NAME, COL_CPU, COL_MSF, COL_KBS = 0, 150, 206, 262
local CONTENT_W = 320
local FRAME_W = CONTENT_W + PAD * 2
local ROWS_TOP = -46   -- first row's y, below the title and column headers

local function ColorFor(pct)
    if pct >= 5.0 then return 1.00, 0.35, 0.35 end
    if pct >= 2.0 then return 1.00, 0.82, 0.00 end
    if pct >= 0.5 then return 0.90, 0.90, 0.90 end
    return 0.55, 0.55, 0.55
end

local function Text(parent, font, x, y, width, justify)
    local fs = parent:CreateFontString(nil, "ARTWORK", font)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD + x, y)
    fs:SetWidth(width)
    fs:SetJustifyH(justify)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end

function UI:Init()
    if self.frame then return end

    local f = CreateFrame("Frame", "FreeloaderFrame", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    -- Before any scripts exist: frames are created shown, and letting OnHide
    -- fire here would clear the saved "was open" flag we are about to read.
    f:Hide()

    f:SetWidth(FRAME_W)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetPoint(FL.db.point[1], UIParent, FL.db.point[2], FL.db.point[3], FL.db.point[4])

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0, 0, 0, 0.85)
    end

    f.title = Text(f, "GameFontNormal", COL_NAME, -PAD, 200, "LEFT")
    f.title:SetText("Freeloader")
    -- Stops short of the close button rather than running under it.
    f.rate = Text(f, "GameFontDisableSmall", COL_MSF, -PAD + 2, 92, "RIGHT")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() UI:Hide() end)

    local head = ROWS_TOP + ROW_H + 3
    Text(f, "GameFontNormalSmall", COL_NAME, head, 148, "LEFT"):SetText("Addon")
    Text(f, "GameFontNormalSmall", COL_CPU,  head,  52, "RIGHT"):SetText("CPU")
    Text(f, "GameFontNormalSmall", COL_MSF,  head,  52, "RIGHT"):SetText("ms/f")
    Text(f, "GameFontNormalSmall", COL_KBS,  head,  58, "RIGHT"):SetText("KB/s")

    self.lines = {}
    f.summary = Text(f, "GameFontHighlightSmall", COL_NAME, 0, CONTENT_W, "LEFT")
    f.state   = Text(f, "GameFontHighlightSmall", COL_NAME, 0, CONTENT_W, "LEFT")

    f:SetScript("OnDragStart", function(self)
        if not FL.db.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        FL.db.point = { point, relPoint, x, y }
    end)
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

    self.frame = f
    self:Layout()
end

-- Rows are built on demand and never destroyed: /free rows is a display
-- preference, not a reason to churn font strings.
function UI:Layout()
    local f, n = self.frame, FL.db.rows

    for i = 1, n do
        if not self.lines[i] then
            local y = ROWS_TOP - (i - 1) * ROW_H
            self.lines[i] = {
                name = Text(f, "GameFontHighlightSmall", COL_NAME, y, 148, "LEFT"),
                cpu  = Text(f, "GameFontHighlightSmall", COL_CPU,  y,  52, "RIGHT"),
                msf  = Text(f, "GameFontHighlightSmall", COL_MSF,  y,  52, "RIGHT"),
                kbs  = Text(f, "GameFontHighlightSmall", COL_KBS,  y,  58, "RIGHT"),
            }
        end
        for _, fs in pairs(self.lines[i]) do fs:Show() end
    end
    for i = n + 1, #self.lines do
        for _, fs in pairs(self.lines[i]) do fs:Hide() end
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
        local line, r = self.lines[i], rows[i]
        if r then
            line.name:SetText(r.name)
            line.name:SetTextColor(ColorFor(r.pct))
            line.cpu:SetText(("%.1f%%"):format(r.pct))
            line.cpu:SetTextColor(ColorFor(r.pct))
            line.msf:SetText(("%.2f"):format(r.msf))
            line.kbs:SetText(r.churn >= 1024 and ("%.1fM"):format(r.churn / 1024)
                                              or ("%.0f"):format(r.churn))
        else
            line.name:SetText("")
            line.cpu:SetText("")
            line.msf:SetText("")
            line.kbs:SetText("")
        end
    end

    if #rows == 0 then
        self.lines[1].name:SetText("|cff808080sampling...|r")
    end

    f.rate:SetText(("every %.2gs"):format(db.rate))
    f.summary:SetText(("|cff909090all addons|r  %.1f%%   %.2f ms/f   %.0f KB/s   |cff909090at|r %d fps")
        :format(total.cpu, total.msf, total.churn, math.floor(total.fps + 0.5)))

    if FL.profilingActive then
        -- 16.7 ms is one frame at 60 fps; the share of it addons are taking is
        -- the whole point, and it is a much sharper number than "3.2 ms".
        f.state:SetText(("|cff909090%.0f%% of a 60 fps frame budget spent in addon Lua.|r")
            :format(total.msf / 16.67 * 100))
    else
        f.state:SetText("|cffff6060CPU is off.|r |cff80c0ff/free on|r |cff909090to enable script profiling.|r")
    end
end

function UI:Show()   self.frame:Show() end
function UI:Hide()   self.frame:Hide() end
function UI:Toggle()
    if self.frame:IsShown() then self:Hide() else self:Show() end
end
