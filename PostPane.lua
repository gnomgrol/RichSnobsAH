local addonName, addon = ...

-- Create the Post Pane
function addon:CreatePostPane(parentFrame)
    local pane = CreateFrame("Frame", "RichSnobsAHPostPane", parentFrame, "BackdropTemplate")
    pane:SetAllPoints(parentFrame)
    pane:Hide()
    
    -- Title
    local title = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -15)
    title:SetText("Post Items")
    title:Hide()
    pane.title = title
    

    -- Other auctions list (replaces item selection list)
    local ahLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ahLabel:SetPoint("TOPLEFT", 15, -15)
    ahLabel:SetText("Other Auctions (Unit Price):")

    local ahScrollFrame = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    ahScrollFrame:SetPoint("TOPLEFT", 15, -30)
    ahScrollFrame:SetPoint("BOTTOMRIGHT", pane, "TOPRIGHT", -15, -180) -- Moved up and resized
    ahScrollFrame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    ahScrollFrame:SetBackdropColor(0, 0, 0, 1.0)
    
    local ahScroll = CreateFrame("ScrollFrame", "RichSnobsAHPostAHScroll", ahScrollFrame, "FauxScrollFrameTemplate")
    ahScroll:SetPoint("TOPLEFT", 5, -5)
    ahScroll:SetPoint("BOTTOMRIGHT", -25, 5)
    ahScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 20, function() addon:RefreshPostAHList() end)
    end)
    pane.ahScroll = ahScroll

    pane.ahRows = {}
    for i = 1, 7 do -- Reduced from 8 to fit smaller frame
        local row = CreateFrame("Button", nil, ahScrollFrame)
        row:SetHeight(20)
        row:SetPoint("LEFT", 5, 0)
        row:SetPoint("RIGHT", -25, 0)
        if i == 1 then
            row:SetPoint("TOP", 0, -5)
        else
            row:SetPoint("TOP", pane.ahRows[i-1], "BOTTOM")
        end
        
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", 5, 0)
        row.icon = icon

        local stackText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        stackText:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -2)
        row.stackText = stackText

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        row.text = text
        
        local price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        price:SetPoint("RIGHT", -5, 0)
        row.price = price
 
        local selectedTex = row:CreateTexture(nil, "BACKGROUND")
        selectedTex:SetAllPoints()
        selectedTex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        selectedTex:SetBlendMode("ADD")
        selectedTex:Hide()
        row.selectedTex = selectedTex
 
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        
        row:SetScript("OnClick", function()
            addon:SelectAHPrice(row.data)
        end)

        row:SetScript("OnEnter", function(self)
            if self.data and self.data.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.data.link)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        
        pane.ahRows[i] = row
    end

    -- Selected Item Info
    local selectedLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    selectedLabel:SetPoint("TOPLEFT", ahScrollFrame, "BOTTOMLEFT", 0, -5)
    selectedLabel:SetText("No item selected")
    pane.selectedLabel = selectedLabel

    -- Scan Status
    local scanStatus = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scanStatus:SetPoint("TOPLEFT", selectedLabel, "BOTTOMLEFT", 0, -2)
    scanStatus:SetText("")
    pane.scanStatus = scanStatus

    -- Pricing Info
    local priceLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    priceLabel:SetPoint("TOPLEFT", scanStatus, "BOTTOMLEFT", 0, -10)
    priceLabel:SetText("Bid: --   Buyout: --")
    pane.priceLabel = priceLabel

    -- Controls
    local stackLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stackLabel:SetPoint("TOPLEFT", priceLabel, "BOTTOMLEFT", 0, -15)
    stackLabel:SetText("Stack:")
    
    local stackSizeEdit = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    stackSizeEdit:SetSize(35, 20)
    stackSizeEdit:SetPoint("LEFT", stackLabel, "RIGHT", 5, 0)
    stackSizeEdit:SetAutoFocus(false)
    stackSizeEdit:SetText("1")
    pane.stackSizeEdit = stackSizeEdit

    local stackMaxBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    stackMaxBtn:SetSize(35, 18)
    stackMaxBtn:SetPoint("LEFT", stackSizeEdit, "RIGHT", 2, 0)
    stackMaxBtn:SetText("Max")
    stackMaxBtn:SetNormalFontObject("GameFontNormalSmall")
    stackMaxBtn:SetScript("OnClick", function()
        if pane.selectedItem then
            local _, _, _, _, _, _, _, stack = GetItemInfo(pane.selectedItem.link)
            stackSizeEdit:SetText(tostring(stack or 1))
            addon:UpdatePostButtonText()
        end
    end)

    local numStacksLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    numStacksLabel:SetPoint("LEFT", stackMaxBtn, "RIGHT", 10, 0)
    numStacksLabel:SetText("Num:")

    local numStacksEdit = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    numStacksEdit:SetSize(35, 20)
    numStacksEdit:SetPoint("LEFT", numStacksLabel, "RIGHT", 5, 0)
    numStacksEdit:SetAutoFocus(false)
    numStacksEdit:SetText("1")
    pane.numStacksEdit = numStacksEdit

    local numMaxBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    numMaxBtn:SetSize(35, 18)
    numMaxBtn:SetPoint("LEFT", numStacksEdit, "RIGHT", 2, 0)
    numMaxBtn:SetText("Max")
    numMaxBtn:SetNormalFontObject("GameFontNormalSmall")
    numMaxBtn:SetScript("OnClick", function()
        if pane.selectedItem then
            local totalCount = 0
            for b = 0, 4 do
                local numSlots = (C_Container and C_Container.GetContainerNumSlots(b)) or (_G.GetContainerNumSlots and _G.GetContainerNumSlots(b)) or GetContainerNumSlots(b)
                for s = 1, numSlots do
                    local link
                    if C_Container and C_Container.GetContainerItemLink then
                        link = C_Container.GetContainerItemLink(b, s)
                    else
                        link = GetContainerItemLink(b, s)
                    end
                    if link and link:find("item:" .. (pane.selectedItem.link:match("item:(%d+)") or ""), 1, true) then
                        local count
                        if C_Container and C_Container.GetContainerItemInfo then
                            local info = C_Container.GetContainerItemInfo(b, s)
                            count = info and info.stackCount or 0
                        else
                            local _, itemCount = GetContainerItemInfo(b, s)
                            count = itemCount or 0
                        end
                        totalCount = totalCount + count
                    end
                end
            end
            
            local stackSize = tonumber(stackSizeEdit:GetText()) or 1
            numStacksEdit:SetText(tostring(math.max(1, math.floor(totalCount / stackSize))))
            addon:UpdatePostButtonText()
        end
    end)

    stackSizeEdit:SetScript("OnTextChanged", function() addon:UpdatePostButtonText() end)
    numStacksEdit:SetScript("OnTextChanged", function() addon:UpdatePostButtonText() end)

    local postBtn = CreateFrame("Button", "RichSnobsAHPostButton", pane, "SecureActionButtonTemplate, UIPanelButtonTemplate")
    postBtn:SetSize(160, 22)
    postBtn:SetPoint("BOTTOM", 0, 15)
    postBtn:SetText("Post Auction")
    postBtn:SetAttribute("type", "click")
    postBtn:SetScript("PreClick", function() addon:ExecutePostPreparation() end)

    pane.postBtn = postBtn
    
    -- Drop to Sell Field
    local sellDrop = CreateFrame("Button", "RichSnobsAHSellDrop", pane, "BackdropTemplate")
    sellDrop:SetSize(40, 40)
    sellDrop:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -15, 100)
    sellDrop:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    sellDrop:SetBackdropColor(0, 0.4, 0, 0.6)
    
    local sellDropIcon = sellDrop:CreateTexture(nil, "ARTWORK")
    sellDropIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_11")
    sellDropIcon:SetAllPoints(sellDrop)
    sellDrop.icon = sellDropIcon
    
    local sellDropText = sellDrop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sellDropText:SetPoint("BOTTOM", sellDrop, "TOP", 0, 2)
    sellDropText:SetText("Sell")
    
    sellDrop:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Quick Sell Item", 1, 1, 1)
        GameTooltip:AddLine("Drop an item here or click with an item on your cursor to prepare it for selling.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    sellDrop:SetScript("OnLeave", function() GameTooltip:Hide() end)
    
    local function HandleItemDrop()
        local infoType, itemID, itemLink = GetCursorInfo()
        if infoType == "item" and itemLink then
            ClearCursor()
            addon:SelectPostItem({link = itemLink})
        end
    end
    
    sellDrop:SetScript("OnReceiveDrag", HandleItemDrop)
    sellDrop:SetScript("OnClick", HandleItemDrop)

    -- Event listener for combat end to apply pending button states
    local combatFrame = CreateFrame("Frame")
    combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatFrame:SetScript("OnEvent", function()
        if pane.postBtn and pane.postBtn.pendingEnabledState ~= nil then
            if pane.postBtn.pendingEnabledState then
                pane.postBtn:Enable()
            else
                pane.postBtn:Disable()
            end
            pane.postBtn.pendingEnabledState = nil
        end
    end)
    pane.combatFrame = combatFrame

    addon.postPane = pane
end

function addon:SafeSetBtnEnabled(button, enabled)
    if not button then return end
    if InCombatLockdown() then
        button.pendingEnabledState = enabled
    else
        if enabled then
            button:Enable()
        else
            button:Disable()
        end
        button.pendingEnabledState = nil
    end
end


function addon:ShowPostPane(item)
    if not self.postPane then return end    
    
    -- Switch to the Post tab in the AH panel
    self:SelectAHPanelTab(3)
    

    
    if item then
        self:SelectPostItem(item)
    end
end

function addon:SelectPostItem(item)
    if not item or not self.postPane then return end
    
    self.postPane.selectedItem = item
    self.postPane.selectedLabel:SetText("Posting: " .. (item.link or "Unknown"))
    
    -- Add tooltip to selected label as well
    if not self.postPane.selectedItemBtn then
        local btn = CreateFrame("Button", nil, self.postPane)
        btn:SetAllPoints(self.postPane.selectedLabel)
        btn:SetScript("OnEnter", function(self)
            if addon.postPane.selectedItem and addon.postPane.selectedItem.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(addon.postPane.selectedItem.link)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.postPane.selectedItemBtn = btn
    end
    
    -- Reset price data
    self.postPane.suggestedBuyout = nil
    self.postPane.suggestedBid = nil
    self.postPane.selectedAHData = nil
    if self.postPane.priceLabel then
        self.postPane.priceLabel:SetText("Bid: --   Buyout: --")
    end
    
    -- Determine default stack size
    local itemName = GetItemInfo(item.link)
    local defaultStack = 1
    if itemName then
        local _, _, _, _, _, _, _, stack = GetItemInfo(item.link)
        defaultStack = stack or 1
    end
    
    -- Count total in bags
    local totalCount = self:GetBagItemCount(item.link)
    
    -- Use smaller of default stack or total count as initial stack size
    local initialStack = math.min(defaultStack, totalCount)
    if initialStack < 1 then initialStack = 1 end
    
    self.postPane.stackSizeEdit:SetText(tostring(initialStack))
    self.postPane.numStacksEdit:SetText(tostring(math.max(1, math.floor(totalCount / initialStack))))
    
    -- Start AH scan for prices
    if itemName then
        self.isPostScan = true
        self:ScanForItemPrice(itemName)
    end

    self:UpdatePostButtonText()
end

function addon:UpdatePostButtonText()
    if not self.postPane or not self.postPane.selectedItem then return end
    
    local numStacks = tonumber(self.postPane.numStacksEdit:GetText()) or 0
    local stackSize = tonumber(self.postPane.stackSizeEdit:GetText()) or 1
    
    if self.postPane.postBtn then
        self.postPane.postBtn:SetText(string.format("Post Auction (%d left)", numStacks))
        if numStacks <= 0 then
            self:SafeSetBtnEnabled(self.postPane.postBtn, false)
        else
            -- Only enable if we actually have enough items for at least one stack in BAGS
            local totalCount = self:GetBagItemCount(self.postPane.selectedItem.link)

            if totalCount >= stackSize then
                self:SafeSetBtnEnabled(self.postPane.postBtn, true)
            else
                self:SafeSetBtnEnabled(self.postPane.postBtn, false)
            end
        end
    end
end

-- Refresh the AH results list in the post pane
function addon:RefreshPostAHList()
    if not self.postPane or not self.postPane:IsShown() then return end
    
    local results = self.postPane.ahResults or {}
    
    FauxScrollFrame_Update(self.postPane.ahScroll, #results, 7, 20)
    local offset = FauxScrollFrame_GetOffset(self.postPane.ahScroll)
    
    for i = 1, 7 do
        local row = self.postPane.ahRows[i]
        local index = offset + i
        if index <= #results then
            local data = results[index]
            row.icon:SetTexture(data.texture or "Interface\\Icons\\Inv_Misc_QuestionMark")
            row.stackText:SetText(data.count > 1 and data.count or "")
            
                        local nameText = data.owner or "Unknown"
            if data.owner == UnitName("player") then
                nameText = "|cff00ff00" .. nameText .. "|r"
            end
            if data.quantity and data.quantity > 1 then
                nameText = nameText .. " (" .. data.quantity .. ")"
            end
            row.text:SetText(nameText)
            
            row.price:SetText(self:FormatMoney(data.unitPrice))
            row.data = data
            
            if self.postPane.selectedAHData == data then
                row.selectedTex:Show()
            else
                row.selectedTex:Hide()
            end
            
            row:Show()
        else
            row:Hide()
        end
    end
end

-- Select a price from the AH list to use for undercutting
function addon:SelectAHPrice(data)
    if not data then return end
    
    -- Re-enable post button if it was disabled from a failed/incomplete attempt
    if self.postPane.postBtn then
        self:SafeSetBtnEnabled(self.postPane.postBtn, true)
    end

    -- Use this unit price as the base for undercutting
    local unitPrice = data.unitPrice
    local unitBid = data.unitBid or unitPrice
    
    -- Undercut by 1 copper (ensure it's integer)
    local suggestedBuyout = math.floor(unitPrice - 1)
    if suggestedBuyout < 1 then suggestedBuyout = 1 end
    
    -- Bid: undercut target bid by 1 copper, but cap at buyout
    local suggestedBid = math.floor(unitBid - 1)
    if suggestedBid < 1 then suggestedBid = 1 end
    if suggestedBid > suggestedBuyout then suggestedBid = suggestedBuyout end
    
    self.postPane.suggestedBuyout = suggestedBuyout
    self.postPane.suggestedBid = suggestedBid
    self.postPane.selectedAHData = data
    
    if self.postPane.priceLabel then
        self.postPane.priceLabel:SetText(string.format("Bid: %s   Buyout: %s", self:FormatMoney(suggestedBid), self:FormatMoney(suggestedBuyout)))
    end
    
    self:RefreshPostAHList()
    self:UpdatePostButtonText()
end

-- Scan for item price
function addon:ScanForItemPrice(itemName)
    local canQuery = CanSendAuctionQuery()
    if not canQuery then
        self.postPane.scanStatus:SetText("|cffff0000Throttled (Wait)|r")
        C_Timer.After(1.0, function() addon:ScanForItemPrice(itemName) end)
        return
    end

    self.postPane.scanStatus:SetText("Scanning for lowest price...")
    self.postPane.ahResults = {}
    self:RefreshPostAHList()
    self.postScanRetryCount = 0

    local scanFrame = CreateFrame("Frame")
    scanFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    
    local timeout
    timeout = C_Timer.After(5, function()
        scanFrame:UnregisterAllEvents()
        self.isPostScan = false
        if self.postPane:IsShown() then
            self.postPane.scanStatus:SetText("Scan timed out.")
        end
    end)

    scanFrame:SetScript("OnEvent", function(frame, event, arg1)
        local batchCount, totalCount = GetNumAuctionItems("list")
        
        if totalCount == 0 and batchCount == 0 then
            -- In Classic, 0/0 can mean loading or actually empty.
            -- We retry a few times before giving up.
            self.postScanRetryCount = (self.postScanRetryCount or 0) + 1
            if self.postScanRetryCount < 3 then
                return -- Wait for next event or timeout
            end
            -- If we retried enough and still 0/0, assume it's actually empty
        end
        
        if timeout then
            timeout:Cancel()
        end
        
        -- Small delay to let item/owner info cache
        C_Timer.After(0.1, function()
            scanFrame:UnregisterAllEvents()
            self:ProcessPostScanResults(itemName)
        end)
    end)

    -- Ensure sorting is correct before querying
    addon:SetAHBuyoutSort()
    
    QueryAuctionItems(itemName, nil, nil, 0, nil, nil, false, true)
end

function addon:ProcessPostScanResults(itemName)
    local batchCount, totalCount = GetNumAuctionItems("list")
    local minBuyoutUnit = nil
    local minBidUnit = nil
    local results = {}
    local groupedMap = {}

    for i = 1, batchCount do
        local name, texture, count, _, _, _, _, bid, _, buyout, _, _, _, owner = GetAuctionItemInfo("list", i)
        local itemLink = GetAuctionItemLink("list", i)
        
        -- Only include auctions with buyout price
        if name == itemName and buyout and buyout > 0 then
            local unitPrice = buyout / count
            local unitBid = (bid or buyout) / count
            
            -- Grouping key: price + bid + owner + stack size
            local ownerName = owner or "Unknown"
            local key = string.format("%.4f_%.4f_%s_%d", unitPrice, unitBid, ownerName, count)
            
            if groupedMap[key] then
                groupedMap[key].quantity = groupedMap[key].quantity + 1
            else
                local data = {
                    owner = ownerName,
                    unitPrice = unitPrice,
                    unitBid = unitBid,
                    count = count,
                    buyout = buyout,
                    bid = bid,
                    texture = texture,
                    link = itemLink,
                    quantity = 1
                }
                groupedMap[key] = data
                table.insert(results, data)
            end
            
            if ownerName ~= UnitName("player") then
                if not minBuyoutUnit or unitPrice < minBuyoutUnit then
                    minBuyoutUnit = unitPrice
                    minBidUnit = unitBid
                end
            end
        end
    end
    
    -- Sort results by unit price
    table.sort(results, function(a, b)
        if a.unitPrice ~= b.unitPrice then
            return a.unitPrice < b.unitPrice
        end
        return a.unitBid < b.unitBid
    end)
    self.postPane.ahResults = results
    
    -- Auto-select the cheapest non-player auction to undercut
    local cheapestNonPlayer = nil
    for _, data in ipairs(results) do
        if data.owner ~= UnitName("player") then
            cheapestNonPlayer = data
            break
        end
    end
    
    if cheapestNonPlayer then
        self:SelectAHPrice(cheapestNonPlayer)
        self.postPane.scanStatus:SetText("Scan complete.")
    elseif #results > 0 then
        -- All auctions are ours, just select the first one as reference
        self:SelectAHPrice(results[1])
        self.postPane.scanStatus:SetText("Only your auctions found.")
    else
        self.postPane.scanStatus:SetText("No other auctions found.")
    end
    self:RefreshPostAHList()
    self:UpdatePostButtonText()
    self.isPostScan = false
end

-- Execute the preparation for posting (putting item in slot and setting prices)
-- This is called during PreClick for the SecureActionButton
function addon:ExecutePostPreparation()
    local pane = self.postPane
    if not pane.selectedItem or not pane.suggestedBuyout then
        return
    end

    -- Item finding logic follows; disable button only if item is confirmed


    local stackSize = tonumber(pane.stackSizeEdit:GetText()) or 1
    local numStacks = tonumber(pane.numStacksEdit:GetText()) or 1
    local itemName = GetItemInfo(pane.selectedItem.link)
    
    -- Find the item in bags
    local bag, slot = nil, nil
    
    for b = 0, 4 do
        local numSlots = (C_Container and C_Container.GetContainerNumSlots(b)) or (_G.GetContainerNumSlots and _G.GetContainerNumSlots(b)) or GetContainerNumSlots(b)
        for s = 1, numSlots do
            local itemLink, count, isLocked
            if C_Container and C_Container.GetContainerItemLink then
                itemLink = C_Container.GetContainerItemLink(b, s)
                local info = C_Container.GetContainerItemInfo(b, s)
                count = info and info.stackCount or 0
                isLocked = info and info.isLocked
            else
                itemLink = GetContainerItemLink(b, s)
                local _, itemCount, itemLocked = GetContainerItemInfo(b, s)
                count = itemCount or 0
                isLocked = itemLocked
            end

            if itemLink and itemLink:find(itemName, 1, true) and not isLocked then
                if count >= stackSize then
                    bag, slot = b, s
                    break
                end
            end
        end
        if bag then break end
    end

    if not bag then
        addon.print("Item not found in bags.")
        if pane.postBtn then self:SafeSetBtnEnabled(pane.postBtn, true) end
        return
    end

    -- Disable button now that we are sure we can post
    if pane.postBtn then
        self:SafeSetBtnEnabled(pane.postBtn, false)
    end

    -- Place item in slot
    ClearCursor()
    if C_Container and C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bag, slot)
    else
        PickupContainerItem(bag, slot)
    end
    ClickAuctionSellItemButton()
    ClearCursor()

    -- Set Prices and sync Blizzard UI
    local totalBuyout = pane.suggestedBuyout * stackSize
    local totalBid = pane.suggestedBid * stackSize
    
    local startPriceFrame = _G.StartPrice
    local buyoutPriceFrame = _G.BuyoutPrice
    
    if startPriceFrame then MoneyInputFrame_SetCopper(startPriceFrame, totalBid) end
    if buyoutPriceFrame then MoneyInputFrame_SetCopper(buyoutPriceFrame, totalBuyout) end
    
    local totalBid = pane.suggestedBid * stackSize
    local totalBuyout = pane.suggestedBuyout * stackSize
    PostAuction(totalBid, totalBuyout, 1, stackSize, 1, true)

    -- Post message sent; count will be updated on confirmation in AHResults.lua
end
