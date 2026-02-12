local addonName, addon = ...

-- AH Results Pane Constants
local AH_ROW_HEIGHT = 25
local MAX_AH_ROWS = 11

-- State
addon.ahResultsVisible = false
addon.ahSearchResults = {}
addon.ahCurrentSearchName = nil
addon.ahIsBuying = false
addon.ahPendingItem = nil
addon.ahCurrentPage = 0
addon.ahTotalPages = 0
addon.groupedResultsMap = {}

-- Create a persistent event frame for purchase and post success/failure
local auctionEventFrame = CreateFrame("Frame")
auctionEventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
auctionEventFrame:RegisterEvent("UI_ERROR_MESSAGE")
auctionEventFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
auctionEventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
auctionEventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "AUCTION_ITEM_LIST_UPDATE" then
        if addon.ahIsBuying and addon.ahPendingItem then
            addon:CheckForPendingPurchase()
        end

    elseif event == "AUCTION_HOUSE_CLOSED" then
        if addon.ahIsBuying then
            addon:ResetPurchaseState()
            addon:UpdateStatusText("AH Closed")
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = arg1
        
        -- Handle Post Success
        if msg == ERR_AUCTION_STARTED then
            if addon.postPane and addon.postPane.postBtn then
                -- Decrement the count in the edit box
                local numStacks = tonumber(addon.postPane.numStacksEdit:GetText()) or 0
                if numStacks > 0 then
                    addon.postPane.numStacksEdit:SetText(tostring(numStacks - 1))
                end
                
                -- Wait a tiny bit for the internal counts to be updated
                C_Timer.After(0.1, function()
                    addon:UpdatePostButtonText()
                end)
            end
        end

        if not addon.ahIsBuying or not addon.ahPendingItem then return end
        
        -- Detect win
        local winPattern = (ERR_AUCTION_WON_S or "You won an auction for %s"):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"):gsub("%%%%s", "(.+)")
        local itemNameInMsg = winPattern and msg:find(winPattern)
        local isWon = msg:find("You won") or msg:find("win")
        local bidAcceptMsg = ERR_AUCTION_BID_ACCEPT or "Bid accepted"
        local isBid = msg:find(bidAcceptMsg) or msg:find("bid has been accepted")
        local itemNameMatch = (addon.ahPendingItem and addon.ahPendingItem.name) and msg:find(addon.ahPendingItem.name)

        if itemNameInMsg or (isWon and itemNameMatch) or (isBid and itemNameMatch) then
            local pendingItem = addon.ahPendingItem
            addon:ResetPurchaseState() -- Clears ahIsBuying/ahPendingItem

            if isBid and not isWon then
                addon:UpdateStatusText("Bid placed (No buyout!)")
                addon.print("Warning: Only a bid was placed for " .. (pendingItem.name or "item") .. ". No buyout occurred.")
            else
                addon:UpdateStatusText("Purchase confirmed!")
                addon.lastPurchaseSuccessTime = GetTime()
            end
            
            -- Also clear purchaseTime on the pending item so we don't double-suppress or keep it too long
            pendingItem.purchaseTime = nil

            -- Increment items bought counter if it was a win
            if isWon or not isBid then
                local stackSize = pendingItem.count or 1
                addon.itemsBought = (addon.itemsBought or 0) + stackSize
            end
            
            -- Update quantity or remove from list
            pendingItem.quantity = (pendingItem.quantity or 1) - 1
            if pendingItem.quantity <= 0 then
                for i, res in ipairs(addon.ahSearchResults or {}) do
                    if res == pendingItem then
                        table.remove(addon.ahSearchResults, i)
                        -- Auto-select next item at the same index
                        local nextItem = addon.ahSearchResults[i] or addon.ahSearchResults[i-1]
                        if nextItem then
                            C_Timer.After(0.1, function() addon:SelectResult(nextItem) end)
                        end
                        break
                    end
                end
            else
                -- If item still has quantity, re-verify it for the next click
                C_Timer.After(0.1, function() addon:SelectResult(pendingItem) end)
            end
            return
        end

        -- Detect higher bid (sniped)
        if msg == ERR_AUCTION_HIGHER_BID or msg:find("higher bid") or msg:find("already a bid") then
            local pendingItem = addon.ahPendingItem
            addon:ResetPurchaseState()

            addon:UpdateStatusText("Higher bid / Sniped!")
            addon.print("Someone already placed a higher bid or sniped the item.")
            
            -- Remove from list as it's no longer available at that price
            for i, res in ipairs(addon.ahSearchResults or {}) do
                if res == pendingItem then
                    table.remove(addon.ahSearchResults, i)
                    local nextItem = addon.ahSearchResults[i] or addon.ahSearchResults[i-1]
                    if nextItem then
                        C_Timer.After(0.1, function() addon:SelectResult(nextItem) end)
                    end
                    break
                end
            end
        end

    elseif event == "UI_ERROR_MESSAGE" then
        -- arg1 is error ID, arg2 is message string (in most versions)
        -- but sometimes arg1 is the message. We check both.
        local msg = (type(arg1) == "string") and arg1 or arg2
        if not msg or type(msg) ~= "string" then return end

        -- Handle Post Failure
        if addon.postPane and addon.postPane.postBtn then
            addon:SafeSetBtnEnabled(addon.postPane.postBtn, true)
        end

        -- Handle common auction errors (throttling, not found, etc)
        if not addon.ahIsBuying or not addon.ahPendingItem then return end

        local pendingItem = addon.ahPendingItem

        local shouldRemove = false
        -- ERR_AUCTION_NOT_FOUND is usually "The item was not found"
        if msg == ERR_AUCTION_NOT_FOUND or msg:find("not found") then
                addon:ResetPurchaseState()
                addon:UpdateStatusText("Item not found (Gone)")
                shouldRemove = true
        elseif msg == ERR_AUCTION_DATABASE_ERROR or msg:find("Auction House") then
                -- AH Database error or general AH error
                addon:ResetPurchaseState()
                addon:UpdateStatusText("AH Error")
        else
                -- Catch-all for other errors while buying
                addon:ResetPurchaseState()
                addon:UpdateStatusText("Failed: " .. msg)
        end
        
        addon.print("Purchase failed for " .. (pendingItem.name or "item") .. ": " .. msg)
        
        -- Remove from list ONLY if it's truly gone
        if shouldRemove then
            for i, res in ipairs(addon.ahSearchResults or {}) do
                if res == pendingItem then
                    table.remove(addon.ahSearchResults, i)
                    local nextItem = addon.ahSearchResults[i] or addon.ahSearchResults[i-1]
                    if nextItem then
                        C_Timer.After(0.1, function() addon:SelectResult(nextItem) end)
                    end
                    break
                end
            end
        end
    end
end)

