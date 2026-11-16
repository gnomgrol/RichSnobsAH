-- Sales, from the auction house's "Auction successful" mails. Each one is
-- saved as you take its gold, which happens once per mail, so nothing counts
-- twice. Kept for good, for all your characters.

local _, addon = ...

-- What each item brought: { units, sales, total, low, high } per item ID,
-- or per name for an item the client didn't know when it sold. Built when
-- first asked for, and again after the next sale.
local stats

local function BuildStats()
    stats = {}
    for _, sale in ipairs(addon.db.sales) do
        -- An item the client didn't know when it sold may be known by now.
        sale.itemID = sale.itemID or C_Item.GetItemInfoInstant(sale.name)
        local key = sale.itemID or sale.name
        local item = stats[key]
        if not item then
            item = { units = 0, sales = 0, total = 0 }
            stats[key] = item
        end
        local each = sale.price / sale.count
        item.units = item.units + sale.count
        item.sales = item.sales + 1
        item.total = item.total + sale.price
        item.low = math.min(item.low or each, each)
        item.high = math.max(item.high or each, each)
    end
end

-- An item's sales: units sold, in how many sales, what they brought in all,
-- and the lowest and highest price each. Nil if it never sold.
function addon:SaleStats(itemID)
    if not stats then BuildStats() end
    if stats[itemID] then return stats[itemID] end
    local name = C_Item.GetItemNameByID(itemID)
    return name and stats[name]
end

-- Mails taken since the inbox last changed: the gold stays in a mail until
-- the server answers, so a second click on it counts once.
local taken = {}

local function Record(index)
    if not addon.db or not index or taken[index] then return end
    local _, _, _, _, money = GetInboxHeaderInfo(index)
    local kind, name, _, price, _, _, cut, _, _, _, count = GetInboxInvoiceInfo(index)
    if kind ~= "seller" or not name or not money or money <= 0 then return end
    taken[index] = true

    -- The mail names the item; the client finds its ID if it knows the item.
    local itemID = C_Item.GetItemInfoInstant(name)
    local craft = addon:CraftFor(itemID)
    local cost, complete
    if craft then cost, complete = addon:CraftCost(craft) end
    table.insert(addon.db.sales, {
        t = time(),
        itemID = itemID,
        name = name,
        count = math.max(1, count or 1),
        price = price or 0,               -- the whole sale
        cut = cut or 0,                   -- the house's cut
        cost = complete and cost or nil,  -- craft cost per item when sold
        char = addon:CharKey(),
    })
    stats = nil
    addon:Fire("SALES")
    addon:Refresh()
end

-- Every way the gold leaves a mail: its money button, Open All and mail
-- addons call TakeInboxMoney; Shift-click calls AutoLootMailItem.
if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", Record) end
if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", Record) end
addon:On("MAIL_INBOX_UPDATE", function() wipe(taken) end)
