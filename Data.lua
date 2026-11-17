-- Saved data: the lists, prices, vendor prices and what each character has
-- listed. Everything is keyed by item ID.

local _, addon = ...

local SCHEMA = 2
local PRICE_KEEP = 30 * 86400   -- prices older than this go at login
local LISTED_KEEP = 86400       -- a character's listed counts lapse after a day

--[[ A list entry:
    itemID    the item, or what the recipe makes (nil for enchants)
    recipeID  set for crafts
    name      the recipe's name, for crafts that make no item
    icon      the recipe's icon, likewise
    yield     average items one craft makes
    reagents  { { itemID = n, count = n }, ... }
    prof      the profession's name, to say which window to open
    make      crafts still planned, nil when none; puts the craft in the queue,
              drives what the list is missing, counts down as crafts finish
    amount    the plan that Plan sets at once, kept; nil until you set one
    expanded  reagent rows shown
]]

local function Defaults()
    return {
        schema = SCHEMA,
        lists = {},        -- { name, collapsed, notForSale, entries = { entry, ... } };
                           -- Next on the Sell tab skips a list marked notForSale
        prices = {},       -- [itemID] = { p = copper per unit, t = time() }
        vendor = {},       -- [itemID] = copper per unit, unlimited vendor supply
        commodity = {},    -- [itemID] = true for commodities, false for items
        listed = {},       -- [character] = { t = time(), items = { [itemID] = n } }
        recipes = {},      -- [itemID] = { reagents, yield }: what your characters' learned
                           -- recipes make, saved from their profession windows
        sales = {},        -- { t, itemID, name, count, price, cut, cost, char }, oldest first,
                           -- kept for good; from the auction house's mail (Sales.lua)
        purchases = {},    -- { t, itemID, count, price, char }, oldest first, kept for good;
                           -- your buyouts at the auction house (Auction.lua)
        history = { days = {}, weeks = {} }, -- [itemID] = the item's daily and weekly
                           -- prices, each packed into a string (History.lua); kept for good
        minimap = { hide = false }, -- LibDBIcon's settings: hide, minimapPos
        duration = 2,      -- 1, 2, 3 = 2, 8, 24 hours
        -- lastFullScan = time() of the last whole-house snapshot, for its cooldown
        -- window = where you moved the window, away from the auction house
        -- auctionTab = true when the auction house last closed on this addon's tab
    }
end

function addon:InitDB()
    local db = RichSnobsAHDB
    -- Forever starts fresh: nothing from the TBC data format carries over.
    if type(db) ~= "table" or db.schema ~= SCHEMA then
        db = Defaults()
        RichSnobsAHDB = db
    end
    for key, value in pairs(Defaults()) do
        if db[key] == nil then db[key] = value end
    end

    local now = time()
    for itemID, price in pairs(db.prices) do
        if type(price) ~= "table" or now - (price.t or 0) > PRICE_KEEP then
            db.prices[itemID] = nil
        end
    end
    for key, snapshot in pairs(db.listed) do
        if now - (snapshot.t or 0) > LISTED_KEEP then db.listed[key] = nil end
    end

    self.db = db
end

--------------------------------------------------------------------------------
-- Lists
--------------------------------------------------------------------------------

function addon:ListsChanged()
    self.index = nil
    self:Refresh()
end

