-- Disenchanting: what an armor or weapon item breaks into and what that is
-- worth, and the Disenchant tab's scan for auctions worth buying to
-- disenchant.
--
-- The materials go by quality, armor or weapon, and item level in bands of
-- five. The tables are vanilla's, set against Classic's logged disenchants:
-- green weapons at item level 21-30 give Greater Magic Essence, and weapons
-- from 51 up give 22% dust and 3% shards. Three kinds nobody has measured
-- on Forever are estimates: blues at item level 20 or under, which Forever
-- bands its own way; epics from 56, where the sources disagree; and items
-- above vanilla's highest item level, 92.
--
-- A material is worth its last auction price after the house's cut. An
-- essence without a price takes the other size's, three lesser to a greater.
--
-- At an Arcane Salvager, Forever's Enchanting camp feature, its Boosted
-- Disenchanting buff raises the chance of bonus materials. Players' tests
-- found greens giving about 30% more and blues no more; Blizzard gives no
-- rate. With the tab's Salvager ticked, greens are valued so, or by your own
-- disenchants once you did 100 greens at one: every green you disenchant
-- counts its materials against the tables, at a Salvager and elsewhere.
--
-- The scan checks the materials' prices, then reads every page of three
-- browses, one each for green, blue and epic armor and weapons. The house
-- filters by required level only, so each asks for required levels from ten
-- under the range; the items are then judged by the item level the house
-- gives with each. It keeps the items whose cheapest offer leaves at least
-- the minimum profit, a page at a time, so the deals fill in while it runs.
-- Once it is done, the top deals are searched, so Buy buys an auction that
-- is there; one gone or dearer drops out. Searches during the scan would
-- hold up its pages.
--
-- Judging a scan's items takes nothing from the client's item cache: a scan
-- can hold more items than the cache keeps, and asking for all of them had
-- the client dropping and fetching items without end, your lists' too. The
-- quality comes from the browse it was found in, the slot from the client's
-- instant lookup.

local _, addon = ...
local Auction = addon.Auction

local DE = {
    scanning = false,
    -- While scanning: { step, steps, what, items }. Step 1 checks the
    -- materials' prices, each step after it browses a quality, and items
    -- counts what that browse has read so far.
    progress = nil,
    -- { itemID, key, level, price, value, profit, complete, estimate, row, count },
    -- most profit first; row: the cheapest auction a search found; count: how
    -- many of the auctions it found leave the minimum profit
    deals = {},
    scannedAt = nil, -- time() when the last scan ended
    scanned = 0,     -- the items the scan read, so far while it runs
    cutShort = false, -- a page of the last scan never came
}
addon.Disenchant = DE

local ARMOR, WEAPON = 4, 2 -- item class IDs
local AFTER_CUT = 0.95     -- what a sale leaves after the house's cut
local VANILLA_TOP = 92     -- vanilla's highest item level; Forever's items above it are estimates
local SALVAGER = 1.3       -- what greens give at an Arcane Salvager, by players' tests
local MEASURED_AT = 100    -- your greens disenchanted at one that take over from players' tests
DE.MEASURED_AT = MEASURED_AT
local SEARCH_AHEAD = 5     -- top deals kept searched, so Buy has an auction to buy
local CHECK_KEEP = 120     -- seconds a search's answer stands before the deal is searched again
local ANSWER_TIMEOUT = 10  -- seconds before a search nobody answered can go again
local LEVEL_SPREAD = 10    -- how far an item's required level can sit under its item level
local OPEN_TOP = 999       -- the top of the last band, which has none

