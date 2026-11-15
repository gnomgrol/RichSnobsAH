-- Vendor prices: while a merchant window is open, every item the vendor
-- sells in unlimited supply is remembered at its cheapest price per unit.
-- Those items count at the vendor price in craft costs and are left out of
-- auction house price checks.

local _, addon = ...

local function MerchantItem(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(index)
        if info then return info.price, info.stackCount, info.numAvailable, info.hasExtendedCost end
        return nil
    end
    local _, _, price, stack, available, _, _, extendedCost = GetMerchantItemInfo(index)
    return price, stack, available, extendedCost
end

local function ScanMerchant()
    if not addon.db then return end
    local vendor, changed = addon.db.vendor, false
    for index = 1, GetMerchantNumItems() do
        local price, stack, available, extendedCost = MerchantItem(index)
        local link = GetMerchantItemLink(index)
        local itemID = link and C_Item.GetItemInfoInstant(link)
        -- Limited stock and items that cost tokens or currency don't count.
        if itemID and price and price > 0 and available == -1 and not extendedCost then
            local unit = math.floor(price / math.max(1, stack or 1))
            if not vendor[itemID] or unit < vendor[itemID] then
                vendor[itemID] = unit
                changed = true
            end
        end
    end
    if changed then addon:Refresh() end
end

addon:On("MERCHANT_SHOW", ScanMerchant)
addon:On("MERCHANT_UPDATE", ScanMerchant)

-- For a vendor price that is wrong, such as one only a faction discount gave.
function addon:ForgetVendorPrice(itemID)
    self.db.vendor[itemID] = nil
    self:Refresh()
end
