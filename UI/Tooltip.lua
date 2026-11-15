-- Item tooltips show the last auction price and its age, the vendor price,
-- and the craft cost when one of your lists crafts the item.

local _, addon = ...

local LABEL = { 1, 0.82, 0 }

local function AddLines(tooltip, itemID)
    local price, seen = addon:GetAHPrice(itemID)
    local vendor = addon.db.vendor[itemID]
    local craft = addon:Index().crafts[itemID]
    local cost, complete
    if craft then cost, complete = addon:CraftCost(craft) end
    if not price and not vendor and not cost then return end

    local r, g, b = unpack(LABEL)
    if price then
        tooltip:AddDoubleLine(("AH, %s ago"):format(addon.Age(time() - seen)), addon.Money(price, true), r, g, b, 1, 1, 1)
    end
    if vendor then
        tooltip:AddDoubleLine("Vendor", addon.Money(vendor, true), r, g, b, 1, 1, 1)
    end
    if cost then
        tooltip:AddDoubleLine(complete and "Craft cost" or "Craft cost, prices missing", addon.Money(cost, true),
            r, g, b, 1, 1, 1)
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