-- The item level bands the materials change at, for the tab's range.
DE.BANDS = {}
for _, band in ipairs({ { 5, 15 }, { 16, 20 }, { 21, 25 }, { 26, 30 }, { 31, 35 }, { 36, 40 }, { 41, 45 },
    { 46, 50 }, { 51, 55 }, { 56, 60 } }) do
    DE.BANDS[#DE.BANDS + 1] = { low = band[1], high = band[2], label = band[1] .. "-" .. band[2] }
end
DE.BANDS[#DE.BANDS + 1] = { low = 61, high = OPEN_TOP, label = "61+" }

-- Dusts
local STRANGE, SOUL, VISION, DREAM, ILLUSION = 10940, 11083, 11137, 11176, 16204
-- Essences, lesser and greater
local LESSER_MAGIC, GREATER_MAGIC = 10938, 10939
local LESSER_ASTRAL, GREATER_ASTRAL = 10998, 11082
local LESSER_MYSTIC, GREATER_MYSTIC = 11134, 11135
local LESSER_NETHER, GREATER_NETHER = 11174, 11175
local LESSER_ETERNAL, GREATER_ETERNAL = 16202, 16203
-- Shards, small and large
local SMALL_GLIMMERING, LARGE_GLIMMERING = 10978, 11084
local SMALL_GLOWING, LARGE_GLOWING = 11138, 11139
local SMALL_RADIANT, LARGE_RADIANT = 11177, 11178
local SMALL_BRILLIANT, LARGE_BRILLIANT = 14343, 14344
local NEXUS = 20725

local MATERIALS = {
    STRANGE, SOUL, VISION, DREAM, ILLUSION,
    LESSER_MAGIC, GREATER_MAGIC, LESSER_ASTRAL, GREATER_ASTRAL, LESSER_MYSTIC, GREATER_MYSTIC,
    LESSER_NETHER, GREATER_NETHER, LESSER_ETERNAL, GREATER_ETERNAL,
    SMALL_GLIMMERING, LARGE_GLIMMERING, SMALL_GLOWING, LARGE_GLOWING,
    SMALL_RADIANT, LARGE_RADIANT, SMALL_BRILLIANT, LARGE_BRILLIANT, NEXUS,
}

-- [essence] = { the other size, what one is worth in it }
local OTHER_SIZE = {}
for _, pair in ipairs({
    { LESSER_MAGIC, GREATER_MAGIC }, { LESSER_ASTRAL, GREATER_ASTRAL }, { LESSER_MYSTIC, GREATER_MYSTIC },
    { LESSER_NETHER, GREATER_NETHER }, { LESSER_ETERNAL, GREATER_ETERNAL },
}) do
    OTHER_SIZE[pair[1]] = { pair[2], 1 / 3 }
    OTHER_SIZE[pair[2]] = { pair[1], 3 }
end

local HIGHEST = math.huge

-- A band: the highest item level it covers, then its materials as
-- { itemID, percent chance, fewest, most, average when it isn't halfway }.
-- A band without materials can't be disenchanted.
local GREEN_ARMOR = {
    { 4 },
    { 15, { STRANGE, 80, 1, 2 }, { LESSER_MAGIC, 20, 1, 2 } },
    { 20, { STRANGE, 75, 2, 3 }, { GREATER_MAGIC, 20, 1, 2 }, { SMALL_GLIMMERING, 5, 1, 1 } },
    { 25, { STRANGE, 75, 4, 6 }, { LESSER_ASTRAL, 15, 1, 2 }, { SMALL_GLIMMERING, 10, 1, 1 } },
    { 30, { SOUL, 75, 1, 2 }, { GREATER_ASTRAL, 20, 1, 2 }, { LARGE_GLIMMERING, 5, 1, 1 } },
    { 35, { SOUL, 75, 2, 5 }, { LESSER_MYSTIC, 20, 1, 2 }, { SMALL_GLOWING, 5, 1, 1 } },
    { 40, { VISION, 75, 1, 2 }, { GREATER_MYSTIC, 20, 1, 2 }, { LARGE_GLOWING, 5, 1, 1 } },
    { 45, { VISION, 75, 2, 5 }, { LESSER_NETHER, 20, 1, 2 }, { SMALL_RADIANT, 5, 1, 1 } },
    { 50, { DREAM, 75, 1, 2 }, { GREATER_NETHER, 20, 1, 2 }, { LARGE_RADIANT, 5, 1, 1 } },
    { 55, { DREAM, 75, 2, 5 }, { LESSER_ETERNAL, 20, 1, 2 }, { SMALL_BRILLIANT, 5, 1, 1 } },
    { 60, { ILLUSION, 75, 1, 2 }, { GREATER_ETERNAL, 20, 1, 2 }, { LARGE_BRILLIANT, 5, 1, 1 } },
    { HIGHEST, { ILLUSION, 75, 2, 5 }, { GREATER_ETERNAL, 20, 2, 3 }, { LARGE_BRILLIANT, 5, 1, 1 } },
}

local GREEN_WEAPON = {
    { 4 },
    { 15, { LESSER_MAGIC, 80, 1, 2 }, { STRANGE, 20, 1, 2 } },
    { 20, { GREATER_MAGIC, 75, 1, 2 }, { STRANGE, 20, 2, 3 }, { SMALL_GLIMMERING, 5, 1, 1 } },
    { 25, { GREATER_MAGIC, 75, 1, 2 }, { STRANGE, 15, 4, 6 }, { SMALL_GLIMMERING, 10, 1, 1 } },
    { 30, { GREATER_MAGIC, 75, 1, 2 }, { SOUL, 20, 1, 2 }, { LARGE_GLIMMERING, 5, 1, 1 } },
    { 35, { LESSER_MYSTIC, 75, 1, 2 }, { SOUL, 20, 2, 5 }, { SMALL_GLOWING, 5, 1, 1 } },
    { 40, { GREATER_MYSTIC, 75, 1, 2 }, { VISION, 20, 1, 2 }, { LARGE_GLOWING, 5, 1, 1 } },
    { 45, { LESSER_NETHER, 75, 1, 2 }, { VISION, 20, 2, 5 }, { SMALL_RADIANT, 5, 1, 1 } },
    { 50, { GREATER_NETHER, 75, 1, 2 }, { DREAM, 20, 1, 2 }, { LARGE_RADIANT, 5, 1, 1 } },
    { 55, { LESSER_ETERNAL, 75, 1, 2 }, { DREAM, 22, 2, 5 }, { SMALL_BRILLIANT, 3, 1, 1 } },
    { 60, { GREATER_ETERNAL, 75, 1, 2 }, { ILLUSION, 22, 1, 2 }, { LARGE_BRILLIANT, 3, 1, 1 } },
    { HIGHEST, { GREATER_ETERNAL, 75, 2, 3 }, { ILLUSION, 22, 2, 5 }, { LARGE_BRILLIANT, 3, 1, 1 } },
}

-- Armor and weapons alike.
local BLUE = {
    { 20, { SMALL_GLIMMERING, 100, 1, 1 }, estimate = true },
    { 25, { SMALL_GLIMMERING, 100, 1, 1 } },
    { 30, { LARGE_GLIMMERING, 100, 1, 1 } },
    { 35, { SMALL_GLOWING, 100, 1, 1 } },
    { 40, { LARGE_GLOWING, 100, 1, 1 } },
    { 45, { SMALL_RADIANT, 100, 1, 1 } },
    { 50, { LARGE_RADIANT, 100, 1, 1 } },
    { 55, { SMALL_BRILLIANT, 100, 1, 1 } },
    { HIGHEST, { LARGE_BRILLIANT, 99.5, 1, 1 }, { NEXUS, 0.5, 1, 1 } },
}

local EPIC = {
    { 39 },
    { 45, { SMALL_RADIANT, 100, 2, 4 } },
    { 50, { LARGE_RADIANT, 100, 2, 4 } },
    { 55, { SMALL_BRILLIANT, 100, 2, 4 } },
    { 60, { NEXUS, 100, 1, 1 }, estimate = true },
    { HIGHEST, { NEXUS, 100, 1, 2, 5 / 3 }, estimate = true },
}

-- salvaged: the materials come at an Arcane Salvager.
local function Bands(rows, salvaged)
    local bands = {}
    for i, row in ipairs(rows) do
        local materials = { salvaged = salvaged }
        for j = 2, #row do
            local itemID, percent, min, max, avg = unpack(row[j])
            materials[#materials + 1] = { itemID = itemID, percent = percent, min = min, max = max,
                avg = avg or (min + max) / 2 }
        end
        bands[i] = { top = row[1], estimate = row.estimate or false, materials = materials }
    end
    return bands
end

local BLUE_BANDS, EPIC_BANDS = Bands(BLUE), Bands(EPIC)
-- [quality][item class] = bands
local RULES = {
    [2] = { [ARMOR] = Bands(GREEN_ARMOR), [WEAPON] = Bands(GREEN_WEAPON) },
    [3] = { [ARMOR] = BLUE_BANDS, [WEAPON] = BLUE_BANDS },
    [4] = { [ARMOR] = EPIC_BANDS, [WEAPON] = EPIC_BANDS },
}
-- Greens disenchanted at an Arcane Salvager.
local SALVAGED_GREENS = { [ARMOR] = Bands(GREEN_ARMOR, true), [WEAPON] = Bands(GREEN_WEAPON, true) }

-- Shirts and tabards don't disenchant, nor does gear that can't be worn.
local NOT_DISENCHANTED = {
    [""] = true, INVTYPE_NON_EQUIP = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BODY = true, INVTYPE_TABARD = true,
}

--------------------------------------------------------------------------------
-- What an item gives
--------------------------------------------------------------------------------

-- An item's materials, each { itemID, percent, min, max, avg }, and whether
-- they are an estimate. With the tab's Salvager ticked, a green's come at a
-- Salvager. Nil for an item that doesn't disenchant, and for one the client
-- has no info on yet. level and quality: the auction's, if known.
function DE:Results(itemID, level, quality)
    if not itemID or addon.NoDisenchant[itemID] then return nil end
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(itemID)
    quality = quality or C_Item.GetItemQualityByID(itemID)
    local byClass = quality == 2 and addon.db.disenchant.salvager and SALVAGED_GREENS or RULES[quality]
    local bands = byClass and byClass[classID]
    if not bands or not equipLoc or NOT_DISENCHANTED[equipLoc] then return nil end
    level = level or select(4, C_Item.GetItemInfo(itemID))
    if not level then return nil end
    for _, band in ipairs(bands) do
        if level <= band.top then
            if #band.materials == 0 then return nil end
            return band.materials, band.estimate or level > VANILLA_TOP
        end
    end
end

-- A material's worth before the cut: its last auction price, or for an
-- essence without one, the other size's.
function DE:MaterialPrice(itemID)
    local price = addon:GetAHPrice(itemID)
    if price then return price end
    local other = OTHER_SIZE[itemID]
    price = other and addon:GetAHPrice(other[1])
    if price then return price * other[2] end
end

-- What greens give at a Salvager against the tables, and whether that is
-- yours: your own once you disenchanted enough greens at one, else players'.
function DE:SalvagerBoost()
    local mine = addon.db.disenchanted.salvager
    if mine.count >= MEASURED_AT and mine.expected > 0 then return mine.got / mine.expected, true end
    return SALVAGER, false
end

-- What the materials bring on average after the cut, at a Salvager's boost
-- where they come at one, and whether all of them had a price; one without
-- counts nothing.
function DE:Value(materials)
    local value, complete = 0, true
    for _, material in ipairs(materials) do
        local price = self:MaterialPrice(material.itemID)
        if price then
            value = value + material.percent / 100 * material.avg * price
        else
            complete = false
        end
    end
    return value * (materials.salvaged and self:SalvagerBoost() or 1) * AFTER_CUT, complete
end

--------------------------------------------------------------------------------
-- The scan and its deals
--------------------------------------------------------------------------------

-- [itemID] = { key, price, quality, level, asked }: each item's cheapest
-- offer in the last scan; asked: the client was asked for its item level
local candidates = {}
local checked = {}    -- [itemID] = { row = its cheapest auction you can buy, nil for none, rows = all of
                      -- them, cheapest first, at = GetTime() }
local asking = {}     -- [itemID] = a token while a search of it waits for its answer
local buying          -- { itemID, auctionID }: the purchase Buy sent
local dirty = false   -- the deals need working out again

local QUALITIES = { 2, 3, 4 } -- browsed in turn: green, blue and epic
local QUALITY_WORDS = { [2] = "green", [3] = "blue", [4] = "epic" }
local QUALITY_FILTERS = { [2] = "UncommonQuality", [3] = "RareQuality", [4] = "EpicQuality" }
local FILTER_IDS = { UncommonQuality = 8, RareQuality = 9, EpicQuality = 10 } -- where the client lacks the enum

-- One quality of armor and weapons whose required level fits the item
-- levels asked for. Items without a required level are missed unless the
-- range starts low.
local function Query(settings, quality)
    local classes = {}
    if settings.armor then classes[#classes + 1] = { classID = ARMOR } end
    if settings.weapons then classes[#classes + 1] = { classID = WEAPON } end
    local name = QUALITY_FILTERS[quality]
    return {
        searchString = "",
        minLevel = math.max(settings.minItemLevel - LEVEL_SPREAD, 0),
        maxLevel = settings.maxItemLevel < OPEN_TOP and settings.maxItemLevel or 0, -- 0: no top
        filters = { Enum.AuctionHouseFilter and Enum.AuctionHouseFilter[name] or FILTER_IDS[name] },
        itemClassFilters = classes,
    }
end

-- "green armor and weapons", for the status line.
local function What(settings, quality)
    local kinds = not settings.weapons and "armor" or not settings.armor and "weapons" or "armor and weapons"
    return QUALITY_WORDS[quality] .. " " .. kinds
end

-- The auction's item level, as the house gives it. Where it doesn't, the
-- client's, which is asked for once and read when it arrives.
local function Level(itemID, candidate)
    if candidate.level then return candidate.level end
    local level = candidate.key.itemLevel
    if level and level > 0 then
        candidate.level = level
    elseif not candidate.asked then
        candidate.asked = true
        candidate.level = select(4, C_Item.GetItemInfo(itemID))
        if not candidate.level then C_Item.RequestLoadItemDataByID(itemID) end
    end
    return candidate.level
end

-- An item of the scan as a deal, or nil when it isn't one.
local function MakeDeal(itemID, candidate, settings)
    local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
    if not ((classID == ARMOR and settings.armor) or (classID == WEAPON and settings.weapons)) then return nil end
    local level = Level(itemID, candidate)
    if not level or level < settings.minItemLevel or level > settings.maxItemLevel then return nil end
    local materials, estimate = DE:Results(itemID, level, candidate.quality)
    if not materials then return nil end
    local check = checked[itemID]
    if check and not check.row then return nil end
    local value, complete = DE:Value(materials)
    local price = check and check.row.buyout or candidate.price
    local profit = value - price
    if profit < settings.minProfit then return nil end
    -- Once searched, how many of its auctions leave the minimum profit.
    local count
    if check then
        count = 0
        for _, row in ipairs(check.rows) do
            if value - row.buyout >= settings.minProfit then count = count + 1 end
        end
    end
    return {
        itemID = itemID, key = candidate.key, level = level, quality = candidate.quality, price = price,
        value = value, profit = profit, complete = complete, estimate = estimate, row = check and check.row,
        count = count,
    }
end

local function ByProfit(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.itemID < b.itemID
end

-- Marks a search of the item as waiting; one nobody answers can go again.
local function Ask(itemID)
    local token = {}
    asking[itemID] = token
    C_Timer.After(ANSWER_TIMEOUT, function()
        if asking[itemID] == token then
            asking[itemID] = nil
            dirty = true
            addon:Refresh()
        end
    end)
end

local function Evaluate()
    dirty = false
    local settings = addon.db.disenchant
    local deals = {}
    for itemID, candidate in pairs(candidates) do
        local deal = MakeDeal(itemID, candidate, settings)
        if deal then deals[#deals + 1] = deal end
    end
    table.sort(deals, ByProfit)
    DE.deals = deals
    DE:SearchTop()
end

-- The deals, most profit first, worked out again when something changed.
function DE:Deals()
    if dirty then Evaluate() end
    return self.deals
end

-- Searches the top deals without a fresh answer, with the exact item the
-- browse found, so Buy has an auction to buy. Not while a scan runs.
function DE:SearchTop()
    if not Auction.isOpen or self.scanning then return end
    local now = GetTime()
    for i = 1, math.min(SEARCH_AHEAD, #self.deals) do
        local deal = self.deals[i]
        local check = checked[deal.itemID]
        if not asking[deal.itemID] and not (check and now - check.at < CHECK_KEEP) then
            Ask(deal.itemID)
            Auction:Search(deal.itemID, true, true, deal.key)
        end
    end
end

-- A filter changed: the last scan's items are sorted again.
function DE:Set(key, value)
    addon.db.disenchant[key] = value
    dirty = true
    addon:Refresh()
end

-- A browse result of the scan. An item comes once per variant, like each
-- "of the Bear"; the cheapest counts.
local function Take(result, quality)
    local key, price = result.itemKey, result.minPrice
    local itemID = key and key.itemID
    local old = itemID and candidates[itemID]
    if itemID and price and price > 0 and not (old and old.price <= price) then
        candidates[itemID] = { key = key, price = price, quality = quality }
        dirty = true
    end
end

local function Scanned(complete)
    DE.scanning = false
    DE.scannedAt, DE.cutShort = time(), not complete
    addon:SetStatus(complete and ("Scanned %d items"):format(DE.scanned)
        or ("The scan was cut short: %d items"):format(DE.scanned))
    dirty = true
    addon:Refresh()
end

-- From the Scan button: the materials' prices first, then a browse for
-- each quality, each a step of the progress the tab shows. The last scan's
-- deals go at once; this one's come in with its pages.
function DE:Scan()
    local settings = addon.db.disenchant
    if self.scanning or not Auction.isOpen or not (settings.armor or settings.weapons) then return end
    self.scanning = true
    wipe(candidates)
    wipe(checked)
    wipe(asking)
    self.scanned = 0
    dirty = true
    local progress = { step = 1, steps = #QUALITIES + 1, what = "material prices" }
    self.progress = progress
    Auction:ScanPrices(MATERIALS, "disenchanting materials")
    local complete, left = true, #QUALITIES
    for i, quality in ipairs(QUALITIES) do
        local what, taken = QUALITY_WORDS[quality] .. "s", 0
        -- The browse's results since the last call.
        local function TakeNew(results)
            for j = taken + 1, #results do Take(results[j], quality) end
            DE.scanned = DE.scanned + #results - taken
            taken = #results
        end
        Auction:Browse(Query(settings, quality), What(settings, quality), {
            onProgress = function(results)
                TakeNew(results)
                progress.step, progress.what, progress.items = i + 1, what, #results
                addon:Refresh()
            end,
            onDone = function(results, done)
                TakeNew(results)
                complete = complete and done
                left = left - 1
                if left == 0 then Scanned(complete) end
            end,
        })
    end
    addon:Refresh()
end

-- Buys the deal's cheapest auction, one item.
function DE:Buy(deal)
    if not deal.row then return end
    buying = { itemID = deal.itemID, auctionID = deal.row.auctionID }
    Auction:BuyAuction(deal.itemID, deal.row)
end

-- A search's answer: the item's auctions you can buy, cheapest first.
addon:Listen("RESULTS", function(itemID)
    if not candidates[itemID] then return end
    asking[itemID] = nil
    local result = Auction.results[itemID]
    local rows = {}
    for _, r in ipairs(result and result.rows or {}) do
        if r.auctionID and not r.own then rows[#rows + 1] = r end
    end
    checked[itemID] = { row = rows[1], rows = rows, at = GetTime() }
    dirty = true
end)

-- After a purchase, Auction.lua searches the item again; its deal waits for
-- that answer.
addon:On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    if not (buying and buying.auctionID == auctionID) then return end
    local itemID = buying.itemID
    buying = nil
    checked[itemID] = nil
    Ask(itemID)
    dirty = true
end)

-- A refused purchase: the auction may be gone, so the item is searched again.
addon:On("AUCTION_HOUSE_SHOW_ERROR", function()
    if not buying then return end
    local itemID = buying.itemID
    buying = nil
    checked[itemID] = nil
    local candidate = candidates[itemID]
    if candidate then
        Ask(itemID)
        Auction:Search(itemID, true, true, candidate.key)
    end
    dirty = true
    addon:Refresh()
end)

-- An item level the client was asked for is read as it arrives, while the
-- item is surely in its cache.
local function InfoArrived(itemID)
    local candidate = itemID and candidates[itemID]
    if not (candidate and candidate.asked and not candidate.level) then return end
    candidate.level = select(4, C_Item.GetItemInfo(itemID))
    if candidate.level then dirty = true end
end
addon:On("GET_ITEM_INFO_RECEIVED", InfoArrived)
addon:On("ITEM_DATA_LOAD_RESULT", InfoArrived)

-- Item levels saved before the range went by bands snap to the bands around them.
addon:Listen("DB_READY", function()
    local settings = addon.db.disenchant
    for _, band in ipairs(DE.BANDS) do
        if settings.minItemLevel <= band.high then
            settings.minItemLevel = band.low
            break
        end
    end
    for _, band in ipairs(DE.BANDS) do
        if settings.maxItemLevel <= band.high then
            settings.maxItemLevel = band.high
            break
        end
    end
end)

-- The top deals are searched again at the house; away from it, auctions go stale.
addon:Listen("AH_SHOW", function() dirty = true end)
addon:Listen("AH_HIDE", function()
    -- A scan cut off by the house closing keeps the items it read.
    if DE.scanning then DE.scannedAt, DE.cutShort = time(), true end
    DE.scanning = false
    wipe(checked)
    wipe(asking)
    buying = nil
    dirty = true
end)

-- The tooltips name the materials.
addon:Listen("LOGIN", function()
    for _, itemID in ipairs(MATERIALS) do C_Item.RequestLoadItemDataByID(itemID) end
end)

--------------------------------------------------------------------------------
-- Your disenchants
--------------------------------------------------------------------------------

-- Every green you disenchant counts its materials against what the tables
-- expect, at a Salvager or elsewhere. The game doesn't say which item a
-- disenchant was cast on: it is the bag item the cast names, or else the one
-- it locks as it starts. A cast counts as at a Salvager when its buff was on
-- you as the cast went or as the loot came, and not at all when the game
-- wouldn't say. Loot with anything but disenchanting materials isn't a
-- disenchant's.

local DISENCHANT = 13262 -- the spell
local BOOSTED = 1283701  -- Boosted Disenchanting, the buff near an Arcane Salvager
local LOOT_WAIT = 10     -- seconds after the cast that its loot can come

local IS_MATERIAL = {}
for _, itemID in ipairs(MATERIALS) do IS_MATERIAL[itemID] = true end

local cast -- { castGUID, itemID, boosted, at = GetTime() }: the disenchant on its way

-- Whether you have Boosted Disenchanting; nil when the game won't say.
local function Boosted()
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, BOOSTED)
    if ok then return aura ~= nil end
end

addon:On("UNIT_SPELLCAST_SENT", function(unit, target, castGUID, spellID)
    if unit ~= "player" or spellID ~= DISENCHANT then return end
    cast = { castGUID = castGUID, itemID = addon:ItemNamedInBags(target), boosted = Boosted(), at = GetTime() }
end)

addon:On("UNIT_SPELLCAST_START", function(unit, castGUID)
    if unit == "player" and cast and cast.castGUID == castGUID and not cast.itemID then
        cast.itemID = addon:LockedInBags()
    end
end)

-- A cast that failed or was stopped gives nothing.
local function Stopped(unit, castGUID)
    if unit == "player" and cast and cast.castGUID == castGUID then cast = nil end
end
addon:On("UNIT_SPELLCAST_FAILED", Stopped)
addon:On("UNIT_SPELLCAST_FAILED_QUIET", Stopped)
addon:On("UNIT_SPELLCAST_INTERRUPTED", Stopped)

-- How many materials the loot holds; nil when it holds anything else, or
-- nothing yet.
local function LootUnits()
    local units = 0
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if not (itemID and IS_MATERIAL[itemID]) then return nil end
        local _, _, quantity = GetLootSlotInfo(slot)
        units = units + math.max(quantity or 1, 1)
    end
    if units > 0 then return units end
end

-- The disenchant's loot: a green counts what it gave.
local function LootCame()
    if not cast then return end
    if GetTime() - cast.at > LOOT_WAIT then
        cast = nil
        return
    end
    local units = LootUnits()
    if not units then return end
    local itemID, before, after = cast.itemID, cast.boosted, Boosted()
    cast = nil
    local boosted
    if before or after then
        boosted = true
    elseif before == false and after == false then
        boosted = false
    else
        return
    end
    if not itemID or C_Item.GetItemQualityByID(itemID) ~= 2 then return end
    local materials = DE:Results(itemID, nil, 2)
    if not materials then return end
    local expected = 0
    for _, material in ipairs(materials) do expected = expected + material.percent / 100 * material.avg end
    local mine = addon.db.disenchanted[boosted and "salvager" or "plain"]
    mine.count, mine.got, mine.expected = mine.count + 1, mine.got + units, mine.expected + expected
    -- The deals again: with enough of them, the Salvager's boost is yours.
    dirty = true
    addon:Refresh()
end
addon:On("LOOT_READY", LootCame)
addon:On("LOOT_OPENED", LootCame)
