local addonName, addon = ...

local vendorScanFrame = CreateFrame("Frame")

function addon:ScanMerchantItems()
    local numItems = GetMerchantNumItems()
    local newItemsAdded = 0

    for i = 1, numItems do
        local name, texture, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost = GetMerchantItemInfo(i)
        
        -- -1 means unlimited supply. 
        -- Also check if price is valid (could be 0 for token items without copper cost or other cases)
        if name and numAvailable == -1 and price and price > 0 then
            local costPerItem = math.floor(price / quantity)
            
            -- Only record if it wasn't recorded before OR if price somehow changed (rare but possible across reputations)
            -- If we want to strictly keep the *cheapest* vendor price we've seen (due to rep discounts), we can do so.
            local existingPrice = addon.db.vendorItems[name]
            if not existingPrice or existingPrice > costPerItem then
                addon.db.vendorItems[name] = costPerItem
                if not existingPrice then
                    newItemsAdded = newItemsAdded + 1
                end
            end
        end
    end

    if newItemsAdded > 0 then
        addon.print(string.format("Recorded %d new unlimited vendor items.", newItemsAdded))
    end
    
    -- Refresh UI if open since we might now have vendor prices for tracked items
    if addon.mainFrame and addon.mainFrame:IsShown() then
        addon:RefreshMainFrame()
    end
end

vendorScanFrame:RegisterEvent("MERCHANT_SHOW")
vendorScanFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "MERCHANT_SHOW" then
        addon:ScanMerchantItems()
    end
end)
