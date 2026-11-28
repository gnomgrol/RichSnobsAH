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
        lists = {},        -- { name, collapsed, notForSale, snipe, stay, entries = { entry, ... } };
                           -- Next on the Sell tab skips a list marked notForSale, the
                           -- Snipe tab watches the items of a list marked snipe, and the
                           -- Stay cheapest tab keeps those of a list marked stay cheapest
        prices = {},       -- [itemID] = { p = copper per unit, t = time() }
        vendor = {},       -- [itemID] = copper per unit, unlimited vendor supply
        commodity = {},    -- [itemID] = true for commodities, false for items
        listed = {},       -- [character] = { t = time(), items = { [itemID] = n } }
        recipes = {},      -- [itemID] = { recipeID, prof, reagents, yield }: what your characters'
                           -- learned recipes make, saved from their profession windows
        cooldowns = {},    -- [recipeID] = true for a recipe with a cooldown, like a transmute:
                           -- it never makes a reagent for another craft
        sales = {},        -- { t, itemID, name, count, price, cut, cost, char }, oldest first,
                           -- kept for good; from the auction house's mail (Sales.lua)
        purchases = {},    -- { t, itemID, count, price, char, disenchanted }, oldest first, kept
                           -- for good; your buyouts at the auction house (Auction.lua);
                           -- disenchanted: a disenchant of the item counted what it cost
        posted = {},       -- [character] = { [itemID] = { [price each] = time() } }: your
                           -- posts for a month, to tell a sale mail's item (Sales.lua)
        history = { days = {}, weeks = {} }, -- [itemID] = the item's daily and weekly
                           -- prices, each packed into a string (History.lua); kept for good
        minimap = { hide = false }, -- LibDBIcon's settings: hide, minimapPos
        duration = 2,      -- 1, 2, 3 = 2, 8, 24 hours
        snipe = { cut = 30, max = {} }, -- the Snipe tab: an item's max is cut percent under its
                           -- usual price unless max[itemID] holds your own, copper per unit
        floors = {},       -- [itemID] = copper per unit: the Stay cheapest tab never posts under
                           -- it; without one, under break-even
        perPost = {},      -- [itemID] = how many the Stay cheapest tab puts up per post, and
                           -- keeps up at your price while the cheapest is yours; one without
        disenchant = { armor = true, weapons = true, minItemLevel = 5, maxItemLevel = 999, minProfit = 10000,
            salvager = false, maxQuality = 3, askOver = 250000 },
                           -- the DE buy tab's scan: the item classes, the item levels from
                           -- the low end of one band to the high end of another (999: no
                           -- top), and the least profit a deal leaves, copper; salvager: you
                           -- disenchant at an Arcane Salvager, so greens are worth more;
                           -- maxQuality: the best quality scanned for, 2 to 4 (green to
                           -- epic); askOver: Buy asks first above this price, copper, 0 never
        disenchanted = { salvager = { count = 0, got = 0, expected = 0 },
            plain = { count = 0, got = 0, expected = 0 } },
                           -- your greens disenchanted, at an Arcane Salvager and elsewhere: how
                           -- many, the materials they gave and what the tables expected of them
                           -- (Disenchant.lua)
        bagDisenchant = { keepSellers = true, ignored = {} },
                           -- the Disenchant tab for your bags: keepSellers leaves an item that
                           -- sells for more than its materials bring out of Disenchant next;
                           -- ignored[itemID] = true leaves the item out for good
        disenchantResults = { count = 0, materials = {}, paid = 0, paidFor = 0, last = {} },
                           -- your disenchants since `since` = time(), the first or a reset: how
                           -- many, the materials they gave ([itemID] = n), what you paid at the
                           -- auction house for paidFor of them, and the last ten as
                           -- { t, itemID, materials } (Disenchant.lua)
        -- lastFullScan = time() of the last whole-house snapshot, for its cooldown
        -- window = where you moved the window, away from the auction house
        -- auctionTab = true when the auction house last closed on this addon's tab
        -- hotkey = the key for the shown tab's main button, like "SHIFT-F" (Window.lua)
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
        if db[key] == nil then
            db[key] = value
        elseif type(value) == "table" and type(db[key]) == "table" then
            -- A settings table gets the keys added since it was saved.
            for inner, default in pairs(value) do
                if db[key][inner] == nil then db[key][inner] = default end
            end
        end
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

