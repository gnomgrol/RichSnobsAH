local addonName, addon = ...

-- Create the Undercut Checker pane
function addon:CreateUndercutPane(parentFrame)
    local pane = CreateFrame("Frame", "RichSnobsAHUndercutPane", parentFrame, "BackdropTemplate")
    pane:SetAllPoints(parentFrame)
    pane:Hide()
    
    -- Title (handled by main AH panel, but keeping reference)
    local title = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -15)
    title:SetText("Undercut Checker")
    title:Hide()
    pane.title = title
    

    -- Status text
    local status = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("TOPLEFT", 15, -15)
    status:SetText("Idle")
    pane.status = status

    -- Results container
    local resultsFrame = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    resultsFrame:SetPoint("TOPLEFT", 15, -30)
    resultsFrame:SetPoint("BOTTOMRIGHT", -15, 35)
    resultsFrame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    resultsFrame:SetBackdropColor(0, 0, 0, 1.0)
    resultsFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- Scroll frame
    local scroll = CreateFrame("ScrollFrame", "RichSnobsAHUndercutScroll", resultsFrame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 5, -5)
    scroll:SetPoint("BOTTOMRIGHT", -25, 5)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 30, function() addon:RefreshUndercutPane() end)
    end)
    pane.scroll = scroll

    -- Rows
    pane.rows = {}
    for i = 1, 10 do
        local row = CreateFrame("Button", nil, resultsFrame)
        row:SetHeight(30)
        row:SetPoint("LEFT", 5, 0)
        row:SetPoint("RIGHT", -25, 0)
        if i == 1 then
            row:SetPoint("TOP", 0, -5)
        else
            row:SetPoint("TOP", pane.rows[i-1], "BOTTOM", 0, 0)
        end

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(20); icon:SetHeight(20)
        icon:SetPoint("LEFT", 2, 0)
        row.icon = icon

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        name:SetWidth(150); name:SetJustifyH("LEFT")
        row.name = name

        local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        statusText:SetPoint("LEFT", name, "RIGHT", 5, 0)
        statusText:SetWidth(100); statusText:SetJustifyH("LEFT")
        row.statusText = statusText

        local cancelBtn = CreateFrame("Button", nil, row, "GameMenuButtonTemplate")
        cancelBtn:SetWidth(60); cancelBtn:SetHeight(20)
        cancelBtn:SetPoint("RIGHT", -2, 0)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetNormalFontObject("GameFontNormalSmall")
        cancelBtn:SetHighlightFontObject("GameFontHighlightSmall")
        row.cancelBtn = cancelBtn

        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        
        row:SetScript("OnEnter", function(self)
            if self.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.link)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row:Hide()
        pane.rows[i] = row
    end

    -- Scan Button at the bottom
    local scanBtn = CreateFrame("Button", nil, pane, "GameMenuButtonTemplate")
    scanBtn:SetSize(160, 25)
    scanBtn:SetPoint("BOTTOM", 0, 10)
    scanBtn:SetText("Scan Undercuts")
    scanBtn:SetScript("OnClick", function()
        addon:StartUndercutScan()
    end)
    pane.scanBtn = scanBtn

    addon.undercutPane = pane
end

-- Helper: Format seconds into MM:SS
function addon:FormatTime(seconds)
    if not seconds or seconds <= 0 then return "00:00" end
    local minutes = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%02d:%02d", minutes, secs)
end

