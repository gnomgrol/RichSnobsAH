-- Disenchanting: what an armor or weapon item breaks into and what that is
-- worth, the DE buy tab's scan for auctions worth buying to disenchant, and
-- the Disenchant tab's list of what in your bags disenchants, with the
-- results of your disenchants.
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
-- Disenchanting buff raises the chance of bonus materials; Blizzard gives no
-- rate. Players' data from over 7,000 disenchants, as the SalvageCalc addon
-- has it: a green's dust or essence comes with a 50% chance of one more, so
-- half a one more on average, while its shards and blues come as without.
-- With the Salvager ticked, greens are valued so. Every green you
-- disenchant counts its materials against the tables, at a Salvager and
-- elsewhere, for you to compare.
--
-- The scan checks the materials' prices, then reads every page of a browse
-- for each quality up to the best you pick, green, blue and epic armor and
-- weapons. The house filters by required level only, so each asks for
-- required levels from ten under the range; the items are then judged by
-- the item level the house gives with each. It keeps the items whose
-- cheapest offer leaves at least the minimum profit, a page at a time, so
-- the deals fill in while it runs. Once it is done, the top deals are
-- searched, and the one you chose, so Buy buys an auction that is there;
-- one gone or dearer drops out. Searches during the scan would hold up its
-- pages, so they wait for its end, or for Pause: that holds the scan after
-- the page on its way, and the deals so far are searched and can be bought
-- until Resume.
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
    paused = false, -- the scan holds, and the deals are searched meanwhile
    -- While scanning: { step, steps, what, items }. Step 1 checks the
    -- materials' prices, each step after it browses a quality, and items
    -- counts what that browse has read so far.
    progress = nil,
    -- { itemID, key, level, price, value, profit, complete, estimate, row, count },
    -- most profit first; row: the cheapest auction a search found; count: how
    -- many of the auctions it found leave the minimum profit
    deals = {},
    chosen = nil,    -- the item ID of the deal you chose for Buy over the top one
    scannedAt = nil, -- time() when the last scan ended
    scanned = 0,     -- the items the scan read, so far while it runs
    cutShort = false, -- a page of the last scan never came
}
addon.Disenchant = DE

local ARMOR, WEAPON = 4, 2 -- item class IDs
local AFTER_CUT = 0.95     -- what a sale leaves after the house's cut
DE.AFTER_CUT = AFTER_CUT
local VANILLA_TOP = 92     -- vanilla's highest item level; Forever's items above it are estimates
local SALVAGER_BONUS = 0.5 -- the dust or essence more a green gives at an Arcane Salvager, on average
DE.SALVAGER_BONUS = SALVAGER_BONUS
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

-- A Salvager gives no more of these.
local SHARDS = {}
for _, itemID in ipairs({ SMALL_GLIMMERING, LARGE_GLIMMERING, SMALL_GLOWING, LARGE_GLOWING, SMALL_RADIANT,
    LARGE_RADIANT, SMALL_BRILLIANT, LARGE_BRILLIANT, NEXUS }) do
    SHARDS[itemID] = true
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
-- they are an estimate. With the Salvager ticked, a green's come at a
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

-- What the materials bring on average after the cut, with a Salvager's
-- dust or essence more where they come at one, and whether all of them had
-- a price; one without counts nothing.
function DE:Value(materials)
    local value, complete = 0, true
    local bonus = materials.salvaged and SALVAGER_BONUS or 0
    for _, material in ipairs(materials) do
        local price = self:MaterialPrice(material.itemID)
        if price then
            local avg = material.avg + (SHARDS[material.itemID] and 0 or bonus)
            value = value + material.percent / 100 * avg * price
        else
            complete = false
        end
    end
    return value * AFTER_CUT, complete
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

local QUALITIES = { 2, 3, 4 } -- browsed in turn up to the best you pick: green, blue and epic
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
    if candidate.quality > settings.maxQuality then return nil end
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
    -- Once searched, how many of its auctions leave the minimum profit. A
    -- row holds identical auctions, quantity of them, and a purchase buys one.
    local count
    if check then
        count = 0
        for _, row in ipairs(check.rows) do
            if value - row.buyout >= settings.minProfit then count = count + row.quantity end
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