local function Move(t, from, to)
    if from == to or not t[from] then return end
    local value = table.remove(t, from)
    table.insert(t, math.max(1, math.min(to, #t + 1)), value)
end

function addon:NewList(name)
    local list = { name = name, entries = {} }
    table.insert(self.db.lists, list)
    self:ListsChanged()
    return list
end

function addon:RenameList(list, name)
    list.name = name
    self:ListsChanged()
end

function addon:DeleteList(list)
    tDeleteItem(self.db.lists, list)
    if self.selected and self.selected.list == list then self.selected = nil end
    self:ListsChanged()
end

function addon:MoveList(from, to)
    Move(self.db.lists, from, to)
    self:ListsChanged()
end

function addon:FindEntry(list, itemID, recipeID)
    for i, entry in ipairs(list.entries) do
        if recipeID then
            if entry.recipeID == recipeID then return entry, i end
        elseif not entry.recipeID and entry.itemID == itemID then
            return entry, i
        end
    end
end

-- Returns the entry and whether it is new; an item already on the list
-- isn't added twice.
function addon:AddItem(list, itemID)
    local entry = self:FindEntry(list, itemID)
    if entry then return entry, false end
    entry = { itemID = itemID }
    table.insert(list.entries, entry)
    self:ListsChanged()
    return entry, true
end

-- Adding a recipe that is already on the list refreshes its reagents.
function addon:AddRecipe(list, recipe)
    local entry = self:FindEntry(list, nil, recipe.recipeID)
    local added = not entry
    if added then
        entry = {}
        table.insert(list.entries, entry)
    end
    for _, key in ipairs({ "recipeID", "itemID", "name", "icon", "yield", "reagents", "prof" }) do
        entry[key] = recipe[key]
    end
    self:ListsChanged()
    return entry, added
end

function addon:RemoveEntry(list, entry)
    tDeleteItem(list.entries, entry)
    -- A removed craft mustn't stay behind the Craft button.
    if self.selected and self.selected.entry == entry then self.selected = nil end
    self:ListsChanged()
end

function addon:MoveEntry(list, from, to)
    Move(list.entries, from, to)
    self:ListsChanged()
end

function addon:MoveEntryToList(entry, fromList, toList)
    if fromList == toList then return end
    tDeleteItem(fromList.entries, entry)
    table.insert(toList.entries, entry)
    self:ListsChanged()
end

-- Every item a list deals in: its entries and their reagents.
function addon:ListItemIDs(list, into)
    into = into or {}
    for _, entry in ipairs(list.entries) do
        if entry.itemID then into[#into + 1] = entry.itemID end
        for _, reagent in ipairs(entry.reagents or {}) do into[#into + 1] = reagent.itemID end
    end
    return into
end

-- Which entry crafts an item, and which items any list mentions.
function addon:Index()
    if self.index then return self.index end
    local index = { crafts = {}, tracked = {} }
    for _, list in ipairs(self.db.lists) do
        for _, entry in ipairs(list.entries) do
            if entry.itemID then
                index.tracked[entry.itemID] = true
                if entry.recipeID and not index.crafts[entry.itemID] then
                    index.crafts[entry.itemID] = entry
                end
            end
            for _, reagent in ipairs(entry.reagents or {}) do
                index.tracked[reagent.itemID] = true
            end
        end
    end
    self.index = index
    return index
end

--------------------------------------------------------------------------------
-- Prices
--------------------------------------------------------------------------------

-- count, how many were up, goes to the price history when the source knows it.
function addon:SetPrice(itemID, copper, count)
    if not itemID or not copper or copper <= 0 then return end
    self.db.prices[itemID] = { p = copper, t = time() }
    self:RecordHistory(itemID, copper, count)
    self:Refresh()
end

-- The cheapest auction last seen, and when.
function addon:GetAHPrice(itemID)
    local price = itemID and self.db.prices[itemID]
    if price then return price.p, price.t end
end

-- What one unit costs to buy, from a vendor or the auction house, whichever
-- is cheaper, and which one that is.
function addon:BuyPrice(itemID)
    local vendor = self.db.vendor[itemID]
    local ah = self:GetAHPrice(itemID)
    if vendor and (not ah or vendor <= ah) then return vendor, "vendor" end
    if ah then return ah, "ah" end
end

-- Copper per item the entry makes (per craft for enchants). complete is
-- false when a reagent has no price yet; the sum then leaves it out.
function addon:CraftCost(entry, visiting)
    if not entry.reagents or #entry.reagents == 0 then return nil end
    visiting = visiting or {}
    if visiting[entry] then return nil end
    visiting[entry] = true

    local total, complete = 0, true
    for _, reagent in ipairs(entry.reagents) do
        local unit, known = self:ReagentCost(reagent.itemID, visiting)
        if unit then total = total + unit * reagent.count end
        if not known then complete = false end
    end

    visiting[entry] = nil
    return total / (entry.yield or 1), complete
end

-- What crafts an item: the list entry that does, else a recipe one of your
-- characters knows.
function addon:CraftFor(itemID)
    return itemID and (self:Index().crafts[itemID] or self.db.recipes[itemID])
end

-- The cheaper of buying a reagent and crafting it from another list entry.
function addon:ReagentCost(itemID, visiting)
    local price = self:BuyPrice(itemID)
    local craft = self:Index().crafts[itemID]
    if craft then
        local cost, complete = self:CraftCost(craft, visiting)
        if cost and complete and (not price or cost < price) then return cost, true end
        if not price and cost then return cost, false end
    end
    if price then return price, true end
    return nil, false
end

-- What one sale brings in after the 5% auction house cut, minus the cost.
function addon:Profit(entry)
    local price = self:GetAHPrice(entry.itemID)
    local cost, complete = self:CraftCost(entry)
    if price and cost and complete then return price * 0.95 - cost end
end

--------------------------------------------------------------------------------
-- Counts
--------------------------------------------------------------------------------

function addon:BagCount(itemID)
    return C_Item.GetItemCount(itemID) or 0
end

-- Listed on the auction house across your characters, from each one's
-- last visit within the day.
function addon:ListedCount(itemID)
    local total, now = 0, time()
    for _, snapshot in pairs(self.db.listed) do
        if now - snapshot.t <= LISTED_KEEP then total = total + (snapshot.items[itemID] or 0) end
    end
    return total
end

-- Crafts the reagents in your bags allow. The bank doesn't count: you can't
-- craft from it.
function addon:CraftableCount(entry)
    if not entry.reagents or #entry.reagents == 0 then return nil end
    local most
    for _, reagent in ipairs(entry.reagents) do
        local n = math.floor(self:BagCount(reagent.itemID) / reagent.count)
        if not most or n < most then most = n end
    end
    return most
end

-- The crafts still planned; 0 keeps a craft off the queue. Each finished
-- craft takes one off (Professions.lua).
function addon:Planned(entry)
    return entry.make or 0
end

function addon:SetPlanned(entry, n)
    n = math.floor(n or 0)
    entry.make = n > 0 and n or nil
    self:Refresh()
end

-- The amount Plan sets at once; 0 forgets it.
function addon:SetPlanAmount(entry, n)
    n = math.floor(n or 0)
    entry.amount = n > 0 and n or nil
    self:Refresh()
end

-- Sets every craft on a list that has a stored amount to plan that amount.
-- Returns the crafts planned in all.
function addon:PlanList(list)
    local total = 0
    for _, entry in ipairs(list.entries) do
        if entry.recipeID and entry.amount then
            self:SetPlanned(entry, entry.amount)
            total = total + entry.amount
        end
    end
    return total
end

-- One press of Craft: the plan, or a single craft when none is planned, cut
-- to what the reagents in your bags allow. The plan comes second.
function addon:CraftBatch(entry)
    local planned = self:Planned(entry)
    return math.min(math.max(planned, 1), self:CraftableCount(entry) or 0), planned
end

-- Every planned craft, in the order of your lists.
function addon:Queue()
    local queue = {}
    for _, list in ipairs(self.db.lists) do
        for _, entry in ipairs(list.entries) do
            if entry.recipeID and self:Planned(entry) > 0 then
                queue[#queue + 1] = { list = list, entry = entry }
            end
        end
    end
    return queue
end

-- How many of an item a list's planned crafts use in all.
function addon:Need(list, itemID)
    local need = 0
    for _, entry in ipairs(list.entries) do
        for _, reagent in ipairs(entry.reagents or {}) do
            if reagent.itemID == itemID then need = need + reagent.count * self:Planned(entry) end
        end
    end
    return need
end

-- What the list still lacks after your bags.
function addon:Missing(list, itemID)
    return math.max(0, self:Need(list, itemID) - self:BagCount(itemID))
end

--------------------------------------------------------------------------------
-- Commodity or item auction
--------------------------------------------------------------------------------

function addon:LearnCommodity(itemID, isCommodity)
    if itemID and type(isCommodity) == "boolean" then self.db.commodity[itemID] = isCommodity end
    return isCommodity
end

-- True or false once the auction house has said, else nil.
function addon:IsCommodity(itemID, location, itemKey)
    local known = self.db.commodity[itemID]
    if known ~= nil then return known end

    if itemKey and C_AuctionHouse.GetItemKeyInfo then
        local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
        if ok and info and type(info.isCommodity) == "boolean" then
            return self:LearnCommodity(itemID, info.isCommodity)
        end
    end

    -- GetItemCommodityStatus takes a bag location only, not an item ID.
    location = location or self:FindInBags(itemID)
    if location and C_AuctionHouse.GetItemCommodityStatus and Enum.ItemCommodityStatus then
        local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, location)
        if ok and status == Enum.ItemCommodityStatus.Commodity then return self:LearnCommodity(itemID, true) end
        if ok and status == Enum.ItemCommodityStatus.Item then return self:LearnCommodity(itemID, false) end
    end
end

-- A best guess for display before the auction house has said: stackable
-- goods are commodities.
function addon:GuessCommodity(itemID)
    local known = self:IsCommodity(itemID)
    if known ~= nil then return known end
    local stack = select(8, C_Item.GetItemInfo(itemID))
    return (stack or 1) > 1
end

--------------------------------------------------------------------------------
-- Bags
--------------------------------------------------------------------------------

local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

-- The first stack of an item in the bags. With sellable, only one the
-- auction house takes (not soulbound, not locked).
function addon:FindInBags(itemID, sellable)
    for bag = 0, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and not info.isLocked then
                local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
                if not sellable or C_AuctionHouse.IsSellItemValid(location, false) then
                    return location, info
                end
            end
        end
    end
end
