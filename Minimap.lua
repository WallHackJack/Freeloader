local ADDON, FL = ...

local MB = {}
FL.MinimapButton = MB

-- Hand-rolled rather than LibDBIcon, which would mean shipping LibDBIcon plus
-- LibDataBroker plus CallbackHandler plus LibStub -- four library folders
-- inside the addon whose entire argument is that it doesn't carry any. The
-- geometry below is LibDBIcon's, because those numbers are known to sit right
-- on the ring and there is no reason to rediscover them.

local RADIUS = 80

local function Reposition(button)
    local angle = math.rad(FL.db.minimapAngle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * RADIUS, math.sin(angle) * RADIUS)
end

-- Runs only while the button is actually being dragged; the script is attached
-- on OnDragStart and torn off again on OnDragStop.
local function OnDragUpdate(button)
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    FL.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    Reposition(button)
end

local function OnEnter(button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine("Freeloader")
    GameTooltip:AddLine("Which addon isn't paying its way.", 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")

    if not FL.profilingActive then
        GameTooltip:AddLine("Script profiling is off -- no CPU figures.", 1, 0.4, 0.4)
    elseif FL.UI.frame:IsShown() then
        GameTooltip:AddDoubleLine("Addon CPU",
            ("%.1f%% of a core"):format(FL.total.cpu), 1, 1, 1, 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Frame budget",
            ("%.0f%% at 60 fps"):format(FL.total.msf / 16.67 * 100), 1, 1, 1, 1, 0.82, 0)
    else
        -- Nothing samples while the window is closed, so the last totals are
        -- from whenever it was last open. Stale numbers in a tooltip are worse
        -- than none.
        GameTooltip:AddLine("Open the window for live figures.", 0.7, 0.7, 0.7)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff80c0ffLeft-click|r toggle the window", 1, 1, 1)
    GameTooltip:AddLine("|cff80c0ffRight-click|r print the session report", 1, 1, 1)
    GameTooltip:AddLine("|cff80c0ffDrag|r move around the minimap", 1, 1, 1)
    GameTooltip:Show()
end

function MB:Init()
    if self.button then return end

    local b = CreateFrame("Button", "FreeloaderMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    -- A coin, because the name is an accusation about paying your way.
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -5)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    b:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then FL:Report() else FL.UI:Toggle() end
    end)
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnEnter", OnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    self.button = b
    self:Update()
end

function MB:Update()
    Reposition(self.button)
    if FL.db.minimap then self.button:Show() else self.button:Hide() end
end