function addon:ResetPurchaseState()
    if addon.purchaseTimeoutTimer then
        addon.purchaseTimeoutTimer:Cancel()
        addon.purchaseTimeoutTimer = nil
    end
    if addon.purchasePollingTicker then
        addon.purchasePollingTicker:Cancel()
        addon.purchasePollingTicker = nil
    end
    
    -- Immediately clear pending item to prevent multiple outcome processing
    local pendingItem = addon.ahPendingItem
    addon.ahPendingItem = nil

    -- targeted caching pruning to prevent ghosts:
    -- Remove the item we just bought/failed from all cached pages
    if pendingItem and pendingItem.key then
        local key = pendingItem.key
        if addon.pageResults then
            for pageNum, pRes in pairs(addon.pageResults) do
                if pRes[key] then
                    pRes[key] = nil
                end
            end
        end
    end
    
    -- Reset state immediately to allow rapid subsequent purchases
    addon.ahIsBuying = false
    addon.ahIsBidPlaced = false
    addon.ahReadyToBuy = false
    addon.ahTriedPageZeroFallback = false
    addon.lastPurchaseSuccessTime = GetTime() 
    
    -- Force a refresh to update button state
    addon:RefreshAHResults()
    
    -- If we still have a selection, verify it again
    if addon.ahSelectedResult then
        addon:VerifySelectedItem()
    end
end

-- Create the expandable AH results pane
function addon:CreateAHResultsPane(parentFrame)
    local pane = CreateFrame("Frame", "RichSnobsAHResultsPane", parentFrame, "BackdropTemplate")
    pane:SetAllPoints(parentFrame)
    pane:Hide()
    
    -- Progress text
    local progress = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    progress:SetPoint("TOPLEFT", 15, -25)
    progress:SetText("Idle")
    pane.progress = progress

    -- Search EditBox
    local searchEdit = CreateFrame("EditBox", "RichSnobsAHSearchEdit", pane, "InputBoxTemplate")
    searchEdit:SetSize(200, 20)
    searchEdit:SetPoint("TOPLEFT", 17, -2)
    searchEdit:SetAutoFocus(false)
    searchEdit:SetText("")
    searchEdit:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        if text and text ~= "" then
            addon:SearchAH(text, false) -- isExact = false for manual searches
            self:ClearFocus()
        end
    end)
    pane.searchEdit = searchEdit

    -- Fast Scan Checkbox
    local fastScanCB = CreateFrame("CheckButton", "RichSnobsAHFastScanCB", pane, "InterfaceOptionsCheckButtonTemplate")
    fastScanCB:SetPoint("LEFT", searchEdit, "RIGHT", 10, 0)
    fastScanCB:SetSize(24, 24)
    _G[fastScanCB:GetName() .. "Text"]:SetText("Fast scan")
    fastScanCB:SetScript("OnClick", function(self)
        addon.db.fastScan = self:GetChecked()
    end)
    fastScanCB:SetScript("OnShow", function(self)
        self:SetChecked(addon.db.fastScan)
    end)
    pane.fastScanCB = fastScanCB
    
    -- Search Button
    local searchBtn = CreateFrame("Button", nil, pane, "GameMenuButtonTemplate")
    searchBtn:SetSize(80, 22)
    searchBtn:SetPoint("LEFT", fastScanCB, "RIGHT", 75, 0)
    searchBtn:SetText("Search")
    searchBtn:SetNormalFontObject("GameFontNormalSmall")
    searchBtn:SetHighlightFontObject("GameFontHighlightSmall")
    searchBtn:SetScript("OnClick", function()
        local text = searchEdit:GetText()
        if text and text ~= "" then
            addon:SearchAH(text, false)
            searchEdit:ClearFocus()
        end
    end)
    pane.searchBtn = searchBtn

    -- Items bought indicator
    local itemsBought = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itemsBought:SetPoint("BOTTOMRIGHT", -15, 15)
    itemsBought:SetText("")
    pane.itemsBought = itemsBought

    -- Current AH Page indicator
    local currentPage = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    currentPage:SetPoint("BOTTOMRIGHT", -15, 38)
    currentPage:SetTextColor(0.7, 0.7, 0.7)
    currentPage:SetText("")
    pane.currentPage = currentPage

    -- Status text
    local statusText = pane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("BOTTOMLEFT", 15, 38)
    statusText:SetTextColor(1, 0.82, 0) -- Gold color
    statusText:SetText("")
    pane.statusText = statusText

    -- Results container with scroll
    local resultsFrame = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    resultsFrame:SetPoint("TOPLEFT", 10, -38) 
    resultsFrame:SetPoint("BOTTOMRIGHT", -10, 50)
    resultsFrame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    resultsFrame:SetBackdropColor(0, 0, 0, 1.0)
    resultsFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    resultsFrame:SetClipsChildren(true)
    
    -- Scroll frame
    local scroll = CreateFrame("ScrollFrame", "RichSnobsAHResultsScroll", resultsFrame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 5, -5)
    scroll:SetPoint("BOTTOMRIGHT", -25, 5) -- Fixed: moved in slightly to prevent overlap
    
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, AH_ROW_HEIGHT, function() addon:RefreshAHResults() end)
    end)
    
    pane.scroll = scroll
    
    -- Create result rows
    pane.rows = {}
    for i = 1, MAX_AH_ROWS do
        local row = CreateFrame("Button", nil, resultsFrame)
        row:SetHeight(AH_ROW_HEIGHT)
        row:SetPoint("LEFT", 5, 0)
        row:SetPoint("RIGHT", -25, 0)
        if i == 1 then
            row:SetPoint("TOP", 0, -5)
        else
            row:SetPoint("TOP", pane.rows[i-1], "BOTTOM", 0, 0)
        end
        
        -- Stack Size (before icon)
        local stackSize = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        stackSize:SetPoint("LEFT", 2, 0)
        stackSize:SetWidth(26)
        stackSize:SetJustifyH("RIGHT")
        row.stackSize = stackSize
        
        -- Icon
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(AH_ROW_HEIGHT - 4, AH_ROW_HEIGHT - 4)
        icon:SetPoint("LEFT", stackSize, "RIGHT", 2, 0)
        row.icon = icon
        
        -- Stack Count (e.g. [10] for 10 stacks)
        local stackCount = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        stackCount:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        stackCount:SetWidth(32)
        stackCount:SetJustifyH("LEFT")
        stackCount:SetTextColor(0.7, 0.7, 0.7)
        row.stackCount = stackCount

        -- Unit Price (Gold) - Locked to Right
        local unitPrice = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        unitPrice:SetPoint("RIGHT", -5, 0)
        unitPrice:SetWidth(70)
        unitPrice:SetJustifyH("RIGHT")
        row.unitPrice = unitPrice

        -- Seller Name - Locked to Left of Unit Price
        local seller = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        seller:SetPoint("RIGHT", unitPrice, "LEFT", -10, 0)
        seller:SetWidth(65)
        seller:SetJustifyH("LEFT")
        row.seller = seller

        -- Item Name - Filling the middle
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", stackCount, "RIGHT", 10, 0)
        name:SetPoint("RIGHT", seller, "LEFT", -10, 0)
        name:SetJustifyH("LEFT")
        row.name = name
        
        
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        
        -- Selection Highlight
        local selection = row:CreateTexture(nil, "BACKGROUND")
        selection:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        selection:SetBlendMode("ADD")
        selection:SetVertexColor(0, 1, 0, 0.4)
        selection:SetAllPoints(row)
        selection:Hide()
        row.selection = selection



        
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        
        row:SetScript("OnEnter", function(self)
            if self.data and self.data.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.data.link)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnClick", function(self)
            if self.data then
                if IsShiftKeyDown() and addon.addItemActiveEditBox and addon.addItemActiveEditBox:IsVisible() then
                    addon:AddItemFromLink(self.data.link)
                else
                    addon:SelectResult(self.data)
                end
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        
        row:Hide()
        
        pane.rows[i] = row
    end
    
    local noResults = pane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noResults:SetPoint("CENTER", resultsFrame, "CENTER")
    noResults:SetText("No auctions found")
    noResults:Hide()
    pane.noResults = noResults
    
    -- Global Buy Button
    local globalBuyBtn = CreateFrame("Button", nil, pane, "GameMenuButtonTemplate")
    globalBuyBtn:SetWidth(160)
    globalBuyBtn:SetHeight(25)
    globalBuyBtn:SetPoint("BOTTOM", 0, 10)
    globalBuyBtn:SetText("Buy Selected")
    globalBuyBtn:Disable()
    globalBuyBtn:SetScript("OnClick", function(self)
        if addon.ahSelectedResult then
            addon:InitiateBuy(addon.ahSelectedResult)
        end
    end)
    pane.globalBuyBtn = globalBuyBtn
    
    addon.ahResultsPane = pane
    addon:RefreshAHResults() -- Initialize with empty state (hides rows)
