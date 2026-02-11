local addonName, addon = ...

function addon:CreateMainAHPanel(parentFrame)
    local panel = CreateFrame("Frame", "RichSnobsAHMainAHPanel", parentFrame, "BackdropTemplate")
    panel:SetWidth(420)
    panel:SetPoint("TOPLEFT", parentFrame, "TOPRIGHT", -1, 0)
    panel:SetPoint("BOTTOMLEFT", parentFrame, "BOTTOMRIGHT", -1, 0)
    panel:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    panel:SetBackdropColor(0, 0, 0, 1.0)
    panel:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    panel:Hide()
    
    -- Make AH panel draggable (moves the main frame)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self)
        local parent = self:GetParent()
        if parent and parent.StartMoving then
            parent:StartMoving()
        end
    end)
    panel:SetScript("OnDragStop", function(self)
        local parent = self:GetParent()
        if parent and parent.StopMovingOrSizing then
            parent:StopMovingOrSizing()
        end
    end)
    
    -- Tabs for switching between Buy, Undercut, Post
    panel.tabs = {}
    local tabNames = {"Buy", "Undercut", "Post"}
    local tabWidth = (panel:GetWidth() - 20) / 3
    
    for i, name in ipairs(tabNames) do
        local tab = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
        tab:SetWidth(tabWidth)
        tab:SetHeight(25)
        tab:SetText(name)
        if i == 1 then
            tab:SetPoint("TOPLEFT", 10, -10)
        else
            tab:SetPoint("LEFT", panel.tabs[i-1], "RIGHT", 0, 0)
        end
        
        tab:SetScript("OnClick", function()
            addon:SelectAHPanelTab(i)
        end)
        panel.tabs[i] = tab
    end
    
    -- Sub-panes container
    local container = CreateFrame("Frame", nil, panel)
    container:SetPoint("TOPLEFT", 0, -35)
    container:SetPoint("BOTTOMRIGHT", 0, 0) -- Fill to the bottom
    panel.container = container
    
    addon.mainAHPanel = panel
    
    -- Initialize sub-panes inside our container
    addon:CreateAHResultsPane(container)
    addon:CreateUndercutPane(container)
    addon:CreatePostPane(container)
end

function addon:SelectAHPanelTab(index)
    if not addon.mainAHPanel then return end
    
    addon.db.selectedTab = index
    addon.mainAHPanel:Show()
    
    -- Hide all
    if addon.ahResultsPane then addon.ahResultsPane:Hide() end
    if addon.undercutPane then addon.undercutPane:Hide() end
    if addon.postPane then addon.postPane:Hide() end
    
    -- Highlight active tab (simple way: change text color or disable button)
    for i, tab in ipairs(addon.mainAHPanel.tabs) do
        if i == index then
            tab:SetNormalFontObject("GameFontHighlight")
        else
            tab:SetNormalFontObject("GameFontNormal")
        end
    end
    
    -- Show selected
    if index == 1 then
        if addon.ahResultsPane then addon.ahResultsPane:Show() end
    elseif index == 2 then
        if addon.undercutPane then addon.undercutPane:Show() end
        addon:FetchPlayerAuctions()
    elseif index == 3 then
        if addon.postPane then addon.postPane:Show() end
    end
    
    addon.mainAHPanel:Show()
end

function addon:ShowMainAHPanel()
    if not addon.mainAHPanel then return end
    addon.mainAHPanel:Show()
    
    -- Default to Buy tab if nothing shown
    if (not addon.ahResultsPane or not addon.ahResultsPane:IsShown()) and
       (not addon.undercutPane or not addon.undercutPane:IsShown()) and
       (not addon.postPane or not addon.postPane:IsShown()) then
        addon:SelectAHPanelTab(1)
    end
end
