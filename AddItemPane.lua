local addonName, addon = ...

function addon:CreateAddItemPopout(parentFrame)
    local popout = CreateFrame("Frame", "RichSnobsAHAddItemPopout", parentFrame, "BackdropTemplate")
    popout:SetWidth(parentFrame:GetWidth())
    popout:SetHeight(70)
    popout:SetPoint("TOPLEFT", parentFrame, "BOTTOMLEFT", 0, 2) -- Flush to bottom, slightly overlapping for border
    
    popout:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    popout:SetBackdropColor(0, 0, 0, 1.0)
    popout:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    
    -- Make popout draggable (moves the main frame)
    popout:EnableMouse(true)
    popout:RegisterForDrag("LeftButton")
    popout:SetScript("OnDragStart", function(self)
        if addon.mainFrame then addon.mainFrame:StartMoving() end
    end)
    popout:SetScript("OnDragStop", function(self)
        if addon.mainFrame then addon.mainFrame:StopMovingOrSizing() end
    end)
    
    popout:Hide()

    -- Title/Instructions (Centered)
    local title = popout:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Shift-click items anywhere to add them to the active group")
    popout.title = title

    -- Last Added Link Box (Read-only, Centered)
    local editBox = CreateFrame("EditBox", nil, popout, "InputBoxTemplate")
    editBox:SetSize(popout:GetWidth() - 100, 25)
    editBox:SetPoint("TOP", title, "BOTTOM", 0, -5)
    editBox:SetAutoFocus(false)
    editBox:SetEnabled(false) -- Read-only
    editBox:SetJustifyH("CENTER")
    popout.editBox = editBox
    addon.addItemActiveEditBox = editBox

    -- Close Button (Small X button in corner)
    local closeBtn = CreateFrame("Button", nil, popout, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    closeBtn:SetSize(24, 24)
    closeBtn:SetScript("OnClick", function()
        popout:Hide()
    end)
    popout.closeBtn = closeBtn

    addon.addItemPopout = popout
end

function addon:ToggleAddItemPopout()
    if not addon.addItemPopout then
        addon:CreateAddItemPopout(addon.mainFrame)
    end
    
    if addon.addItemPopout:IsShown() then
        addon.addItemPopout:Hide()
    else
        addon.addItemPopout:Show()
    end
end
