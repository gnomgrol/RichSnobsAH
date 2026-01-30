local addonName, addon = ...

-- Full Scan logic
-- Sequential Scan for all tracked items
function addon:StartFullScan()
    if not addon:IsAHOpen() then
        addon.print("Auction House is not open.")
        return
    end

    local trackedNamesMap = addon:GetAllTrackedItemNames()
    local trackedNames = {}
    for name, _ in pairs(trackedNamesMap) do
        table.insert(trackedNames, name)
    end

    if #trackedNames == 0 then
        addon.print("No items tracked to scan.")
        return
    end

    addon.print(string.format("Starting scan of %d tracked items...", #trackedNames))
    
    -- Disable UI
    if addon.fullScanBtn then addon.fullScanBtn:Disable() end
    if addon.undercutBtn then addon.undercutBtn:Disable() end
    if addon.postBtn then addon.postBtn:Disable() end
    if addon.importBtn then addon.importBtn:Disable() end

    local currentIndex = 1
    local lastPrintedIndex = 0
    local updatedCount = 0

    local function ScanNext()
        if not addon:IsAHOpen() then
            addon.print("AH closed. Stopping scan.")
            addon:EndFullScan()
            return
        end

        if currentIndex > #trackedNames then
            addon.print(string.format("Full scan finished. Updated %d prices.", updatedCount))
            addon:EndFullScan()
            if updatedCount > 0 and addon.mainFrame and addon.mainFrame:IsShown() then
                addon:RefreshMainFrame()
            end
            return
        end

        local itemName = trackedNames[currentIndex]
        
        local canQuery = CanSendAuctionQuery()
        -- Print progress only when we actually start the scan for this item
        if not canQuery then
            C_Timer.After(0.5, ScanNext)
            return
        end

        if lastPrintedIndex ~= currentIndex then
            addon.print(string.format("Scanning (%d/%d): %s", currentIndex, #trackedNames, itemName))
            lastPrintedIndex = currentIndex
        end

        self.retryCount = 0
        -- Register for update
        local scanFrame = CreateFrame("Frame")
        scanFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
        
        local timeout
        timeout = C_Timer.After(5, function()
            if scanFrame.isProcessing then return end
            scanFrame.isProcessing = true
            scanFrame:UnregisterAllEvents()
            currentIndex = currentIndex + 1
            ScanNext()
        end)

        scanFrame:SetScript("OnEvent", function(self, event)
            if self.isProcessing then return end
            
            local batchCount, totalCount = GetNumAuctionItems("list")
            
            if totalCount == 0 and batchCount == 0 then
                 -- Handle potential 0/0 hang in Classic
                 self.retryCount = (self.retryCount or 0) + 1
                 if self.retryCount < 3 then
                     return -- Wait for another event or timeout
                 end
                 -- If we've waited enough, it's actually empty
            end

            self.isProcessing = true
            if timeout then
                timeout:Cancel()
                timeout = nil
            end
            scanFrame:UnregisterAllEvents()

            local minPrice = nil
            for i = 1, batchCount do
                local name, _, count, _, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
                -- Only include auctions with buyout price
                if name == itemName and buyout and buyout > 0 then
                    local unitPrice = math.floor(buyout / count)
                    if not minPrice or unitPrice < minPrice then
                        minPrice = unitPrice
                    end
                end
            end

            if minPrice then
                if addon.db.prices[itemName] ~= minPrice then
                    addon.db.prices[itemName] = minPrice
                    updatedCount = updatedCount + 1
                end
            end

            currentIndex = currentIndex + 1
            -- Small delay between items to be nice to the server
            C_Timer.After(0.2, ScanNext)
        end)

        QueryAuctionItems(itemName, nil, nil, 0, nil, nil, false, true)
    end

    ScanNext()
end

function addon:EndFullScan()
    if addon.fullScanBtn then addon.fullScanBtn:Enable() end
    if addon.undercutBtn then addon.undercutBtn:Enable() end
    if addon.postBtn then addon.postBtn:Enable() end
    if addon.importBtn then addon.importBtn:Enable() end
end