-- Every item a list deals in: its entries, their reagents, and the reagents
-- of any reagent one of your recipes makes, so a price check can weigh
-- buying it against crafting it.
function addon:ListItemIDs(list, into)
    into = into or {}
    local opened = {}
    local function AddReagents(reagents)
        for _, reagent in ipairs(reagents or {}) do
            into[#into + 1] = reagent.itemID
            local craft = not opened[reagent.itemID] and self:ReagentCraft(reagent.itemID)
            opened[reagent.itemID] = true
            if craft then AddReagents(craft.reagents) end
        end
    end
    for _, entry in ipairs(list.entries) do
        if entry.itemID then into[#into + 1] = entry.itemID end
        AddReagents(entry.reagents)
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

-- count, how many were up, goes to the price history when the source knows
-- it. noHistory: the snipe rounds' prices stay out of the history, or the
-- odd cheap offer they look for would become the usual price.
function addon:SetPrice(itemID, copper, count, noHistory)
    if not itemID or not copper or copper <= 0 then return end
    self.db.prices[itemID] = { p = copper, t = time() }
    if not noHistory then self:RecordHistory(itemID, copper, count) end
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

-- What crafts an item that another craft takes: as CraftFor, but never a
-- recipe with a cooldown, which makes one a day at most.
function addon:ReagentCraft(itemID)
    if not itemID then return nil end
    local cooldowns = self.db.cooldowns
    local entry = self:Index().crafts[itemID]
    if entry and not cooldowns[entry.recipeID] then return entry end
    local known = self.db.recipes[itemID]
    if known and not cooldowns[known.recipeID] then return known end
end

-- The price each that pays back what one cost you after the cut: its craft
-- cost once every reagent has a price, else what you paid for them on
-- average. Nil without either.
function addon:BreakEven(itemID)
    local craft = self:CraftFor(itemID)
    local cost, complete
    if craft then cost, complete = self:CraftCost(craft) end
    if not (cost and complete) then
        local bought = self:PurchaseStats(itemID)
        cost = bought and bought.total / bought.units
    end
    if cost then return math.ceil(cost * 100 / 95) end
end

-- The least Stay cheapest posts at: your own floor, else break-even; nil
-- without either. own: the floor is yours.
function addon:Floor(itemID)
    local own = self.db.floors[itemID]
    if own then return own, true end
    return self:BreakEven(itemID), false
end

-- The cheaper of buying a reagent and crafting it with one of your recipes,
-- whether every price was known, and the recipe when crafting wins.
function addon:ReagentCost(itemID, visiting)
    local price = self:BuyPrice(itemID)
    local craft = self:ReagentCraft(itemID)
    if craft then
        local cost, complete = self:CraftCost(craft, visiting)
        if cost and complete and (not price or cost < price) then return cost, true, craft end
        if not price and cost then return cost, false, craft end
    end
    if price then return price, true end
    return nil, false
end

-- The recipe a list makes a reagent with: one of yours, when crafting costs
-- less than buying, or when there is no price to buy it at.
function addon:CraftedReagent(itemID)
    return (select(3, self:ReagentCost(itemID)))
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

-- Every planned craft, in the order of your lists. A list's sub-crafts
-- (Needs) come ahead of its crafts, a reagent's own sub-crafts before it,
-- marked sub: their count follows from the list, not a plan of their own.
function addon:Queue()
    local queue = {}
    for _, list in ipairs(self.db.lists) do
        local _, subs = self:Needs(list)
        for i = #subs, 1, -1 do
            queue[#queue + 1] = { list = list, entry = subs[i], sub = true }
        end
        for _, entry in ipairs(list.entries) do
            if entry.recipeID and self:Planned(entry) > 0 then
                queue[#queue + 1] = { list = list, entry = entry }
            end
        end
    end
    return queue
end

-- A list's sub-craft of an item, as an entry the queue can craft: the same
-- table from one redraw to the next, kept while the list exists and never
-- saved. make is the crafts the list still lacks.
local subEntries = setmetatable({}, { __mode = "k" })

local function SubEntry(list, itemID, recipe, crafts)
    local subs = subEntries[list]
    local sub = subs[itemID]
    if not sub then
        sub = { itemID = itemID, sub = true }
        subs[itemID] = sub
    end
    sub.recipeID, sub.prof, sub.reagents, sub.yield = recipe.recipeID, recipe.prof, recipe.reagents, recipe.yield
    sub.make = crafts
    return sub
end

-- What a list's planned crafts use in all, by item, and its sub-crafts. A
-- reagent you craft (CraftedReagent) is a sub-craft for the part that your
-- bags and the list's own planned crafts of it don't cover, and passes
-- that on to its own reagents. Sub-crafts come before the ones they use.
function addon:Needs(list)
    local needs, made, subs = {}, {}, {}
    -- One that's no longer needed keeps no count.
    subEntries[list] = subEntries[list] or {}
    for _, sub in pairs(subEntries[list]) do sub.make = nil end

    -- The items in an order where every craft that uses one comes before
    -- it, so its need is whole by the time it is passed on; otherwise in
    -- the list's order.
    local order, seen = {}, {}
    local function Visit(itemID)
        if seen[itemID] then return end
        seen[itemID] = true
        local craft = self:CraftedReagent(itemID)
        for _, reagent in ipairs(craft and craft.reagents or {}) do Visit(reagent.itemID) end
        table.insert(order, 1, itemID)
    end

    for _, entry in ipairs(list.entries) do
        local planned = self:Planned(entry)
        if planned > 0 then
            if entry.itemID then made[entry.itemID] = (made[entry.itemID] or 0) + planned * (entry.yield or 1) end
            for _, reagent in ipairs(entry.reagents or {}) do
                needs[reagent.itemID] = (needs[reagent.itemID] or 0) + reagent.count * planned
                Visit(reagent.itemID)
            end
        end
    end

    for _, itemID in ipairs(order) do
        local craft = self:CraftedReagent(itemID)
        local short = craft and (needs[itemID] or 0) - self:BagCount(itemID) - (made[itemID] or 0) or 0
        if short > 0 then
            local crafts = math.ceil(short / (craft.yield or 1))
            for _, reagent in ipairs(craft.reagents) do
                needs[reagent.itemID] = (needs[reagent.itemID] or 0) + reagent.count * crafts
            end
            subs[#subs + 1] = SubEntry(list, itemID, craft, crafts)
        end
    end
    return needs, subs
end

-- How many of an item a list's planned crafts use in all.
function addon:Need(list, itemID)
    return self:Needs(list)[itemID] or 0
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

-- Each item in the bags, in bag order: fn(bag, slot, info).
function addon:EachBagItem(fn)
    for bag = 0, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info then fn(bag, slot, info) end
        end
    end
end

-- How many bag slots are empty.
function addon:FreeBagSlots()
    local free = 0
    for bag = 0, LAST_BAG do free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0) end
    return free
end

-- The bag item its link names so, like a cast's target: its item ID.
function addon:ItemNamedInBags(name)
    if not name or name == "" then return nil end
    for bag = 0, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink and info.hyperlink:match("|h%[(.-)%]|h") == name then return info.itemID end
        end
    end
end

-- The item locked in the bags, like one a spell is cast on: its item ID; nil
-- when none is, or items of more than one kind are.
function addon:LockedInBags()
    local found
    for bag = 0, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.isLocked then
                if found and found ~= info.itemID then return nil end
                found = info.itemID
            end
        end
    end
    return found
end