-- The deal you chose for Buy, while it is one; one gone lets go.
function DE:Chosen()
    if not self.chosen then return nil end
    for _, deal in ipairs(self.deals) do
        if deal.itemID == self.chosen then return deal end
    end
    self.chosen = nil
end

-- Chooses a deal for Buy over the top one, or lets go of the one chosen.
function DE:Choose(itemID)
    self.chosen = self.chosen ~= itemID and itemID or nil
    self:SearchTop()
    addon:Refresh()
end

-- Searches the deal you chose and the top deals without a fresh answer,
-- with the exact item the browse found, so Buy has an auction to buy. Not
-- while a scan runs, unless it is paused.
function DE:SearchTop()
    if not Auction.isOpen or (self.scanning and not self.paused) then return end
    local now = GetTime()
    local deals = { self:Chosen() }
    for i = 1, math.min(SEARCH_AHEAD, #self.deals) do deals[#deals + 1] = self.deals[i] end
    for _, deal in ipairs(deals) do
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

-- A scan that ends while paused lets go of the pause, which would hold
-- whatever waits behind it.
local function Scanned(complete)
    DE.scanning = false
    if DE.paused then
        DE.paused = false
        Auction:ResumeScans()
    end
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
    local qualities = {}
    for _, quality in ipairs(QUALITIES) do
        if quality <= settings.maxQuality then qualities[#qualities + 1] = quality end
    end
    local progress = { step = 1, steps = #qualities + 1, what = "material prices" }
    self.progress = progress
    Auction:ScanPrices(MATERIALS, "disenchanting materials")
    local complete, left = true, #qualities
    for i, quality in ipairs(qualities) do
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

-- Holds the scan once the page on its way is in, and searches the deals so
-- far, so Buy can buy them before the scan ends.
function DE:Pause()
    if not self.scanning or self.paused then return end
    self.paused = true
    Auction:PauseScans()
    addon:SetStatus("Scan paused")
    dirty = true
    addon:Refresh()
end

-- Goes on with the scan where it stopped.
function DE:Resume()
    if not self.paused then return end
    self.paused = false
    Auction:ResumeScans()
    addon:Refresh()
end

-- Buys the deal's cheapest auction, one item, when the house can take it: a
-- click on Yes may come after it closed, or another purchase went out.
function DE:Buy(deal)
    if not deal.row or not Auction:CanAct() or Auction:Busy() then return end
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
    DE.scanning, DE.paused = false, false
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

-- Every disenchant counts the materials it gave towards your results, and
-- what you paid for its item at the auction house, if you bought it there.
-- A green also counts its materials against what the tables expect, at a
-- Salvager or elsewhere. The game doesn't say which item a disenchant was
-- cast on: it is the bag item the cast names, else the item the Disenchant
-- tab's button aimed at, else the one it locks as it starts. A cast counts as
-- at a Salvager when its buff was on you as the cast went or as the loot
-- came, and not at all when the game wouldn't say. Loot with anything but
-- disenchanting materials isn't a disenchant's.

local DISENCHANT = 13262 -- the spell
DE.SPELL = DISENCHANT
local BOOSTED = 1283701  -- Boosted Disenchanting, the buff near an Arcane Salvager
local LOOT_WAIT = 10     -- seconds after the cast that its loot can come
local AIM_WAIT = 1       -- seconds after the button's click that its cast can come
local LAST_KEPT = 10     -- disenchants your results keep one by one

local IS_MATERIAL = {}
for _, itemID in ipairs(MATERIALS) do IS_MATERIAL[itemID] = true end

local cast  -- { castGUID, itemID, boosted, at = GetTime() }: the disenchant on its way
local aimed -- { itemID, at = GetTime() }: the item the button's click cast at

-- Whether you have Boosted Disenchanting; nil when the game won't say.
function DE:Boosted()
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, BOOSTED)
    if ok then return aura ~= nil end
end

-- The Disenchant tab's button, as its click casts at a bag item.
function DE:Aim(item)
    aimed = { itemID = item.itemID, at = GetTime() }
end

-- Whether a disenchant is on its way, from its cast to its loot, and its item.
function DE:Disenchanting()
    if cast and GetTime() - cast.at <= LOOT_WAIT then return true, cast.itemID end
    return false
end

addon:On("UNIT_SPELLCAST_SENT", function(unit, target, castGUID, spellID)
    if unit ~= "player" or spellID ~= DISENCHANT then return end
    local itemID = addon:ItemNamedInBags(target)
    if not itemID and aimed and GetTime() - aimed.at <= AIM_WAIT then itemID = aimed.itemID end
    aimed = nil
    cast = { castGUID = castGUID, itemID = itemID, boosted = DE:Boosted(), at = GetTime() }
    addon:Refresh()
end)

addon:On("UNIT_SPELLCAST_START", function(unit, castGUID)
    if unit == "player" and cast and cast.castGUID == castGUID and not cast.itemID then
        cast.itemID = addon:LockedInBags()
    end
end)

-- A cast that failed or was stopped gives nothing.
local function Stopped(unit, castGUID)
    if unit == "player" and cast and cast.castGUID == castGUID then
        cast = nil
        addon:Refresh()
    end
end
addon:On("UNIT_SPELLCAST_FAILED", Stopped)
addon:On("UNIT_SPELLCAST_FAILED_QUIET", Stopped)
addon:On("UNIT_SPELLCAST_INTERRUPTED", Stopped)

-- The loot's materials, [itemID] = how many, and how many in all; nil when it
-- holds anything else, or nothing yet.
local function LootMaterials()
    local got, units = {}, 0
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if not (itemID and IS_MATERIAL[itemID]) then return nil end
        local _, _, quantity = GetLootSlotInfo(slot)
        quantity = math.max(quantity or 1, 1)
        got[itemID] = (got[itemID] or 0) + quantity
        units = units + quantity
    end
    if units > 0 then return got, units end
end

-- What one of the item cost you at the auction house: the latest buyout of
-- it no disenchant counted yet, which this one now does. Any of your
-- characters' buyouts count, as gear bought on one is often disenchanted on
-- another.
local function Paid(itemID)
    local purchases = addon.db.purchases
    for i = #purchases, 1, -1 do
        local purchase = purchases[i]
        if purchase.itemID == itemID and not purchase.disenchanted then
            purchase.disenchanted = true
            return purchase.price / purchase.count
        end
    end
end

-- A disenchant joins your results.
local function Record(itemID, got)
    local results = addon.db.disenchantResults
    results.since = results.since or time()
    results.count = results.count + 1
    for material, n in pairs(got) do results.materials[material] = (results.materials[material] or 0) + n end
    local paid = itemID and Paid(itemID)
    if paid then results.paid, results.paidFor = results.paid + paid, results.paidFor + 1 end
    table.insert(results.last, 1, { t = time(), itemID = itemID, materials = got })
    results.last[LAST_KEPT + 1] = nil
end

-- A green's materials against what the tables expect, at a Salvager or not.
local function Measure(itemID, units, boosted)
    if not itemID or C_Item.GetItemQualityByID(itemID) ~= 2 then return end
    local materials = DE:Results(itemID, nil, 2)
    if not materials then return end
    local expected = 0
    for _, material in ipairs(materials) do expected = expected + material.percent / 100 * material.avg end
    local mine = addon.db.disenchanted[boosted and "salvager" or "plain"]
    mine.count, mine.got, mine.expected = mine.count + 1, mine.got + units, mine.expected + expected
end

-- The disenchant's loot.
local function LootCame()
    if not cast then return end
    if GetTime() - cast.at > LOOT_WAIT then
        cast = nil
        return
    end
    local got, units = LootMaterials()
    if not got then return end
    local itemID, before, after = cast.itemID, cast.boosted, DE:Boosted()
    cast = nil
    Record(itemID, got)
    if before or after then
        Measure(itemID, units, true)
    elseif before == false and after == false then
        Measure(itemID, units, false)
    end
    addon:Refresh()
end
addon:On("LOOT_READY", LootCame)
addon:On("LOOT_OPENED", LootCame)

-- What your results' materials bring at their last prices after the cut; one
-- without a price counts nothing.
function DE:ResultsWorth()
    local worth = 0
    for itemID, n in pairs(addon.db.disenchantResults.materials) do
        worth = worth + n * (self:MaterialPrice(itemID) or 0)
    end
    return worth * AFTER_CUT
end

-- Your results start over.
function DE:ResetResults()
    addon.db.disenchantResults = { since = time(), count = 0, materials = {}, paid = 0, paidFor = 0, last = {} }
    addon:Refresh()
end

--------------------------------------------------------------------------------
-- Your bags
--------------------------------------------------------------------------------

-- The Disenchant tab lists what in your bags disenchants, in bag order, and
-- its button disenchants them an item a click. It works through the items
-- not kept: an item is kept when you ignored it, when it's in an equipment
-- set, when it's an epic, and, with Keep what sells for more ticked, when it
-- sells for more than its materials bring. It sells for the better of a
-- vendor's price and, unless it's bound to you, its last auction price after
-- the cut. An item with a material unpriced isn't kept for that.

DE.picked = nil -- { bag, slot, itemID }: the item you picked for the button

-- Whether the bag slot's item is in an equipment set; false when the game won't say.
local function InSet(bag, slot)
    local ok, inSet = pcall(C_Container.GetContainerItemEquipmentSetInfo, bag, slot)
    return ok and inSet == true
end

-- The better of a vendor's price and, unless the item is bound, its last
-- auction price after the cut.
local function Sells(itemID, vendor, bound)
    local auction = not bound and addon:GetAHPrice(itemID)
    return math.max(vendor or 0, auction and auction * AFTER_CUT or 0)
end

-- Each item in the bags that disenchants, in bag order: { bag, slot, itemID,
-- quality, level, value, complete, estimate, sells, locked, kept }; kept:
-- why Disenchant next leaves it out.
function DE:BagItems()
    local settings = addon.db.bagDisenchant
    local items = {}
    addon:EachBagItem(function(bag, slot, info)
        local itemID = info.itemID
        local quality = info.quality or C_Item.GetItemQualityByID(itemID)
        local _, _, _, level, _, _, _, _, _, _, vendor = C_Item.GetItemInfo(itemID)
        local materials, estimate = self:Results(itemID, level, quality)
        if not materials then return end
        local value, complete = self:Value(materials)
        local sells = Sells(itemID, vendor, info.isBound)
        local kept
        if settings.ignored[itemID] then
            kept = "ignored"
        elseif InSet(bag, slot) then
            kept = "in a set"
        elseif quality == 4 then
            kept = "epic"
        elseif settings.keepSellers and complete and sells > value then
            kept = "sells for more"
        end
        items[#items + 1] = { bag = bag, slot = slot, itemID = itemID, quality = quality, level = level,
            value = value, complete = complete, estimate = estimate, sells = sells, locked = info.isLocked,
            kept = kept }
    end)
    return items
end

-- The item the button disenchants: the one you picked while it's still in
-- its slot, else the first not kept nor locked.
function DE:BagTarget(items)
    local picked = self.picked
    if picked then
        for _, item in ipairs(items) do
            if item.bag == picked.bag and item.slot == picked.slot and item.itemID == picked.itemID then return item end
        end
        self.picked = nil
    end
    for _, item in ipairs(items) do
        if not item.kept and not item.locked then return item end
    end
end

-- Picks an item for the button, or lets go of the one picked.
function DE:Pick(item)
    local picked = self.picked
    if picked and item and picked.bag == item.bag and picked.slot == item.slot and picked.itemID == item.itemID then
        item = nil
    end
    self.picked = item and { bag = item.bag, slot = item.slot, itemID = item.itemID } or nil
    addon:Refresh()
end

-- An ignored item stays out of Disenchant next for good, on all your characters.
function DE:SetIgnored(itemID, ignored)
    addon.db.bagDisenchant.ignored[itemID] = ignored and true or nil
    addon:Refresh()
end

function DE:SetKeepSellers(on)
    addon.db.bagDisenchant.keepSellers = on
    addon:Refresh()
end

-- Whether this character knows Disenchant; true when the game won't say.
function DE:Known()
    for _, check in ipairs({ C_SpellBook and C_SpellBook.IsSpellInSpellBook or false, IsPlayerSpell or false }) do
        if check then
            local ok, known = pcall(check, DISENCHANT)
            if ok and type(known) == "boolean" then return known end
        end
    end
    return true
end
