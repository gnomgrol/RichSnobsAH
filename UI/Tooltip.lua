-- Item tooltips show the last auction price and its age, the auction prices
-- of the last 30 days, the vendor price, the craft cost when one of your
-- lists crafts the item or one of your characters knows its recipe, and what
-- your sales of it brought.

local _, addon = ...

local LABEL = { 1, 0.82, 0 }

local function AddLines(tooltip, itemID)
    local price, seen = addon:GetAHPrice(itemID)
    local history = addon:PriceStats(itemID)
    -- A single day says no more than the AH line.
    if history and history.days < 2 then history = nil end
    local vendor = addon.db.vendor[itemID]
    local craft = addon:CraftFor(itemID)
    local cost, complete
    if craft then cost, complete = addon:CraftCost(craft) end
    -- No reagent priced yet leaves no cost worth showing.
    if cost == 0 and not complete then cost = nil end
    local sold = addon:SaleStats(itemID)
    if not price and not history and not vendor and not cost and not sold then return end

    local r, g, b = unpack(LABEL)
    if price then
        tooltip:AddDoubleLine(("AH, %s ago"):format(addon.Age(time() - seen)), addon.Money(price, true), r, g, b, 1, 1, 1)
    end
    -- Each day's cheapest price, on the days with one.
    if history then
        tooltip:AddDoubleLine(("AH %d days, min / avg / max"):format(history.days), ("%s / %s / %s"):format(
            addon.Money(history.low), addon.Money(history.avg), addon.Money(history.high)), r, g, b, 1, 1, 1)
    end
    if vendor then
        tooltip:AddDoubleLine("Vendor", addon.Money(vendor, true), r, g, b, 1, 1, 1)
    end
    if cost then
        tooltip:AddDoubleLine(complete and "Craft cost" or "Craft cost, prices missing", addon.Money(cost, true),
            r, g, b, 1, 1, 1)
    end
    -- What one brought, before the house's cut.
    if sold then
        tooltip:AddDoubleLine(("Sold %d, min / avg / max"):format(sold.units), ("%s / %s / %s"):format(
            addon.Money(sold.low), addon.Money(sold.total / sold.units), addon.Money(sold.high)), r, g, b, 1, 1, 1)
    end
end

if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if not addon.db or not data or not data.id then return end
        -- The comparison tooltips beside it would repeat the same lines.
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
        AddLines(tooltip, data.id)
    end)
end
