local addonName, addon = ...

local ROW_HEIGHT = 20
local MAX_ROWS = 15

function addon:CreateVendorItemsPopout(parentFrame)
    local popout = CreateFrame("Frame", "RichSnobsAHVendorItemsPopout", parentFrame, "BackdropTemplate")
    popout:SetWidth(300)
    popout:SetHeight(380)
    popout:SetPoint("TOPLEFT", parentFrame, "TOPRIGHT", 2, 0)
    
    popout:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    popout:SetBackdropColor(0, 0, 0, 1.0)
    popout:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    
    popout:EnableMouse(true)
    -- Just anchor it to main panel for now, or allow drag
    popout:RegisterForDrag("LeftButton")
    popout:SetScript("OnDragStart", function(self)
        if addon.mainFrame then addon.mainFrame:StartMoving() end
    end)
    popout:SetScript("OnDragStop", function(self)
        if addon.mainFrame then addon.mainFrame:StopMovingOrSizing() end
    end)
    
    popout:Hide()

    -- Title
    local title = popout:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Scanned Vendor Items")
    popout.title = title

    -- Subtitle
    local subtitle = popout:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subtitle:SetText("(These items are skipped during AH scans)")
    subtitle:SetTextColor(0.6, 0.6, 0.6)

    -- Close Button
    local closeBtn = CreateFrame("Button", nil, popout, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    closeBtn:SetSize(24, 24)
    closeBtn:SetScript("OnClick", function()
        popout:Hide()
        if addon.isAHStateOpen and addon.mainAHPanel then
            addon.mainAHPanel:Show()
        end
    end)
    popout.closeBtn = closeBtn

    -- ScrollFrame
    local scrollFrame = CreateFrame("ScrollFrame", "RichSnobsAHVendorItemsScroll", popout, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, -50)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)
    
    popout.scrollFrame = scrollFrame
    popout.rows = {}
    
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, popout)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("LEFT", 15, 0)
        row:SetPoint("RIGHT", -35, 0)
        
        if i == 1 then
            row:SetPoint("TOP", scrollFrame, "TOP", 0, 0)
        else
            row:SetPoint("TOP", popout.rows[i-1], "BOTTOM")
        end
        
        -- Delete Button
        local delBtn = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        delBtn:SetSize(20, 20)
        delBtn:SetPoint("LEFT", 0, 0)
        delBtn:SetScript("OnClick", function(self)
            if row.itemName then
                addon.db.vendorItems[row.itemName] = nil
                addon:RefreshVendorItemsPane()
            end
        end)
        row.delBtn = delBtn
        
        -- Item Name
        local nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameStr:SetPoint("LEFT", delBtn, "RIGHT", 5, 0)
        nameStr:SetPoint("RIGHT", row, "RIGHT", -80, 0)
        nameStr:SetJustifyH("LEFT")
        nameStr:SetWordWrap(false)
        row.nameStr = nameStr
        
        -- Price
        local priceStr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        priceStr:SetPoint("RIGHT", 0, 0)
        priceStr:SetJustifyH("RIGHT")
        row.priceStr = priceStr
        
        popout.rows[i] = row
    end
    
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() addon:RefreshVendorItemsPane() end)
    end)
    
    popout:SetScript("OnShow", function()
        addon:RefreshVendorItemsPane()
    end)
    
    addon.vendorItemsPopout = popout
end

function addon:ToggleVendorItemsPopout()
    if not addon.vendorItemsPopout then
        addon:CreateVendorItemsPopout(addon.mainFrame)
    end
    
    if addon.vendorItemsPopout:IsShown() then
        addon.vendorItemsPopout:Hide()
        if addon.isAHStateOpen and addon.mainAHPanel then
            addon.mainAHPanel:Show()
        end
    else
        if addon.mainAHPanel and addon.mainAHPanel:IsShown() then
            addon.mainAHPanel:Hide()
        end
        addon.vendorItemsPopout:Show()
    end
end

function addon:RefreshVendorItemsPane()
    if not addon.vendorItemsPopout or not addon.vendorItemsPopout:IsShown() then return end
    
    -- Gather items
    local items = {}
    if addon.db and addon.db.vendorItems then
        for name, price in pairs(addon.db.vendorItems) do
            table.insert(items, {name = name, price = price})
        end
    end
    
    -- Sort alphabetically
    table.sort(items, function(a, b) return a.name < b.name end)
    
    local numItems = #items
    FauxScrollFrame_Update(addon.vendorItemsPopout.scrollFrame, numItems, MAX_ROWS, ROW_HEIGHT)
    
    local offset = FauxScrollFrame_GetOffset(addon.vendorItemsPopout.scrollFrame)
    for i = 1, MAX_ROWS do
        local row = addon.vendorItemsPopout.rows[i]
        local index = offset + i
        
        if index <= numItems then
            local itemData = items[index]
            row.itemName = itemData.name
            
            row.nameStr:SetText(itemData.name)
            row.nameStr:SetTextColor(1, 1, 0) -- Yellow for vendor items
            row.priceStr:SetText(addon:FormatMoney(itemData.price))
            
            row:Show()
        else
            row.itemName = nil
            row:Hide()
        end
    end
end