-- Refresh Undercut Pane
function addon:RefreshUndercutPane()
    if not self.undercutPane or not self.undercutPane:IsShown() then return end
    local results = self.undercutResults or {}
    local pane = self.undercutPane
    
    -- Update timeLeft for sold auctions before sorting to ensure stable sort results
    for _, res in ipairs(results) do
        if res.isSold then
            res.timeLeft = GetAuctionItemTimeLeft("owner", res.ownerIndex)
        end
    end

    -- Sort results: Active (with undercut status) first, then sold auctions at the bottom
    -- Sold auctions are sorted by timeLeft (soonest arriving first)
    table.sort(results, function(a, b)
        if a.isSold ~= b.isSold then
            return not a.isSold
        end
        if a.isSold then
            return (a.timeLeft or 0) < (b.timeLeft or 0)
        end
        -- Secondary sort within groups: by name
        return a.name < b.name
    end)

    FauxScrollFrame_Update(pane.scroll, #results, 10, 30)
    local offset = FauxScrollFrame_GetOffset(pane.scroll)
    
    for i = 1, 10 do
        local row = pane.rows[i]
        local index = offset + i
        if index <= #results then
            local auction = results[index]
            row.icon:SetTexture(auction.texture or "Interface\\Icons\\Inv_Misc_QuestionMark")
            local nameText = (auction.link or auction.name) .. (auction.count > 1 and (" x" .. auction.count) or "")
            if auction.numStacked and auction.numStacked > 1 then
                nameText = nameText .. " |cffaaaaaa(" .. auction.numStacked .. ")|r"
            end
            row.name:SetText(nameText)
            
            if auction.isSold then
                row.statusText:SetText("|cff00ff00Sold!|r " .. self:FormatMoney(auction.payoff) .. "\n|cffaaaaaa" .. self:FormatTime(auction.timeLeft) .. "|r")
                row.cancelBtn:Disable()
            elseif auction.cancellingThis then
                row.statusText:SetText("|cffffff00Cancelling...|r")
                row.cancelBtn:Disable()
            elseif auction.error then
                row.statusText:SetText("|cffff0000Error: " .. auction.error .. "|r")
                row.cancelBtn:Enable()
            elseif auction.scanning then
                row.statusText:SetText("|cffffff00Scanning...|r")
                row.cancelBtn:Disable()
            elseif addon.isCancelling then
                row.statusText:SetText("|cffaaaaaaQueued...|r")
                row.cancelBtn:Disable()
            elseif auction.scanned then
                if auction.undercut then
                    row.statusText:SetText("|cffff0000" .. (auction.undercutCount or 1) .. " undercuts\n" .. self:FormatMoney(auction.delta) .. "|r")
                else
                    row.statusText:SetText("|cff00ff00Cheapest!|r")
                end
                row.cancelBtn:Enable()
            else
                -- Not scanned yet
                if addon.isUndercutScan then
                    row.statusText:SetText("|cffaaaaaaQueued...|r")
                else
                    row.statusText:SetText("|cffaaaaaa" .. self:FormatMoney(auction.buyout) .. "|r")
                end
                row.cancelBtn:Enable()
            end
            
            row.cancelBtn:SetScript("OnClick", function()
                addon:CancelUndercutAuction(auction)
            end)
            
            row.link = auction.link
            row:Show()
        else
            row:Hide()
        end
    end
end


-- Start Undercut Scan
function addon:StartUndercutScan()
    if not addon:IsAHOpen() then
        addon.print("Auction House is not open.")
        return
    end

    if self.isUndercutScan then return end

    -- Fetch latest first to ensure we have a fresh list of active auctions
    self:FetchPlayerAuctions()

    if not self.undercutResults or #self.undercutResults == 0 then
         -- FetchPlayerAuctions already updates status
         return
    end

    -- Disable UI to prevent concurrent scans
    if self.undercutPane and self.undercutPane.scanBtn then
        self.undercutPane.scanBtn:Disable()
    end
    if addon.fullScanBtn then addon.fullScanBtn:Disable() end
    if addon.importBtn then addon.importBtn:Disable() end

    self.isUndercutScan = true
    self.undercutPane.status:SetText("Scanning undercuts...")
    
    local itemsToScanMap = {}
    for _, res in ipairs(self.undercutResults) do
        if not res.isSold and res.buyout > 0 then
            itemsToScanMap[res.name] = true
            res.scanning = false
            res.scanned = false
        end
    end

    self.itemsToScan = {}
    for name, _ in pairs(itemsToScanMap) do
        table.insert(self.itemsToScan, name)
    end

    if #self.itemsToScan == 0 then
        self.undercutPane.status:SetText("No active auctions to scan.")
        addon:EndUndercutScan()
        return
    end

    self.undercutScanIndex = 1
    self:ScanNextUndercut()
end

-- Fetch player's auctions (Active & Sold)
function addon:FetchPlayerAuctions(preserveScanResults)
    if not addon:IsAHOpen() then return end

    local scanStateMap = {}
    if preserveScanResults and self.undercutResults then
        for _, res in ipairs(self.undercutResults) do
            local key = string.format("%s_%d_%d_%d", res.name, res.count, res.buyout, res.isSold and 1 or 0)
            scanStateMap[key] = {
                scanned = res.scanned,
                undercut = res.undercut,
                undercutCount = res.undercutCount,
                delta = res.delta,
                error = res.error
            }
        end
    end

    local groupedResults = {}
    local resultsMap = {}
    local numOwnerAuctions = GetNumAuctionItems("owner")
    
    if numOwnerAuctions == 0 then
        self.undercutResults = {}
        if self.undercutPane then
            self.undercutPane.status:SetText("No auctions found.")
        end
        self:RefreshUndercutPane()
        return
    end

    for i = 1, numOwnerAuctions do
        local name, texture, count, quality, canUse, level, levelColHeader, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemId = GetAuctionItemInfo("owner", i)
        
        -- saleStatus: 0 = active, 1 = sold
        if (saleStatus == 0 and buyoutPrice > 0) or saleStatus == 1 then
            local itemLink = GetAuctionItemLink("owner", i)
            local timeLeft = GetAuctionItemTimeLeft("owner", i)
            
            -- Key for grouping: name, stack size, buyout price, sale status
            local key = string.format("%s_%d_%d_%d", name, count, buyoutPrice, saleStatus)
            
            if resultsMap[key] then
                local res = resultsMap[key]
                res.numStacked = res.numStacked + 1
                -- Keep the lowest time left for the group
                if timeLeft < res.timeLeft then
                    res.timeLeft = timeLeft
                    res.ownerIndex = i
                end
            else
                local res = {
                    name = name,
                    texture = texture,
                    count = count,
                    buyout = buyoutPrice,
                    payoff = bidAmount,
                    undercut = false,
                    scanning = false,
                    scanned = false,
                    link = itemLink,
                    isSold = (saleStatus == 1),
                    timeLeft = timeLeft,
                    ownerIndex = i,
                    numStacked = 1
                }

                -- Restore scan state if requested
                if scanStateMap[key] then
                    local s = scanStateMap[key]
                    res.scanned = s.scanned
                    res.undercut = s.undercut
                    res.undercutCount = s.undercutCount
                    res.delta = s.delta
                    res.error = s.error
                end

                resultsMap[key] = res
                table.insert(groupedResults, res)
            end
        end
    end

    self.undercutResults = groupedResults
    if self.undercutPane then
        if preserveScanResults then
             -- Don't overwrite the status if we are just updating counts during cancellation
        else
             self.undercutPane.status:SetText(string.format("Loaded %d items (%d auctions).", #groupedResults, numOwnerAuctions))
        end
    end
    self:RefreshUndercutPane()
end

function addon:ScanNextUndercut()
    if not self.undercutPane or not self.undercutPane:IsShown() then 
        self.isUndercutScan = false
        addon:EndUndercutScan()
        return 
    end

    -- Guard: Prevent starting a new search if one is already active or throttled
    if self.isSearchingForUndercut then return end

    if self.undercutScanIndex > #self.itemsToScan then
        self.undercutPane.status:SetText("Undercut scan finished.")
        self.isUndercutScan = false
        addon:EndUndercutScan()
        return
    end

    local itemName = self.itemsToScan[self.undercutScanIndex]
    
    -- Mark all auctions for this item as scanning
    for _, auction in ipairs(self.undercutResults) do
        if auction.name == itemName then
            auction.scanning = true
        end
    end

    if self.undercutPane then
        self.undercutPane.status:SetText(string.format("Scanning (%d/%d): %s", self.undercutScanIndex, #self.itemsToScan, itemName))
        self:RefreshUndercutPane()
    end
    
    -- Reset retry count for new item
    self.undercutRetryCount = 0
    -- Perform AH search for this item
    self:SearchForUndercut(itemName)
    self.undercutScanIndex = self.undercutScanIndex + 1
end

function addon:SearchForUndercut(itemName)
    -- Lock search
    self.isSearchingForUndercut = true

    local canQuery = CanSendAuctionQuery()
    if not canQuery then
        if self.undercutPane then
            self.undercutPane.status:SetText(string.format("|cffff0000Throttled (Wait)|r - Scanning %s", itemName))
            -- Ensure rows also show Scanning... state even while waiting for AH
            addon:RefreshUndercutPane()
        end
        C_Timer.After(1.0, function() 
            if self.isUndercutScan then
                -- Reset lock briefly to allow re-entry
                self.isSearchingForUndercut = false
                addon:SearchForUndercut(itemName) 
            end
        end)
        return
    end

    if not self.undercutScanFrame then
        self.undercutScanFrame = CreateFrame("Frame")
    end
    
    local scanFrame = self.undercutScanFrame
    scanFrame:UnregisterAllEvents()
    scanFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    
    if self.undercutTimeout then
        self.undercutTimeout:Cancel()
    end

    self.undercutTimeout = C_Timer.After(5, function()
        scanFrame:UnregisterAllEvents()
        
        -- Update all auctions for this item
        for _, auction in ipairs(self.undercutResults) do
            if auction.name == itemName and auction.scanning then
                auction.scanning = false
                auction.error = "Timeout"
            end
        end
        
        self.isSearchingForUndercut = false
        addon:ScanNextUndercut()
    end)

    scanFrame:SetScript("OnEvent", function(frame, event)
        local batchCount, totalCount = GetNumAuctionItems("list")
        
        if totalCount == 0 and batchCount == 0 then
            -- In Classic, 0/0 can mean loading or actually empty.
            -- We retry a few times before giving up.
            self.undercutRetryCount = (self.undercutRetryCount or 0) + 1
            if self.undercutRetryCount < 3 then
                return -- Wait for next event or timeout
            end
            -- If we retried enough and still 0/0, assume it's actually empty
        end
        
        if self.undercutTimeout then
            self.undercutTimeout:Cancel()
            self.undercutTimeout = nil
        end

        local expectedBatch = math.min(50, totalCount)
        if batchCount < expectedBatch then
            return -- Still loading this page
        end

        -- Validation: Wait for all data on the current page to be ready (owner names, etc)
        local unknownCount = 0
        for i = 1, batchCount do
            local name, _, _, _, _, _, _, _, _, _, _, _, _, owner, _, _, _, hasAllInfo = GetAuctionItemInfo("list", i)
            if not hasAllInfo or not name or name == "" or not owner or owner == "" then
                unknownCount = unknownCount + 1
            end
        end

        local now = GetTime()
        local pageLoadStart = self.undercutPageLoadStartTime or now
        if unknownCount > 0 then
            if now - pageLoadStart < 2.0 then
                self.undercutPageLoadStartTime = pageLoadStart
                if self.undercutPane then
                    self.undercutPane.status:SetText(string.format("Loading %s... (%d unknowns)", itemName, unknownCount))
                end
                -- We don't unregister yet, just return and wait for next event/timer
                return
            end
            -- Timeout: process anyway but maybe it's partially logged
        end
        self.undercutPageLoadStartTime = nil -- Reset

        scanFrame:UnregisterAllEvents()
        
        C_Timer.After(0.1, function()
            -- We process results even if isUndercutScan was just cleared by a finish event
            -- to ensure the last item's data is recorded.

            -- Analyze results
            local minBuyoutUnit = nil
            local ahAuctions = {}
            for i = 1, batchCount do
                local name, texture, count, q, cu, l, lch, mb, mi, buyout, ba, hb, hbf, owner = GetAuctionItemInfo("list", i)
                if name == itemName and buyout and buyout > 0 then
                    local unitPrice = buyout / count
                    local isMine = (owner == UnitName("player")) or (owner == "Unknown") -- In classic, if owner is nil it MIGHT be ours or just loading
                    
                    if not isMine then
                        if not minBuyoutUnit or unitPrice < minBuyoutUnit then
                            minBuyoutUnit = unitPrice
                        end
                        table.insert(ahAuctions, { unitPrice = unitPrice })
                    end
                end
            end
            
            -- Apply results
            for _, auction in ipairs(self.undercutResults) do
                if auction.name == itemName then
                    auction.scanning = false
                    auction.scanned = true
                    auction.minBuyout = minBuyoutUnit and (minBuyoutUnit * auction.count)
                    
                    local playerUnitPrice = auction.buyout / auction.count
                    local undercutCount = 0
                    for _, ahAuction in ipairs(ahAuctions) do
                        if ahAuction.unitPrice < playerUnitPrice - 0.0001 then
                            undercutCount = undercutCount + 1
                        end
                    end

                    if minBuyoutUnit and (minBuyoutUnit < playerUnitPrice - 0.0001) then
                        auction.undercut = true
                        auction.undercutCount = undercutCount
                        auction.delta = (playerUnitPrice - minBuyoutUnit) * auction.count
                    else
                        auction.undercut = false
                        auction.delta = 0
                    end
                end
            end
            
            addon:RefreshUndercutPane()
            C_Timer.After(0.2, function() 
                self.isSearchingForUndercut = false
                addon:ScanNextUndercut() 
            end)
        end)
    end)

    QueryAuctionItems(itemName, nil, nil, 0, nil, nil, false, true)
end

function addon:CancelUndercutAuction(auction)
    if addon.isCancelling then return end

    local function FindTargetIndex()
        local numOwnerAuctions = GetNumAuctionItems("owner")
        for i = 1, numOwnerAuctions do
            local name, texture, count, q, cu, l, lch, mb, mi, buyout, ba, hb, hbf, owner, ownerFull, saleStatus = GetAuctionItemInfo("owner", i)
            if name == auction.name and count == auction.count and buyout == auction.buyout and saleStatus == 0 then
                return i
            end
        end
        return nil
    end

    local targetIndex = FindTargetIndex()
    
    if targetIndex then
        -- CRITICAL: Call CancelAuction BEFORE updating any UI to avoid execution path taint
        CancelAuction(targetIndex)

        -- Now safe to update UI state
        addon.isCancelling = true
        auction.cancellingThis = true
        addon:RefreshUndercutPane()
        
        if not self.cancellationListener then
            self.cancellationListener = CreateFrame("Frame")
        end
        local listener = self.cancellationListener
        listener:UnregisterAllEvents()
        listener:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
        
        if self.cancelTimeout then self.cancelTimeout:Cancel() end
        self.cancelTimeout = C_Timer.After(4.0, function()
             listener:UnregisterAllEvents()
             addon.isCancelling = false
             auction.cancellingThis = false
             addon:RefreshUndercutPane()
        end)
        
        listener:SetScript("OnEvent", function(frame, event)
            frame:UnregisterAllEvents()
            if self.cancelTimeout then self.cancelTimeout:Cancel() self.cancelTimeout = nil end
            
            addon.isCancelling = false
            auction.cancellingThis = false
            
            -- Re-fetch auctions from the server to get precise updated counts and indices
            -- Preserve current scan results so the user doesn't lose the "Undercut" status info
            addon:FetchPlayerAuctions(true)
        end)
    else
        self.print("Could not find auction to cancel for " .. auction.name)
        for i, res in ipairs(self.undercutResults) do
            if res == auction then
                table.remove(self.undercutResults, i)
                break
            end
        end
        addon:RefreshUndercutPane()
    end
end
function addon:EndUndercutScan()
    self.isUndercutScan = false
    self.isSearchingForUndercut = false
    
    -- Cleanup search logic
    if self.undercutScanFrame then
        self.undercutScanFrame:UnregisterAllEvents()
    end
    if self.undercutTimeout then
        self.undercutTimeout:Cancel()
        self.undercutTimeout = nil
    end
    self.undercutPageLoadStartTime = nil

    if self.undercutResults then
        for _, auction in ipairs(self.undercutResults) do
            -- If we were just scanning this, it's now done (but no results applied)
            if auction.scanning then
                auction.scanned = false -- Reset if unfinished
            end
            auction.scanning = false
        end
    end
    if self.undercutPane then
        if self.undercutPane.scanBtn then
            self.undercutPane.scanBtn:Enable()
        end
        -- If AH is closed, update status
        if not addon:IsAHOpen() then
            self.undercutPane.status:SetText("Scan stopped (AH Closed)")
        end
    end
    if addon.fullScanBtn then addon.fullScanBtn:Enable() end
    if addon.importBtn then addon.importBtn:Enable() end
    addon:RefreshUndercutPane()
end
