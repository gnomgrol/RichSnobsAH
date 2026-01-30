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
    resultsFrame:SetPoint("BOTTOMRIGHT", -15, 45)
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

    addon.undercutPane = pane
end

-- Refresh Undercut Pane
function addon:RefreshUndercutPane()
    if not self.undercutPane or not self.undercutPane:IsShown() then return end
    local results = self.undercutResults or {}
    local pane = self.undercutPane
    
    FauxScrollFrame_Update(pane.scroll, #results, 10, 30)
    local offset = FauxScrollFrame_GetOffset(pane.scroll)
    
    for i = 1, 10 do
        local row = pane.rows[i]
        local index = offset + i
        if index <= #results then
            local auction = results[index]
            row.icon:SetTexture(auction.texture or "Interface\\Icons\\Inv_Misc_QuestionMark")
            row.name:SetText(auction.name .. " x" .. auction.count)
            
            if auction.scanning or addon.isCancelling then
                row.statusText:SetText(auction.scanning and "|cffffff00Scanning...|r" or "|cffffff00Cancelling...|r")
                row.cancelBtn:Disable()
            elseif not auction.scanned then
                -- Only show "Queued" if we are actually in a scan session
                if addon.isUndercutScan then
                    row.statusText:SetText("|cffaaaaaaQueued...|r")
                else
                    row.statusText:SetText("|cffaaaaaaSkipped|r")
                end
                row.cancelBtn:Enable()
            elseif auction.error then
                row.statusText:SetText("|cffff0000Error: " .. auction.error .. "|r")
                row.cancelBtn:Enable()
            elseif auction.undercut then
                row.statusText:SetText("|cffff0000" .. (auction.undercutCount or 1) .. " undercuts\n" .. self:FormatMoney(auction.delta) .. "|r")
                row.cancelBtn:Enable()
            else
                row.statusText:SetText("|cff00ff00Cheapest!|r")
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

    -- Disable UI to prevent concurrent scans
    if self.undercutPane and self.undercutPane.scanBtn then
        self.undercutPane.scanBtn:Disable()
    end
    if addon.fullScanBtn then addon.fullScanBtn:Disable() end
    if addon.importBtn then addon.importBtn:Disable() end

    self.isUndercutScan = true
    -- Hide other panes
    -- if addon.ahResultsPane then addon.ahResultsPane:Hide() end
    -- if addon.postPane then addon.postPane:Hide() end
    
    -- self.undercutPane:Show()
    self.undercutPane.status:SetText("Fetching your auctions...")
    self.undercutResults = {}
    self:RefreshUndercutPane()
    
    -- 1. Scan player's auctions
    local numOwnerAuctions = GetNumAuctionItems("owner")
    if numOwnerAuctions == 0 then
        self.undercutPane.status:SetText("No active auctions found.")
        addon:EndUndercutScan()
        return
    end

    local itemsToScanMap = {}
    for i = 1, numOwnerAuctions do
        local name, texture, count, quality, canUse, level, levelColHeader, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemId = GetAuctionItemInfo("owner", i)
        
        -- saleStatus: 0 = active, 1 = sold
        if saleStatus == 0 and buyoutPrice > 0 then
            local itemLink = GetAuctionItemLink("owner", i)
            table.insert(self.undercutResults, {
                name = name,
                texture = texture,
                count = count,
                buyout = buyoutPrice,
                undercut = false,
                scanning = false,
                scanned = false,
                link = itemLink
            })
            itemsToScanMap[name] = true
        end
    end

    if #self.undercutResults == 0 then
         self.undercutPane.status:SetText("No active auctions with buyout found.")
         addon:EndUndercutScan()
         return
    end

    self.itemsToScan = {}
    for name, _ in pairs(itemsToScanMap) do
        table.insert(self.itemsToScan, name)
    end

    self.undercutScanIndex = 1
    self:ScanNextUndercut()
end

function addon:ScanNextUndercut()
    if not self.undercutPane or not self.undercutPane:IsShown() then 
        self.isUndercutScan = false
        addon:EndUndercutScan()
        return 
    end

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
    local canQuery = CanSendAuctionQuery()
    if not canQuery then
        if self.undercutPane then
            self.undercutPane.status:SetText(string.format("|cffff0000Throttled (Wait)|r - Scanning %s", itemName))
        end
        C_Timer.After(1.0, function() addon:SearchForUndercut(itemName) end)
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
                    if owner and owner ~= UnitName("player") then
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
            C_Timer.After(0.2, function() addon:ScanNextUndercut() end)
        end)
    end)

    QueryAuctionItems(itemName, nil, nil, 0, nil, nil, false, true)
end

function addon:CancelUndercutAuction(auction)
    if addon.isCancelling then return end

    -- Need to find the current ownerIndex as it might have changed if auctions were cancelled
    local numOwnerAuctions = GetNumAuctionItems("owner")
    local targetIndex = nil
    
    for i = 1, numOwnerAuctions do
        local name, texture, count, quality, canUse, level, levelColHeader, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemId = GetAuctionItemInfo("owner", i)
        
        if name == auction.name and count == auction.count and buyoutPrice == auction.buyout and saleStatus == 0 then
            targetIndex = i
            break
        end
    end
    
    if targetIndex then
        addon.isCancelling = true
        addon:RefreshUndercutPane() -- UI updates to show locking state

        CancelAuction(targetIndex)
        self.print("Cancelled auction for " .. auction.name)
        
        -- Wait for confirmation event
        if not self.cancellationListener then
            self.cancellationListener = CreateFrame("Frame")
        end
        local listener = self.cancellationListener
        listener:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
        
        -- Timeout safety
        if self.cancelTimeout then self.cancelTimeout:Cancel() end
        self.cancelTimeout = C_Timer.After(4.0, function()
             listener:UnregisterAllEvents()
             addon.isCancelling = false
             -- Force remove row on timeout to prevent stuck UI
             for i, res in ipairs(self.undercutResults) do
                if res == auction then
                    table.remove(self.undercutResults, i)
                    break
                end
             end
             addon:RefreshUndercutPane()
             addon.print("Cancellation confirmation timed out.")
        end)
        
        listener:SetScript("OnEvent", function(frame, event)
            if event == "AUCTION_OWNED_LIST_UPDATE" then
                -- Success!
                frame:UnregisterAllEvents()
                if self.cancelTimeout then self.cancelTimeout:Cancel() self.cancelTimeout = nil end
                
                addon.isCancelling = false
                -- Remove from results
                for i, res in ipairs(self.undercutResults) do
                    if res == auction then
                        table.remove(self.undercutResults, i)
                        break
                    end
                end
                addon:RefreshUndercutPane()
            end
        end)
    else
        self.print("Could not find auction to cancel. It might have already been cancelled or sold.")
    end
end
function addon:EndUndercutScan()
    self.isUndercutScan = false
    if self.undercutResults then
        for _, auction in ipairs(self.undercutResults) do
            -- If we were just scanning this, it's now done
            if auction.scanning then
                auction.scanned = true
            end
            auction.scanning = false
        end
    end
    if self.undercutPane and self.undercutPane.scanBtn then
        self.undercutPane.scanBtn:Enable()
    end
    if addon.fullScanBtn then addon.fullScanBtn:Enable() end
    if addon.importBtn then addon.importBtn:Enable() end
    addon:RefreshUndercutPane()
end