end

-- Helper: Collapse default AH
function addon:CollapseAH()
    -- Logic removed as per user request
end

-- Helper: Restore default AH
function addon:RestoreAH()
    -- Logic removed as per user request
end

function addon:StopNormalScan()
    -- Only unregister events in HideAHResults, not when stopping a scan for purchase!
    -- if addon.ahEventFrame then
    --    addon.ahEventFrame:UnregisterAllEvents()
    -- end
    if addon.ahScanTimeoutTimer then
        addon.ahScanTimeoutTimer:Cancel()
        addon.ahScanTimeoutTimer = nil
    end
    if addon.pendingSearchTimer then
        addon.pendingSearchTimer:Cancel()
        addon.pendingSearchTimer = nil
    end
    if addon.navigationRetryTimer then
        addon.navigationRetryTimer:Cancel()
        addon.navigationRetryTimer = nil
    end
    addon.pendingSearch = nil
    -- addon.ahCurrentSearchName = nil -- FIXED: Preserve this for purchase navigation!
    addon.ahIsBuying = false
    addon.ahIsScanning = false -- Ensure we stop processing events
    addon.isPostScan = false
    addon.isUndercutScan = false
end

-- Helper: Ensure AH is sorted by buyout unit price (lowest first)
function addon:SetAHBuyoutSort()
    -- Classic Era/Anniversary API for sorting: SortAuctionSetSort(case, "column", reverse)
    -- Some modern Classic clients support "unitprice" or "buyout".
    -- We'll try them defensively.
    if SortAuctionSetSort then
        -- Try "unitprice" (per-item buyout) first
        local success = pcall(SortAuctionSetSort, "list", "unitprice", false)
        if not success then
            -- Fallback to "buyout" (total buyout)
            pcall(SortAuctionSetSort, "list", "buyout", false)
        end
    elseif SortAuctionItems then
        -- Legacy API fallback
        pcall(SortAuctionItems, "list", "buyout")
    end
end

function addon:ClearAHResultsState()
    addon.ahSearchResults = {}
    addon.pageResults = {}
    addon.groupedResultsMap = {}
    addon.ahCurrentPage = 0
    addon.ahTotalPages = 0
    addon.ahLastProcessedPage = -1
    addon.ahLastPageHash = ""
    addon.ahWaitingForPageUpdate = false
    addon.ahIsScanning = false
end

-- Search AH for an item
function addon:SearchAH(link, isExact)
    -- Switch to the Buy tab to show results
    self:SelectAHPanelTab(1)
    
    if not link then return end
    if isExact == nil then isExact = true end

    -- Resolve name
    local name = GetItemInfo(link)
    if not name then 
        name = link:match("%[(.-)%]") or link 
    end
    
    -- Sync search bar text
    if addon.ahResultsPane and addon.ahResultsPane.searchEdit then
        addon.ahResultsPane.searchEdit:SetText(name)
    end

    -- IMMEDIATELY stop any ongoing scan/pane activity and clear results
    addon:StopNormalScan()
    addon:ClearAHResultsState()
    addon:RefreshAHResults() -- Clear the UI immediately
    
    if addon.ahResultsPane then
        addon.ahResultsPane.progress:SetText("Initiating search...")
        addon.ahResultsPane.currentPage:SetText("")
    end

    if addon.undercutPane and addon.undercutPane:IsShown() then
        addon.undercutPane:Hide()
    end
    if addon.postPane and addon.postPane:IsShown() then
        addon.postPane:Hide()
    end

    -- Check if we can send a query (throttling)
    local canQuery, canGetAll = CanSendAuctionQuery()
    if not canQuery then
        addon.print("Search throttled. Retrying in 1s...")
        if addon.ahResultsPane then
            addon:UpdateStatusText("|cffff0000Throttled (Wait)|r")
            addon.ahResultsPane.progress:SetText("|cffffff00Throttled (Auto-retry)|r")
        end
        
        -- Store pending search and schedule retry
        addon.pendingSearch = { link = link, isExact = isExact }
        if not addon.pendingSearchTimer then
            addon.pendingSearchTimer = C_Timer.NewTicker(1.0, function()
                if addon.pendingSearch then
                    local pLink = addon.pendingSearch.link
                    local pExact = addon.pendingSearch.isExact
                    -- Attempt to search again
                    addon:SearchAH(pLink, pExact)
                end
            end)
        end
        return
    end

    -- Clear pending search if we successfully proceeded
    if addon.pendingSearchTimer then
        addon.pendingSearchTimer:Cancel()
        addon.pendingSearchTimer = nil
    end
    addon.pendingSearch = nil

    -- Check if AH is open
    local ahOpen = addon:IsAHOpen()
    if not ahOpen then
        addon.print("Auction House is not open.")
        return
    end

    addon.ahCurrentSearchName = name
    addon.ahCurrentSearchIsExact = isExact
    addon.ahIsScanning = true -- Set THIS as the actual scan start signal
    addon.ahCurrentPage = 0
    addon.ahLastProcessedPage = -1
    addon.ahPageBufferWaitCount = 0
    addon.ahQueryCountForPage = 1
    addon.ahWaitingForPageUpdate = true
    addon.ahLastQueryTime = GetTime()
    addon.itemsBought = 0 -- Reset items bought counter for new search
    addon:UpdateStatusText("")

    
    if addon.ahResultsPane then
        addon.ahResultsPane.progress:SetText("Starting scan...")
        addon.ahResultsPane.currentPage:SetText("")
    end
    local MAX_SCAN_RETRIES = 3
    
    -- Register for auction update event
    if not addon.ahEventFrame then
        addon.ahEventFrame = CreateFrame("Frame")
    end
    
    addon.ahEventFrame:UnregisterAllEvents()
    addon.ahEventFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    addon.ahEventFrame:SetScript("OnEvent", function(self, event)
        if addon.ahIsBuying or addon.isPostScan or addon.isUndercutScan then 
            -- If we are buying or it's a scan from other panes, we should NOT process this as a Buy scan update.
            return 
        end
        C_Timer.After(0.1, function()
            addon:ProcessAHResults()
        end)
    end)

    -- Timeout protection: If no event for 5 seconds, try to re-query
    if addon.ahScanTimeoutTimer then
        addon.ahScanTimeoutTimer:Cancel()
    end
    addon.ahScanTimeoutTimer = C_Timer.NewTicker(5, function()
        if addon.ahCurrentSearchName and addon.ahEventFrame:IsEventRegistered("AUCTION_ITEM_LIST_UPDATE") then
            if addon.isPostScan or addon.isUndercutScan then return end
            -- Only retry if we haven't finished yet
            if addon.ahCurrentPage < addon.ahTotalPages or addon.ahTotalPages == 0 then
                addon:ProcessAHResults()
            end
        end
    end)
    
    -- Query the auction house
    -- Classic API: QueryAuctionItems(name, minLevel, maxLevel, page, usable, qualityIndex, getAll, exactMatch)
    addon.ahWaitingForPageUpdate = true
    addon.ahLastQueryTime = GetTime()
    addon.ahQueryCountForPage = 1
    
    -- Ensure sorting is correct before querying
    addon:SetAHBuyoutSort()
    
    QueryAuctionItems(name, nil, nil, 0, nil, nil, false, isExact)
    
    -- Collapse AH
    addon:CollapseAH()
    
    if addon.ahResultsPane then
        addon.ahResultsPane.progress:SetText("Starting scan...")
    end
    
    addon.print("Searching AH for: " .. name)
