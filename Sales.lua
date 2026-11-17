-- Sales, from the auction house's "Auction successful" mails. Each one is
-- saved as you take its gold, which happens once per mail, so nothing counts
-- twice. Kept for good, for all your characters. Each batch you take is
-- summed up in chat: what each item brought, and in how many sales.

local _, addon = ...

-- Item IDs by name, from every item the addon knows: your lists first, then
-- recipes, your auctions, prices, vendor prices and price history. Built when
-- first needed, and again at each visit to the mailbox.
local byName

local function KnownNames()
    local names, checked = {}, {}
    local function Add(itemID)
        if not itemID or checked[itemID] then return end
        checked[itemID] = true
        local name = C_Item.GetItemNameByID(itemID)
        if name and not names[name] then names[name] = itemID end
    end
    for itemID in pairs(addon:Index().tracked) do Add(itemID) end
    for itemID in pairs(addon.db.recipes) do Add(itemID) end
    for _, snapshot in pairs(addon.db.listed) do
        for itemID in pairs(snapshot.items) do Add(itemID) end
    end
    for itemID in pairs(addon.db.prices) do Add(itemID) end
    for itemID in pairs(addon.db.vendor) do Add(itemID) end
    for itemID in pairs(addon.db.history.days) do Add(itemID) end
    for itemID in pairs(addon.db.history.weeks) do Add(itemID) end
    return names
end

-- The mail names the item only. C_Item.GetItemInfoInstant finds an ID by
-- name for some items only (it missed most of the first sales), so the rest
-- are looked up among the items the addon knows.
local function ItemIDByName(name)
    if not name then return nil end
    local itemID = C_Item.GetItemInfoInstant(name)
    if itemID then return itemID end
    byName = byName or KnownNames()
    return byName[name]
end

addon:On("MAIL_SHOW", function() byName = nil end)

-- Sales saved without an item ID get one where the name is known now.
addon:Listen("LOGIN", function()
    for _, sale in ipairs(addon.db.sales) do
        if not sale.itemID then sale.itemID = ItemIDByName(sale.name) end
    end
end)

-- What each item brought: { units, sales, total, low, high } per item ID,
-- or per name for an item whose ID isn't known. Built when first asked for,
-- and again after the next sale.
local stats

local function BuildStats()
    stats = {}
    for _, sale in ipairs(addon.db.sales) do
        sale.itemID = sale.itemID or ItemIDByName(sale.name)
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

-- What the mails taken since the last summary paid out, per item:
-- { money, sales, items = { [itemID or name] = { itemID, name, sales, units, money } } }
local collected
local takes = 0 -- counts takes, so only the latest one's timer prints

-- Open All takes a mail every 0.15 seconds or so; a pause this long ends a batch.
local SUMMARY_DELAY = 3

local function PrintCollected()
    if not collected then return end
    local summary = collected
    collected = nil
    local items = {}
    for _, item in pairs(summary.items) do items[#items + 1] = item end
    table.sort(items, function(a, b)
        if a.money ~= b.money then return a.money > b.money end
        return a.name < b.name
    end)
    addon:Print(("Collected %s from %d %s"):format(addon.Money(summary.money), summary.sales,
        summary.sales == 1 and "sale" or "sales"))
    for _, item in ipairs(items) do
        -- The items sold, when sales held more than one each.
        local units = item.units > item.sales and (", %d items"):format(item.units) or ""
        DEFAULT_CHAT_FRAME:AddMessage(("   %s: %d %s%s, %s"):format(addon.UI.ItemLink(item.itemID) or item.name,
            item.sales, item.sales == 1 and "sale" or "sales", units, addon.Money(item.money)))
    end
end

-- money is what the mail paid out: the price less the house's cut, plus the
-- deposit back.
local function Collect(itemID, name, count, money)
    collected = collected or { money = 0, sales = 0, items = {} }
    local key = itemID or name
    local item = collected.items[key]
    if not item then
        item = { itemID = itemID, name = name, sales = 0, units = 0, money = 0 }
        collected.items[key] = item
    end
    item.sales = item.sales + 1
    item.units = item.units + count
    item.money = item.money + money
    collected.sales = collected.sales + 1
    collected.money = collected.money + money
    takes = takes + 1
    local this = takes
    C_Timer.After(SUMMARY_DELAY, function()
        if this == takes then PrintCollected() end
    end)
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

    local itemID = ItemIDByName(name)
    local craft = addon:CraftFor(itemID)
    local cost, complete
    if craft then cost, complete = addon:CraftCost(craft) end
    count = math.max(1, count or 1)
    table.insert(addon.db.sales, {
        t = time(),
        itemID = itemID,
        name = name,
        count = count,
        price = price or 0,               -- the whole sale
        cut = cut or 0,                   -- the house's cut
        cost = complete and cost or nil,  -- craft cost per item when sold
        char = addon:CharKey(),
    })
    Collect(itemID, name, count, money)
    stats = nil
    addon:Fire("SALES")
    addon:Refresh()
end

-- Every way the gold leaves a mail: its money button, Open All and mail
-- addons call TakeInboxMoney; Shift-click calls AutoLootMailItem.
if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", Record) end
if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", Record) end
addon:On("MAIL_INBOX_UPDATE", function() wipe(taken) end)
-- Closing the mailbox doesn't wait for the pause.
addon:On("MAIL_CLOSED", PrintCollected)