end

-- Helper: Generate a hash of the current page results to detect redundant updates
function addon:GeneratePageHash()
    local batchCount = GetNumAuctionItems("list")
    local hash = ""
    for i = 1, batchCount do
        local name, _, count, _, _, _, _, _, _, buyout, _, _, _, owner = GetAuctionItemInfo("list", i)
        if name then
            hash = hash .. string.format("%s_%d_%d_%s|", name, count or 1, buyout or 0, owner or "?")
        end
    end
    return hash
end

-- Process AH results after query completes
function addon:ProcessAHResults()
    if not addon.ahIsScanning or addon.ahIsBuying then return end

    local batchCount, totalCount = GetNumAuctionItems("list")
    
    -- If we get 0/0, it might be that the page is still loading or it's actually empty.
    -- We'll use a retry mechanism if we expect results.
    if totalCount == 0 and batchCount == 0 then
        if addon.ahScanRetryCount < 3 then
            addon.ahScanRetryCount = addon.ahScanRetryCount + 1
            if addon.ahResultsPane then
                addon.ahResultsPane.progress:SetText(string.format("Retry %d...", addon.ahScanRetryCount))
            end
            C_Timer.After(1.0, function()
                if addon.ahCurrentSearchName then
                    addon:SetAHBuyoutSort()
                    QueryAuctionItems(addon.ahCurrentSearchName, nil, nil, addon.ahCurrentPage, nil, nil, false, addon.ahCurrentSearchIsExact)
                end
            end)
        else
            if addon.ahResultsPane then
                addon.ahResultsPane.progress:SetText("No items found.")
            end
            if addon.ahEventFrame then
                addon.ahEventFrame:UnregisterAllEvents()
            end
            if addon.ahScanTimeoutTimer then
                addon.ahScanTimeoutTimer:Cancel()
                addon.ahScanTimeoutTimer = nil
            end
        end
        return
    end

    -- Reset retries on success
    addon.ahScanRetryCount = 0
    
    addon.ahTotalPages = math.ceil(totalCount / 50)
    
    -- Validation: Wait for all data on the current page to be ready
    local unknownCount = 0
    for i = 1, batchCount do
        local name, _, _, _, _, _, _, _, _, _, _, _, _, owner, _, _, _, hasAllInfo = GetAuctionItemInfo("list", i)
        if not hasAllInfo or not name or name == "" or not owner or owner == "" then
            unknownCount = unknownCount + 1
        end
    end

    -- If there are unknowns, we MUST wait (up to 2s total for data to arrive)
    local now = GetTime()
    local pageLoadStart = addon.ahPageLoadStartTime or now
    if unknownCount > 0 then
        if now - pageLoadStart < 2.0 then
            addon.ahPageLoadStartTime = pageLoadStart
            if addon.ahResultsPane then
                addon.ahResultsPane.progress:SetText(string.format("Page %d Loading... (%d unknowns)", addon.ahCurrentPage + 1, unknownCount))
            end
            return
        end
        -- Timeout: process anyway but log it
        addon.print("Warning: Page " .. addon.ahCurrentPage + 1 .. " data incomplete (unknowns) after timeout.")
    end
    addon.ahPageLoadStartTime = nil -- Reset for next page

    -- Deduplication & Buffer Freshness Check
    local pageHash = addon:GeneratePageHash()
    
    if not addon.ahIsBuying then
        local isLastPage = (addon.ahCurrentPage == addon.ahTotalPages - 1)
        local expectedCount = totalCount % 50
        if expectedCount == 0 and totalCount > 0 then expectedCount = 50 end
        
        -- Detect STALE buffer:
        -- A: Content hash matches the previous page (moved to new page but buffer hasn't updated)
        -- B: We are on the last page but still see 50 items when we expect fewer (totalCount % 50)
        local isStaleContent = (addon.ahCurrentPage ~= addon.ahLastProcessedPage and pageHash == addon.ahLastPageHash)
        local isStaleCount = (isLastPage and batchCount ~= expectedCount and batchCount == 50)

        if isStaleContent or isStaleCount then
            addon.ahPageBufferWaitCount = (addon.ahPageBufferWaitCount or 0) + 1
            
            -- UI Feedback: Show how long we've been waiting and when we will retry
            local queryAge = now - (addon.ahLastQueryTime or 0)
            local nextRetry = math.max(0, 5.5 - queryAge)
            
            if addon.ahResultsPane then
                local totalPagesDisp = addon.ahTotalPages > 0 and addon.ahTotalPages or "?"
                addon.ahResultsPane.progress:SetText(string.format("Waiting for Page %d / %s...", 
                    addon.ahCurrentPage + 1, totalPagesDisp))
            end
            
            -- Schedule a poll
            C_Timer.After(0.2, function()
                if addon.ahWaitingForPageUpdate then
                    addon:ProcessAHResults()
                end
            end)
            
            -- Re-query ONLY after the internal CD has passed + a small buffer
            -- Reduced from 5.5 to 2.5 for more frequent retries as per user request
            if queryAge > 2.5 and CanSendAuctionQuery() then
                addon.ahLastQueryTime = GetTime()
                addon.ahQueryCountForPage = (addon.ahQueryCountForPage or 1) + 1
                local retryName = addon.ahCurrentSearchName or (addon.ahSelectedResult and addon.ahSelectedResult.name)
                if retryName then
                    addon:SetAHBuyoutSort()
                    QueryAuctionItems(retryName, nil, nil, addon.ahCurrentPage, nil, nil, false, addon.ahCurrentSearchIsExact)
                end
            end
            
            -- If we have re-queried enough times and the content is still identical,
            -- assume the pages are legitimately twins and process anyway.
            if (addon.ahQueryCountForPage or 1) >= 3 then
                addon.print("Warning: Forced processing of Page " .. addon.ahCurrentPage + 1 .. " after " .. addon.ahQueryCountForPage .. " queries with identical content.")
            else
                -- Otherwise, stay here and wait for data refresh
                return
            end
        end

        -- 3. If we've already processed this EXACT page number and content, skip redundant event
        if addon.ahCurrentPage == addon.ahLastProcessedPage and pageHash == addon.ahLastPageHash then
            return
        end
    end

    -- Update state
    addon.ahWaitingForPageUpdate = false
    addon.ahPageBufferWaitCount = 0
    addon.ahQueryCountForPage = 1
    addon.ahLastProcessedPage = addon.ahCurrentPage
    addon.ahLastPageHash = pageHash
    
    -- Store results for this specific page 
    addon.pageResults = addon.pageResults or {}
    addon.pageResults[addon.ahCurrentPage] = {}
    local currentPageResults = addon.pageResults[addon.ahCurrentPage]
    
    local minUnitPrice = nil
    addon.priceUpdatedThisPage = false
    for i = 1, batchCount do
        local name, texture, count, quality, canUse, level, levelColHeader, 
              minBid, minIncrement, buyoutPrice, bidAmount, highBidder, bidderFullName,
              owner, ownerFullName, saleStatus, itemId, hasAllInfo = GetAuctionItemInfo("list", i)
        
        if buyoutPrice and buyoutPrice > 0 then
            local unitPrice = math.floor(buyoutPrice / (count or 1))
            local link = GetAuctionItemLink("list", i)
            local realItemId = itemId or (link and tonumber(link:match("item:(%d+)"))) or 0
            
            -- Track lowest unit price for the database
            -- FIX: Only track if the name exactly matches our search query to avoid generic search pollution
            if name == addon.ahCurrentSearchName then
                if not minUnitPrice or unitPrice < minUnitPrice then
                    minUnitPrice = unitPrice
                end
            end

            -- Key: strictly stable key to prevent splits
            local key = string.format("%d_%d_%d", realItemId, count or 1, buyoutPrice)
            
            if currentPageResults[key] then
                currentPageResults[key].quantity = currentPageResults[key].quantity + 1
                -- Prefer real name
                if owner and owner ~= "" then
                    currentPageResults[key].owner = owner
                end
            else
                currentPageResults[key] = {
                    name = name or (realItemId > 0 and GetItemInfo(realItemId)) or "Unknown",
                    texture = texture,
                    count = count or 1,
                    buyout = buyoutPrice,
                    unitPrice = unitPrice,
                    link = link,
                    owner = (owner and owner ~= "") and owner or "Unknown",
                    quantity = 1,
                    key = key,
                    page = addon.ahCurrentPage,
                    itemId = realItemId,
                    quality = quality,
                    minBid = minBid,
                    hasBuyout = true
                }
            end
        else
            -- Bid-only auction
            local link = GetAuctionItemLink("list", i)
            local realItemId = itemId or (link and tonumber(link:match("item:(%d+)"))) or 0
            local key = string.format("bid_%d_%d_%d_%s", realItemId, count or 1, minBid or 0, owner or "unknown")
            
            if currentPageResults[key] then
                currentPageResults[key].quantity = currentPageResults[key].quantity + 1
            else
                currentPageResults[key] = {
                    name = name or "Unknown",
                    quantity = 1,
                    hasBuyout = false
                }
            end
        end
    end
    
    -- Aggregation for Display List (Only Buyouts)
    addon.groupedResultsMap = {}
    local sortedPages = {}
    for pNum in pairs(addon.pageResults) do table.insert(sortedPages, pNum) end
    table.sort(sortedPages)

    local buyoutResults = {}
    local buyoutCount = 0
    local bidOnlyCount = 0

    for _, pageNum in ipairs(sortedPages) do
        local pResults = addon.pageResults[pageNum]
        for key, data in pairs(pResults) do
            if data.hasBuyout then
                buyoutCount = buyoutCount + data.quantity
                if addon.groupedResultsMap[key] then
                    addon.groupedResultsMap[key].quantity = addon.groupedResultsMap[key].quantity + data.quantity
                    if data.owner ~= "Unknown" then
                        addon.groupedResultsMap[key].owner = data.owner
                    end
                else
                    local newData = {}
                    for k, v in pairs(data) do newData[k] = v end
                    addon.groupedResultsMap[key] = newData
                    table.insert(buyoutResults, newData)
                end
            else
                bidOnlyCount = bidOnlyCount + data.quantity
            end
        end
    end
    
    -- Sort buyouts by unit price (lowest first)
    table.sort(buyoutResults, function(a, b)
        if a.unitPrice ~= b.unitPrice then
            return a.unitPrice < b.unitPrice
        end
        
        -- Tie-breaker: unit bid price
        local aUnitBid = (a.minBid or a.buyout) / (a.count or 1)
        local bUnitBid = (b.minBid or b.buyout) / (b.count or 1)
        if aUnitBid ~= bUnitBid then
            return aUnitBid < bUnitBid
        end
        
        return a.count > b.count
    end)
    
    addon.ahSearchResults = buyoutResults
    
    addon:RefreshAHResults()
    if addon.ahResultsPane then
        addon.ahResultsPane.progress:SetText(string.format("Scanning %d/%d (Buyouts: %d | Bids: %d)", 
            addon.ahCurrentPage + 1, addon.ahTotalPages, buyoutCount, bidOnlyCount))
        addon.ahResultsPane.currentPage:SetText(string.format("Current Page: %d", addon.ahCurrentPage + 1))
    end

    -- Update database price for the scanned item
    -- We use minUnitPrice which is the absolute minimum found so far on THIS page.
    -- To ensure we always have the market price, we update it if it's different.
    -- FIX: Only update database if we are performing an EXACT search (e.g. from main frame or full scan)
    if minUnitPrice and addon.ahCurrentSearchName and addon.ahCurrentSearchIsExact then
        local oldPrice = addon.db.prices[addon.ahCurrentSearchName]
        -- On page 0, we can safely overwrite because it's the start of a new scan.
        -- On subsequent pages, we only update if the new minUnitPrice is LOWER than what we found on previous pages.
        -- However, we want to allow prices to go UP between scans.
        -- So: if it's page 0, we set it. If it's page > 0, we only set if lower.
        if addon.ahCurrentPage == 0 then
            if oldPrice ~= minUnitPrice then
                addon.db.prices[addon.ahCurrentSearchName] = minUnitPrice
                if addon.mainFrame and addon.mainFrame:IsShown() then
                    addon:RefreshMainFrame()
                end
            end
        else
            if oldPrice and minUnitPrice < oldPrice then
                addon.db.prices[addon.ahCurrentSearchName] = minUnitPrice
                if addon.mainFrame and addon.mainFrame:IsShown() then
                    addon:RefreshMainFrame()
                end
            end
        end
    end

    -- TRIGGERING PURCHASE CHECK IS NOW REMOVED FROM HERE
    -- (It is handled by the main auctionEventFrame script via AUCTION_ITEM_LIST_UPDATE)

    -- Auto-request next page if we haven't reached the end AND we are in scan mode
    local isFastScan = addon.db.fastScan
    if addon.ahIsScanning and addon.ahCurrentPage < addon.ahTotalPages - 1 and not isFastScan then
        addon.ahCurrentPage = addon.ahCurrentPage + 1
        addon.ahWaitingForPageUpdate = true
        addon.ahLastQueryTime = GetTime()
        addon.ahQueryCountForPage = 1
        -- Add a small delay to avoid overwhelming the server
        C_Timer.After(0.1, function()
            if addon.ahCurrentSearchName and not addon.ahIsBuying then
                addon:SetAHBuyoutSort()
                QueryAuctionItems(addon.ahCurrentSearchName, nil, nil, addon.ahCurrentPage, nil, nil, false, addon.ahCurrentSearchIsExact)
            end
        end)
    elseif addon.ahIsScanning then
        -- Finished scanning all pages
        addon.ahIsScanning = false
        if addon.ahResultsPane then
            local buyoutCount = 0
            local bidOnlyCount = 0
            for _, res in ipairs(addon.ahSearchResults or {}) do
                buyoutCount = buyoutCount + (res.quantity or 1)
            end
            -- Calculate bidOnlyCount by summing non-buyout entries from all pages
            for _, pRes in pairs(addon.pageResults or {}) do
                for _, data in pairs(pRes) do
                    if not data.hasBuyout then
                        bidOnlyCount = bidOnlyCount + (data.quantity or 1)
                    end
                end
            end

            local finishMsg = string.format("Scan complete (Buyouts: %d | Bids: %d / Total: %d)", buyoutCount, bidOnlyCount, totalCount)
            addon.ahResultsPane.progress:SetText(finishMsg)
        end
        -- Keep events registered so purchase navigation works! 
        -- Unregistration now happens ONLY in HideAHResults.
        if addon.ahScanTimeoutTimer then
            addon.ahScanTimeoutTimer:Cancel()
            addon.ahScanTimeoutTimer = nil
        end
    end
end

function addon:ShowAHResults()
    if not addon.ahResultsPane then return end
    
    addon:SelectAHPanelTab(1)
    addon.ahResultsVisible = true
    
    addon:RefreshAHResults()
end

-- Helper: Find the current index of a specific auction result on the current page
-- Returns: index, isPartialMatch (found but info still loading)
function addon:FindAuctionIndex(target)
    if not target then return nil, false, 0 end
    local batchCount = GetNumAuctionItems("list")
    local firstMatchIndex = nil
    local matchCount = 0
    local partialIndex = nil
    local anyLoading = false

    for i = 1, batchCount do
        local name, texture, count, quality, canUse, level, levelColHeader, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemId, hasAllInfo = GetAuctionItemInfo("list", i)
        
        if not hasAllInfo or not name or name == "" then
            anyLoading = true
        end

        -- Match by key criteria (primarily Name, Stack Size, and Buyout)
        local nameMatch = (name == target.name)
        
        -- Secondary check: itemId if name is missing but it's our item
        if not nameMatch and not name and itemId and target.itemId and itemId == target.itemId then
            nameMatch = true
        end

        if nameMatch then
            local countMatch = (count == target.count)
            local buyoutMatch = buyoutPrice and buyoutPrice > 0 and (buyoutPrice == target.buyout)
            local saleMatch = (saleStatus == 0)

            if countMatch and buyoutMatch and saleMatch then
                if hasAllInfo then
                    matchCount = matchCount + 1
                    if not firstMatchIndex then
                        firstMatchIndex = i
                    end
                else
                    -- Found a potential match, but data is still loading
                    partialIndex = i
                end
            end
        end
    end
    -- If we didn't find a match, but items are still loading, return isPartial=true to keep waiting
    return firstMatchIndex, (partialIndex ~= nil or anyLoading), matchCount
end

function addon:CheckForPendingPurchase()
    if not addon.ahIsBuying or not addon.ahPendingItem then return end

    local currentIndex, isPartial, matchingOnPage = addon:FindAuctionIndex(addon.ahPendingItem)
    local batchCount, totalCount = GetNumAuctionItems("list")

    -- Correct the quantity if we found it but the count on this specific page is less than expected
    -- (This happens if our scan data was stale or items were bought/shifted)
    if matchingOnPage > 0 and addon.ahPendingItem.quantity > matchingOnPage then
        -- addon.print(string.format("DEBUG: Correcting quantity for %s: %d -> %d", addon.ahPendingItem.name, addon.ahPendingItem.quantity, matchingOnPage))
        addon.ahPendingItem.quantity = matchingOnPage
        addon:RefreshAHResults()
    end

    if currentIndex then
        -- Stop polling if we found it
        if addon.purchasePollingTicker then
            addon.purchasePollingTicker:Cancel()
            addon.purchasePollingTicker = nil
        end
        if addon.purchaseTimeoutTimer then
            addon.purchaseTimeoutTimer:Cancel()
            addon.purchaseTimeoutTimer = nil
        end
        
        -- Record purchase time for NOT_FOUND suppression
        addon.ahPendingItem.purchaseTime = GetTime()
        
        -- Record purchase time for NOT_FOUND suppression
        addon.ahPendingItem.purchaseTime = GetTime()
        
        -- Set ready state so the user can click to confirm (Hardware Event requirement)
        if not addon.ahReadyToBuy then
            addon.ahReadyToBuy = true
            addon:UpdateStatusText("|cff00ff00Item found! CLICK BUY|r")
            addon:RefreshAHResults()
        end
    else
        -- ITEM NOT FOUND ON THIS PAGE
        -- Check if we are in the middle of a page transition
        local now = GetTime()
        local transitioning = (addon.ahLastPageChangeTime and (now - addon.ahLastPageChangeTime < 3.0))
        
        if isPartial then
            addon:UpdateStatusText("Loading items...")
        elseif transitioning or totalCount == 0 or batchCount == 0 then
            addon:UpdateStatusText("Waiting for AH...")
        else
            -- If not found on the expected page, and we haven't tried Page 0 yet, try Page 0.
            -- Often items shift to the first page when others are bought.
            if addon.ahCurrentPage ~= 0 and not addon.ahTriedPageZeroFallback then
                addon.ahTriedPageZeroFallback = true
                addon.ahCurrentPage = 0
                addon:UpdateStatusText("Redirection to page 1...")
                addon.ahLastPageChangeTime = GetTime()
                local isExact = (addon.ahCurrentSearchIsExact ~= nil) and addon.ahCurrentSearchIsExact or true
                
                -- Ensure sorting is correct before querying page 0 fallback
                addon:SetAHBuyoutSort()
                
                QueryAuctionItems(addon.ahCurrentSearchName or addon.ahPendingItem.name, nil, nil, 0, nil, nil, false, isExact)
            else
                -- Not found and we've already checked Page 1 or it moved beyond our fallback
                addon:UpdateStatusText(string.format("Not found on P%d (Items: %d)", (addon.ahCurrentPage or 0) + 1, batchCount))
                
                -- It's gone or moved significantly. Reset state and remove from results list.
                addon.print("Item no longer found: " .. (addon.ahPendingItem.name or "Unknown"))
                
                local goneItem = addon.ahPendingItem
                addon:ResetPurchaseState()
                
                -- Force remove from search results
                for i, res in ipairs(addon.ahSearchResults or {}) do
                    if res == goneItem then
                        table.remove(addon.ahSearchResults, i)
                        break
                    end
                end
                addon:RefreshAHResults()
            end
        end
    end
end

-- Refresh the AH results display
function addon:RefreshAHResults()
    if not addon.ahResultsPane then return end
    
    local results = addon.ahSearchResults or {}
    local pane = addon.ahResultsPane
    
    -- Update items bought counter UI
    if pane.itemsBought then
        if (addon.itemsBought or 0) > 0 then
            pane.itemsBought:SetText(string.format("Total Bought: %d", addon.itemsBought))
        else
            pane.itemsBought:SetText("")
        end
    end
    
    FauxScrollFrame_Update(pane.scroll, #results, MAX_AH_ROWS, AH_ROW_HEIGHT)
    
    if #results == 0 and (addon.ahCurrentSearchName or addon.ahIsScanning) then
        pane.noResults:Show()
    else
        pane.noResults:Hide()
    end
    
    local offset = FauxScrollFrame_GetOffset(pane.scroll)
    for i = 1, MAX_AH_ROWS do
        local row = pane.rows[i]
        local index = offset + i
        if index <= #results then
            local result = results[index]
            row.data = result -- Store for OnClick
            
            row.icon:SetTexture(result.texture or "Interface\\Icons\\Inv_Misc_QuestionMark")
            
            -- Handle Selection Visual (Match by key for persistence across refreshes)
            if addon.ahSelectedResult and (addon.ahSelectedResult == result or addon.ahSelectedResult.key == result.key) then
                row.selection:Show()
                -- If the objects are different but keys match, sync the reference
                addon.ahSelectedResult = result
            else
                row.selection:Hide()
            end
            
            row.stackSize:SetText(result.count .. "x")
            row.stackCount:SetText("x" .. result.quantity)
            
            row.name:SetText(result.link or result.name or "Unknown")

            local sellerText = result.owner or "Unknown"
            if result.owner == UnitName("player") then
                sellerText = "|cff00ff00" .. sellerText .. "|r"
            end
            row.seller:SetText(sellerText)
            
            row.unitPrice:SetText(addon:FormatMoney(result.unitPrice, true))
            
            -- Tooltip for total cost
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                if result.link then
                    GameTooltip:SetHyperlink(result.link)
                else
                    GameTooltip:AddLine(result.name)
                end
                GameTooltip:AddLine(" ")
                if result.quantity > 1 then
                    GameTooltip:AddLine("Available: " .. result.quantity .. " stacks", 1, 1, 1)
                end
                GameTooltip:AddLine("Total Buyout: " .. addon:FormatMoney(result.buyout))
                if result.itemId then
                    GameTooltip:AddLine("Item ID: " .. result.itemId, 0.5, 0.5, 0.5)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            
            -- Confirm button logic replaced by Global Buy Button logic
            
            row:Show()
        else
            row:Hide()
        end
    end
    
    -- Update Global Buy Button state
    if addon.ahIsBuying then
        pane.globalBuyBtn:Disable()
        pane.globalBuyBtn:SetText("Buying...")
    elseif addon.ahSelectedResult and addon.ahReadyToBuy then
        pane.globalBuyBtn:Enable()
        pane.globalBuyBtn:SetText("Buy Selected")
    elseif addon.ahSelectedResult then
        if addon.ahVerificationFailed then
            pane.globalBuyBtn:Disable()
            pane.globalBuyBtn:SetText("Item Not Found")
        else
            pane.globalBuyBtn:Disable()
            pane.globalBuyBtn:SetText("Verifying...")
        end
    else
        pane.globalBuyBtn:Disable()
        pane.globalBuyBtn:SetText("Select an Item")
    end
end

-- Select a result and verify it
-- Select a result and verify it
function addon:SelectResult(result)
    if addon.ahIsBuying then return end -- Don't switch while buying
    if not result then return end
    
    -- Sync current page with item before stopping scan
    -- This ensures navigation/verification context is correct
    if result.page then
        addon.ahCurrentPage = result.page
    end

    -- Terminate background scan immediately on selection
    addon:StopNormalScan()

    addon.ahSelectedResult = result
    addon.ahReadyToBuy = false
    addon.ahVerificationFailed = false
    
    -- Update UI to show selection immediately
    addon:RefreshAHResults()
    
    addon:VerifySelectedItem()
end

-- Verify that the selected item is on the current page and available
function addon:VerifySelectedItem()
    local result = addon.ahSelectedResult
    if not result then return end
    
    addon.ahVerificationFailed = false

    -- Ensure event frame is ready and registered
    if not addon.ahEventFrame then
        addon.ahEventFrame = CreateFrame("Frame")
    end
    if not addon.ahEventFrame:IsEventRegistered("AUCTION_ITEM_LIST_UPDATE") then
        addon.ahEventFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
        addon.ahEventFrame:SetScript("OnEvent", function(self, event)
            if addon.ahIsBuying or addon.isPostScan or addon.isUndercutScan then return end
            C_Timer.After(0.1, function()
                addon:ProcessAHResults()
            end)
        end)
    end

    -- Check if we can query (Throttling)
    if not CanSendAuctionQuery() then
        addon:UpdateStatusText("|cffff0000Throttled (Wait)|r - Finding item...")
        if not addon.navigationRetryTimer then
            addon.navigationRetryTimer = C_Timer.NewTicker(1.0, function()
                if addon.ahSelectedResult then
                    addon:VerifySelectedItem()
                end
            end)
        end
        return
    end

    -- Clear retry timer if we can query
    if addon.navigationRetryTimer then
        addon.navigationRetryTimer:Cancel()
        addon.navigationRetryTimer = nil
    end
    
    -- Consolidated state reset for any navigation query
    local function PrepareNavigationQuery()
        addon.ahLastQueryTime = GetTime()
        addon.ahPageBufferWaitCount = 0
        addon.ahLastProcessedPage = -1
        addon.ahLastPageHash = ""
        addon.ahWaitingForPageUpdate = true
    end

    local currentSearchName = addon.ahCurrentSearchName or result.name
    local isExact = (addon.ahCurrentSearchIsExact ~= nil) and addon.ahCurrentSearchIsExact or true
    local targetPage = result.page or 0

    -- Check if we are on the correct page
    if addon.ahCurrentPage ~= targetPage then
        local msg = "Navigating to page " .. (targetPage + 1) .. "..."
        addon:UpdateStatusText(msg)
        if addon.ahResultsPane then
            addon.ahResultsPane.progress:SetText(msg)
            addon.ahResultsPane.currentPage:SetText("")
        end
        
        PrepareNavigationQuery()
        addon.ahCurrentPage = targetPage
        addon.ahLastPageChangeTime = GetTime()
        
        addon:SetAHBuyoutSort()
        QueryAuctionItems(currentSearchName, nil, nil, targetPage, nil, nil, false, isExact)
    else
        -- We are on the correct page.
        local currentIndex = addon:FindAuctionIndex(result)
        
        if currentIndex then
            addon.ahReadyToBuy = true
            addon.ahVerificationFailed = false
            local msg = "Item verified. Ready to buy."
            addon:UpdateStatusText(msg)
            if addon.ahResultsPane then
                addon.ahResultsPane.progress:SetText(msg)
            end
            addon:RefreshAHResults()
        else
             local msg = "Verifying..."
             addon:UpdateStatusText(msg)
             if addon.ahResultsPane then
                 addon.ahResultsPane.progress:SetText(msg)
             end
             PrepareNavigationQuery()
             addon:SetAHBuyoutSort()
             QueryAuctionItems(currentSearchName, nil, nil, targetPage, nil, nil, false, isExact)
        end
    end
end

-- Called when Global Buy Button is clicked
function addon:InitiateBuy(result)
    if not result or not addon.ahReadyToBuy then return end
    
    local currentIndex = addon:FindAuctionIndex(result)
    if not currentIndex then
        addon.print("Error: Item lost during buy attempt.")
        addon:VerifySelectedItem() -- Retry verification
        return
    end
    
    local name, _, count, _, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", currentIndex)
    
    if buyoutPrice and buyoutPrice > 0 then
        addon.ahIsBuying = true
        addon.ahPendingItem = result
        addon.ahIsBidPlaced = true
        
        -- Start safety timeout for purchase
        if addon.purchaseTimeoutTimer then addon.purchaseTimeoutTimer:Cancel() end
        addon.purchaseTimeoutTimer = C_Timer.After(10, function()
            if addon.ahIsBuying then
                addon.print("Purchase timed out after 10 seconds.")
                addon:ResetPurchaseState()
                addon:UpdateStatusText("Purchase Timeout")
            end
        end)

        PlaceAuctionBid("list", currentIndex, buyoutPrice)
        addon:UpdateStatusText("Purchasing...")
        
        -- Disable button immediately
        addon:RefreshAHResults()
    else
        addon.print("Error: No buyout price found.")
    end
end

-- Hook into ProcessAHResults or similar to auto-verify after a scan updates
local original_ProcessAHResults = addon.ProcessAHResults
addon.ProcessAHResults = function(self)
    original_ProcessAHResults(self)
    
    -- After results are processed, if we have a selected item, verify it is present
    if addon.ahSelectedResult and not addon.ahIsBuying then
        -- Skip verification if we are STILL waiting for a fresh page update or if we're in stale check
        if addon.ahWaitingForPageUpdate then return end

        local currentIndex, isPartial = addon:FindAuctionIndex(addon.ahSelectedResult)
        
        if currentIndex then
            if not addon.ahReadyToBuy then
                addon.ahReadyToBuy = true
                addon.ahVerificationFailed = false
                local msg = "Item found. Ready to buy."
                addon:UpdateStatusText(msg)
                if addon.ahResultsPane then
                    addon.ahResultsPane.progress:SetText(msg)
                end
                addon:RefreshAHResults()
            end
        elseif isPartial then
            -- Item data is still loading, stay in "Verifying..." state and wait for next event
            addon.ahReadyToBuy = false
            addon.ahVerificationFailed = false
            local msg = "Verifying... (Loading Data)"
            addon:UpdateStatusText(msg)
            if addon.ahResultsPane then
                addon.ahResultsPane.progress:SetText(msg)
            end
            addon:RefreshAHResults()
        else
            -- Check if we are on the expected page
            if addon.ahCurrentPage == (addon.ahSelectedResult.page or 0) then
                -- We are on the page, and all data loaded, but item NOT found. It might be gone.
                addon.ahReadyToBuy = false
                addon.ahVerificationFailed = true
                local msg = "Item not found on this page."
                addon:UpdateStatusText(msg)
                if addon.ahResultsPane then
                    addon.ahResultsPane.progress:SetText(msg)
                end
                addon:RefreshAHResults()
            end
        end
    end
end


-- Hide the AH results pane
function addon:HideAHResults()
    if addon.ahResultsPane then
        addon.ahResultsPane:Hide()
    end
    addon.ahResultsVisible = false
    addon.ahSearchResults = {}
    addon.pageResults = {}
    addon.groupedResultsMap = {}
    addon.ahCurrentSearchName = nil
    addon.ahIsBuying = false
    addon.ahPendingItem = nil
    addon.itemsBought = 0 -- Reset counter
    
    addon:UpdateStatusText("")
    
    if addon.ahEventFrame then
        addon.ahEventFrame:UnregisterAllEvents()
    end
    if addon.ahScanTimeoutTimer then
        addon.ahScanTimeoutTimer:Cancel()
        addon.ahScanTimeoutTimer = nil
    end
    if addon.purchaseTimeoutTimer then
        addon.purchaseTimeoutTimer:Cancel()
        addon.purchaseTimeoutTimer = nil
    end
    
    -- Restore AH
    addon:RestoreAH()
end
