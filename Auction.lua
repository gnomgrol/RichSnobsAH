-- The auction house on Forever's retail-style C_AuctionHouse: price checks,
-- searches, buying, your purchases, posting and your own auctions.
--
-- Searches wait their turn on the throttled channel. Buying, posting and
-- canceling need a hardware event, so they run straight from a click and
-- never from the queue. Search results are shared with Blizzard's frame.

local _, addon = ...

local Auction = {
    isOpen = false,
    -- [itemID] = { commodity = bool, rows = { row, ... }, partial, at = GetTime() }
    results = {},
    owned = nil,     -- your auctions from the last query
    ownedMin = {},   -- [itemID] = cheapest unit price, by the last undercut check or a newer search
    ownedCheckedAt = nil, -- GetTime() when the last undercut check began
}
addon.Auction = Auction

local BATCH_SIZE = 50       -- item keys per SearchForItemKeys
local ANSWER_TIMEOUT = 10   -- seconds before an unanswered request is given up
local PENDING_TIMEOUT = 15  -- seconds before a buy, post or cancel stops blocking
local MAX_ROWS = 50         -- search rows kept per item

local SORT_PRICE = Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
local PRICE_SORT = { { sortOrder = SORT_PRICE, reverseSort = false } }

--------------------------------------------------------------------------------
-- The throttled channel
--------------------------------------------------------------------------------

local queue = {}
local retryQueued = false

local function SystemReady()
    return C_AuctionHouse.IsThrottledMessageSystemReady()
end

local function Pump()
    while queue[1] and Auction.isOpen and SystemReady() do
        table.remove(queue, 1)()
    end
    -- The ready event can be missed, so a waiting queue also checks itself.
    if queue[1] and Auction.isOpen and not retryQueued then
        retryQueued = true
        C_Timer.After(0.5, function()
            retryQueued = false
            Pump()
        end)
    end
end

local function Send(fn)
    if not Auction.isOpen then return false end
    queue[#queue + 1] = fn
    Pump()
    return true
end

-- Whether a click action can go now.
function Auction:CanAct()
    return self.isOpen and SystemReady()
end

-- A buy, post or cancel waiting for its answer. It stops blocking the
-- buttons after a while even if the answer never comes.
local function SetPending(kind, value)
    Auction[kind] = value
    C_Timer.After(PENDING_TIMEOUT, function()
        if Auction[kind] == value then
            Auction[kind] = nil
            addon:SetStatus("No answer from the auction house; check the Auctions tab")
            addon:Refresh()
        end
    end)
end

function Auction:Busy()
    local quote = self.quote
    return self.buying or self.posting or self.canceling
        or (quote and (quote.pending or quote.confirming)) and true or false
end

--------------------------------------------------------------------------------
-- Price checks: many items per request
--------------------------------------------------------------------------------

local scan
local waitingScans = {}

-- Prices items in batched browse requests. Vendor-bought items are skipped
-- unless options.includeVendor. options.onBatch(found, batch) gets each
-- answer as [itemID] = cheapest unit price, with the item IDs asked for;
-- options.onDone runs at the end. A quiet check, the snipe rounds', says
-- nothing on the status line and leaves the price history alone.
function Auction:ScanPrices(itemIDs, label, options)
    options = options or {}
    if not self.isOpen then
        if not options.quiet then addon:SetStatus("Open the auction house to check prices") end
        return false
    end

    local seen, ids = {}, {}
    for _, itemID in ipairs(itemIDs) do
        if not seen[itemID] and (options.includeVendor or not addon.db.vendor[itemID]) then
            seen[itemID] = true
            ids[#ids + 1] = itemID
        end
    end
    if #ids == 0 then
        if not options.quiet then addon:SetStatus(("Nothing to check in %s"):format(label)) end
        if options.onDone then options.onDone() end
        return false
    end

    local batches = {}
    for i = 1, #ids, BATCH_SIZE do
        batches[#batches + 1] = { unpack(ids, i, math.min(i + BATCH_SIZE - 1, #ids)) }
    end
    local job = { batches = batches, index = 0, label = label, options = options }
    -- One check at a time: a second one waits instead of cutting the first short.
    if scan then
        waitingScans[#waitingScans + 1] = job
        return true
    end
    scan = job
    self:NextBatch()
    return true
end

-- A check you started, running or waiting; the snipe rounds don't count.
function Auction:IsScanning()
    if scan and not scan.options.quiet then return true end
    for _, job in ipairs(waitingScans) do
        if not job.options.quiet then return true end
    end
    return false
end

function Auction:NextBatch()
    local current = scan
    if not current then return end
    if current.query then return self:NextPage() end
    current.index = current.index + 1
    local batch = current.batches[current.index]
    local quiet = current.options.quiet

    if not batch then
        if not quiet then addon:SetStatus(("Prices checked: %s"):format(current.label)) end
        if current.options.onDone then current.options.onDone() end
        scan = table.remove(waitingScans, 1)
        if scan then self:NextBatch() end
        addon:Refresh()
        return
    end

    if not quiet then
        addon:SetStatus(("Checking prices: %s"):format(current.label), current.index - 1, #current.batches)
    end
    Send(function()
        if scan ~= current then return end
        local keys = {}
        for _, itemID in ipairs(batch) do
            local ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
            if ok and key then keys[#keys + 1] = key end
        end
        current.waiting = batch
        if not pcall(C_AuctionHouse.SearchForItemKeys, keys, {}) then
            current.waiting = nil
            C_Timer.After(0, function() Auction:NextBatch() end)
            return
        end
        -- A batch nobody answers doesn't stall the rest.
        C_Timer.After(ANSWER_TIMEOUT, function()
            if scan == current and current.waiting == batch then
                current.waiting = nil
                Auction:NextBatch()
            end
        end)
    end)
end

-- The cheapest unit price per item in browse results, and how many are up.
-- An item can have several results (one per item key).
local function Cheapest(results)
    local found, counts = {}, {}
    for _, result in ipairs(results or {}) do
        local itemID = result.itemKey and result.itemKey.itemID
        local price = result.minPrice
        if itemID and price and price > 0 then
            if not found[itemID] or price < found[itemID] then found[itemID] = price end
            counts[itemID] = (counts[itemID] or 0) + (result.totalQuantity or 0)
        end
    end
    return found, counts
end

-- Every browse answer, ours or one from Blizzard's frame, updates prices.
-- counts go to the history for a full answer only, since a later page
-- holds the rest.
local function Record(found, counts, noHistory)
    for itemID, price in pairs(found) do
        local count = counts and counts[itemID] > 0 and counts[itemID] or nil
        addon:SetPrice(itemID, price, count, noHistory)
    end
end

-- A browse from Blizzard's frame can land while a batch waits. An answer
-- counts as ours when it is empty or prices something in the batch.
local function AnswersBatch(found, batch)
    if next(found) == nil then return true end
    for _, itemID in ipairs(batch) do
        if found[itemID] then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Browsing: every page of one query
--------------------------------------------------------------------------------

-- A browse job's end. Its prices go in from all its pages at once, as an
-- item's variants, like each "of the Bear", can sit on different pages.
-- Then the next job starts.
local function EndBrowse(current, complete)
    current.waiting = nil
    local found, counts = Cheapest(current.results)
    Record(found, complete and counts or nil, current.options.quiet)
    if not current.options.quiet then
        addon:SetStatus((complete and "Scanned %s: %d items" or "The scan of %s was cut short: %d items")
            :format(current.label, #current.results))
    end
    if current.options.onDone then current.options.onDone(current.results, complete) end
    scan = table.remove(waitingScans, 1)
    if scan then Auction:NextBatch() end
    addon:Refresh()
end

-- Browses the house with query, as SendBrowseQuery takes it, page after
-- page until the house has sent them all. options.onDone(results, complete)
-- gets every result; complete is false when a page never came.
-- options.onProgress(results) gets the results so far, as it starts and
-- after each page. It waits its turn with the price checks, as one of them
-- would.
function Auction:Browse(query, label, options)
    options = options or {}
    if not self.isOpen then return false end
    query.sorts = query.sorts or PRICE_SORT
    local job = { query = query, label = label, options = options, results = {}, pages = 0 }
    if scan then
        waitingScans[#waitingScans + 1] = job
        return true
    end
    scan = job
    self:NextBatch()
    return true
end

-- A browse job's next request: its query, then a page more after each
-- answer until the house has sent them all.
function Auction:NextPage()
    local current = scan
    if not (current and current.query) then return end
    if current.options.onProgress then current.options.onProgress(current.results) end
    if current.pages > 0 and C_AuctionHouse.HasFullBrowseResults() then return EndBrowse(current, true) end
    if not current.options.quiet then
        addon:SetStatus(#current.results > 0 and ("Scanning %s: %d items"):format(current.label, #current.results)
            or ("Scanning %s..."):format(current.label))
    end
    Send(function()
        if scan ~= current then return end
        local token = {}
        current.waiting = token
        local ok
        if current.pages == 0 then
            ok = pcall(C_AuctionHouse.SendBrowseQuery, current.query)
        else
            ok = pcall(C_AuctionHouse.RequestMoreBrowseResults)
        end
        if not ok then return EndBrowse(current, false) end
        C_Timer.After(ANSWER_TIMEOUT, function()
            if scan == current and current.waiting == token then EndBrowse(current, false) end
        end)
    end)
end

addon:On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    local results = C_AuctionHouse.GetBrowseResults()
    local current = scan
    if current and current.query then
        if current.waiting and current.pages == 0 then
            -- A browse job's first page.
            current.waiting, current.pages, current.results = nil, 1, results
            Auction:NextPage()
            return
        elseif current.pages > 0 then
            -- Another browse took the house's list of answers from the job.
            EndBrowse(current, false)
        end
    end
    local found, counts = Cheapest(results)
    local batch = current and current.waiting
    local ours = batch and AnswersBatch(found, batch)
    Record(found, counts, ours and current.options.quiet)
    if ours then
        current.waiting = nil
        if current.options.onBatch then current.options.onBatch(found, batch) end
        Auction:NextBatch()
    end
end)

addon:On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(added)
    local current = scan
    if current and current.query and current.waiting and current.pages > 0 then
        -- A page more for a browse job.
        current.waiting, current.pages = nil, current.pages + 1
        for _, result in ipairs(added or {}) do current.results[#current.results + 1] = result end
        Auction:NextPage()
        return
    end
    local found = Cheapest(added)
    Record(found)
end)

-- A browse the house couldn't answer ends with what it has.
addon:On("AUCTION_HOUSE_BROWSE_FAILURE", function()
    local current = scan
    if current and current.query and current.waiting then EndBrowse(current, false) end
end)

--------------------------------------------------------------------------------
-- Full Auction House Scan: the whole house in one snapshot
--------------------------------------------------------------------------------

local FULL_SCAN_COOLDOWN = 15 * 60  -- the house allows one snapshot per 15 minutes
local FULL_SCAN_TIMEOUT = 60        -- seconds to wait for the snapshot to arrive
local READ_PER_FRAME = 1000         -- rows read per frame, so the game doesn't freeze
local SAVE_PER_FRAME = 500          -- items whose price and history are saved per frame

-- The scan waiting, being read or being saved: { total, index,
-- cheapest = { [itemID] = unit }, counts = { [itemID] = n }, ids, saved, now }
local full

-- Seconds until the house allows the next snapshot.
function Auction:FullScanWait()
    local last = addon.db.lastFullScan
    if not last then return 0 end
    return math.max(0, last + FULL_SCAN_COOLDOWN - time())
end

-- From a click. The countdown starts at the click whether or not an answer
-- comes: during the house's own cooldown ReplicateItems does nothing and
-- says nothing, and that cooldown ends no later than ours.
function Auction:FullScan()
    if not self.isOpen then return end
    local wait = self:FullScanWait()
    if wait > 0 then
        addon:SetStatus(("The next full scan is allowed in %d min"):format(math.ceil(wait / 60)))
        return
    end
    if not pcall(C_AuctionHouse.ReplicateItems) then
        addon:SetStatus("The game refused the full scan")
        return
    end

    local current = { cheapest = {}, counts = {} }
    full = current
    addon.db.lastFullScan = time()
    addon:SetStatus("Downloading the whole auction house...")
    -- A late answer is still read; this only says it is late.
    C_Timer.After(FULL_SCAN_TIMEOUT, function()
        if full == current and not current.total then
            addon:SetStatus("No full scan came back yet; try again when the countdown ends")
        end
    end)
    addon:Refresh()
end

-- Saves the snapshot's prices a slice per frame: each item's history takes
-- a moment, and thousands of them in one frame would freeze the game. The
-- snapshot is in hand by now, so saving goes on if the auction house closes.
local function SaveSnapshot(current)
    local ids = current.ids
    local last = math.min(current.saved + SAVE_PER_FRAME, #ids)
    for i = current.saved + 1, last do
        local itemID = ids[i]
        local price = math.floor(current.cheapest[itemID] + 0.5)
        addon.db.prices[itemID] = { p = price, t = current.now }
        addon:RecordHistory(itemID, price, current.counts[itemID])
    end
    current.saved = last

    if last < #ids then
        addon:SetStatus("Saving prices", last, #ids)
        C_Timer.After(0, function() SaveSnapshot(current) end)
        return
    end
    if full == current then full = nil end
    addon:SetStatus(("Scanned %s auctions: prices for %s items"):format(
        BreakUpLargeNumbers(current.total), BreakUpLargeNumbers(#ids)))
    addon:Refresh()
end

-- Snapshot rows are 0-based and carry the stack's whole buyout, so the
-- price per unit is buyout / count. Bid-only auctions have no buyout.
local function ReadSnapshot(current)
    if full ~= current then return end
    local cheapest, counts = current.cheapest, current.counts
    local last = math.min(current.index + READ_PER_FRAME, current.total) - 1
    for i = current.index, last do
        local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
        if itemID and buyout and buyout > 0 and count and count > 0 then
            local unit = buyout / count
            if not cheapest[itemID] or unit < cheapest[itemID] then cheapest[itemID] = unit end
            counts[itemID] = (counts[itemID] or 0) + count
        end
    end
    current.index = last + 1

    if current.index < current.total then
        addon:SetStatus("Reading the whole auction house", current.index, current.total)
        C_Timer.After(0, function() ReadSnapshot(current) end)
        return
    end

    local ids = {}
    for itemID in pairs(cheapest) do ids[#ids + 1] = itemID end
    current.ids, current.saved, current.now = ids, 0, time()
    SaveSnapshot(current)
end

-- Only a snapshot this addon asked for is read. Another addon's full scan
-- restarts the house's cooldown, so the countdown restarts with it.
addon:On("REPLICATE_ITEM_LIST_UPDATE", function()
    local current = full
    if not current then
        addon.db.lastFullScan = time()
        addon:Refresh()
        return
    end
    if current.total then return end
    current.total = C_AuctionHouse.GetNumReplicateItems() or 0
    current.index = 0
    ReadSnapshot(current)
end)

--------------------------------------------------------------------------------
-- One item's auctions
--------------------------------------------------------------------------------

local quietSearches = {} -- [itemID] = true while a quiet search of it waits for its answer

-- A background search, as the undercut check's, leaves "Searching..." to
-- the search a pane waits on. A quiet one, a snipe's, also leaves the price
-- history alone. itemKey: the exact item, with the item level and variant a
-- browse found it with; without one, the item ID's.
function Auction:Search(itemID, background, quiet, itemKey)
    if not itemID or not self.isOpen then return false end
    if quiet then quietSearches[itemID] = true end
    if not background then
        if self.searching == itemID then return true end
        self.searching = itemID
        addon:Refresh()
        C_Timer.After(ANSWER_TIMEOUT, function()
            if Auction.searching == itemID then
                Auction.searching = nil
                addon:Refresh()
            end
        end)
    end
    return Send(function()
        local ok, key = true, itemKey
        if not key then ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID) end
        if not (ok and key and pcall(C_AuctionHouse.SendSearchQuery, key, PRICE_SORT, true)) then
            if Auction.searching == itemID then Auction.searching = nil end
            quietSearches[itemID] = nil
            addon:Refresh()
        end
    end)
end

-- partial: the house holds more offers than the rows kept. key: the item
-- key an item search answered for, which a search after a purchase reuses.
local function Finish(itemID, commodity, rows, partial, key)
    addon:LearnCommodity(itemID, commodity)
    Auction.results[itemID] = { commodity = commodity, rows = rows, partial = partial, at = GetTime(), key = key }
    local quiet = quietSearches[itemID]
    quietSearches[itemID] = nil
    if rows[1] then addon:SetPrice(itemID, rows[1].unit, nil, quiet) end
    -- A newer cheapest for an item of yours that was checked, so the
    -- undercut and the count of cheaper offers come from the same answer.
    if rows[1] and Auction.ownedMin[itemID] then Auction.ownedMin[itemID] = rows[1].unit end
    if Auction.searching == itemID then Auction.searching = nil end
    addon:Fire("RESULTS", itemID)
    addon:Refresh()
end

addon:On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    local rows, total = {}, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
    for i = 1, math.min(total, MAX_ROWS) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice then
            rows[#rows + 1] = {
                unit = r.unitPrice,
                quantity = r.quantity or 0,
                own = (r.numOwnerItems or 0) > 0,
            }
        end
    end
    local complete = C_AuctionHouse.HasFullCommoditySearchResults
    Finish(itemID, true, rows, total > MAX_ROWS or (complete ~= nil and not complete(itemID)))
end)

addon:On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local itemID = itemKey and itemKey.itemID
    if not itemID then return end
    local rows, total = {}, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    for i = 1, math.min(total, MAX_ROWS) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        -- Bid-only auctions can't be bought out, so they aren't offers here.
        -- A row gathers identical one-item auctions: quantity is how many,
        -- buyoutAmount what one costs, and a purchase buys one.
        if r and r.buyoutAmount and r.buyoutAmount > 0 then
            rows[#rows + 1] = {
                unit = r.buyoutAmount,
                buyout = r.buyoutAmount,
                quantity = math.max(1, r.quantity or 1),
                auctionID = r.auctionID,
                own = r.containsOwnerItem and true or false,
                timeLeft = r.timeLeftSeconds, -- your own auctions only
                band = r.timeLeft,            -- Enum.AuctionHouseTimeLeftBand
            }
        end
    end
    table.sort(rows, function(a, b) return a.unit < b.unit end)
    local complete = C_AuctionHouse.HasFullItemSearchResults
    Finish(itemID, false, rows, total > MAX_ROWS or (complete ~= nil and not complete(itemKey)), itemKey)
end)

-- The price to post at to undercut an offer: one step under it, or its own
-- price when the offer is yours. Commodities step by a copper unless the
-- client says it takes none; item auctions take whole silver.
function Auction:PriceUnder(row, commodity)
    if row.own then return row.unit end
    local copper = commodity and not (C_AuctionHouse.SupportsCopperValues
        and C_AuctionHouse.SupportsCopperValues() == false)
    if copper then return math.max(1, row.unit - 1) end
    return math.max(100, math.floor((row.unit - 1) / 100) * 100)
end

-- The price to post at: under the cheapest offer.
function Auction:SuggestPrice(itemID, commodity)
    local result = self.results[itemID]
    local first = result and result.rows[1]
    return first and self:PriceUnder(first, commodity) or nil
end

--------------------------------------------------------------------------------
-- Buying
--------------------------------------------------------------------------------

-- A quote still waiting for its price or its purchase stops blocking the
-- buttons after a while, like the other pending actions.
local function ExpireQuote(quote)
    C_Timer.After(PENDING_TIMEOUT, function()
        if Auction.quote == quote and (quote.pending or quote.confirming) then
            Auction.quote = nil
            addon:SetStatus("No answer from the auction house; check your bags before buying again")
            addon:Refresh()
        end
    end)
end

-- Commodities are bought in two clicks: the first asks for a price for the
-- whole quantity, the second confirms it.
function Auction:StartBuy(itemID, quantity)
    self:CancelQuote()
    self.quote = { itemID = itemID, quantity = quantity, pending = true }
    if pcall(C_AuctionHouse.StartCommoditiesPurchase, itemID, quantity) then
        ExpireQuote(self.quote)
        addon:SetStatus(("Getting a price for %d..."):format(quantity))
    else
        self.quote = nil
        addon:SetStatus("The game refused the purchase")
    end
    addon:Refresh()
end

function Auction:CancelQuote()
    if not self.quote then return end
    self.quote = nil
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
end

addon:On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
    local quote = Auction.quote
    if not quote then return end
    quote.pending = nil
    quote.unit, quote.total = unitPrice, totalPrice
    local seconds = C_AuctionHouse.GetQuoteDurationRemaining and C_AuctionHouse.GetQuoteDurationRemaining()
    quote.expires = GetTime() + ((seconds and seconds > 0) and seconds or 30)
    addon:SetStatus(("%d for %s, %s each. Click Confirm to buy."):format(
        quote.quantity, addon.Money(totalPrice), addon.Money(unitPrice, true)))
    addon:Refresh()
    -- The Snipe tab confirms its own quotes within their max.
    addon:Fire("QUOTE", quote)
end)

addon:On("COMMODITY_PRICE_UNAVAILABLE", function()
    if not Auction.quote then return end
    Auction.quote = nil
    addon:SetStatus("That many aren't for sale at one price any more. Search again.")
    addon:Refresh()
end)

function Auction:ConfirmBuy()
    local quote = self.quote
    if not quote or not quote.total then return end
    if GetTime() > quote.expires then
        self:CancelQuote()
        addon:SetStatus("The price quote ran out. Click Buy again.")
    elseif GetMoney() < quote.total then
        addon:SetStatus("Not enough gold for " .. addon.Money(quote.total))
    else
        quote.confirming = true
        if pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, quote.itemID, quote.quantity) then
            ExpireQuote(quote)
        else
            self.quote = nil
            addon:SetStatus("The game refused the purchase")
        end
    end
    addon:Refresh()
end

addon:On("COMMODITY_PURCHASE_SUCCEEDED", function()
    local quote = Auction.quote
    Auction.quote = nil
    if quote then
        addon:SetStatus(("Bought %d %s for %s"):format(quote.quantity,
            addon:ItemName(quote.itemID) or "", addon.Money(quote.total or 0)))
        Auction:Search(quote.itemID)
    end
    addon:Refresh()
end)

addon:On("COMMODITY_PURCHASE_FAILED", function()
    Auction.quote = nil
    addon:SetStatus("The purchase failed")
    addon:Refresh()
end)

-- Item auctions are bought one at a time by auction ID.
function Auction:BuyAuction(itemID, row)
    if GetMoney() < row.buyout then
        addon:SetStatus("Not enough gold for " .. addon.Money(row.buyout))
        return
    end
    local result = self.results[itemID]
    SetPending("buying", { itemID = itemID, auctionID = row.auctionID, buyout = row.buyout, key = result and result.key })
    if not pcall(C_AuctionHouse.PlaceBid, row.auctionID, row.buyout) then
        self.buying = nil
        addon:SetStatus("The game refused the purchase")
    end
    addon:Refresh()
end

addon:On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    local buying = Auction.buying
    if not buying or buying.auctionID ~= auctionID then return end
    Auction.buying = nil
    addon:SetStatus(("Bought %s for %s"):format(addon:ItemName(buying.itemID) or "", addon.Money(buying.buyout)))
    Auction:Search(buying.itemID, nil, nil, buying.key)
end)

--------------------------------------------------------------------------------
-- Purchases
--------------------------------------------------------------------------------

-- Every buyout, from this addon or Blizzard's frame, is saved for good, for
-- all your characters. The game's calls are hooked, since its events name
-- neither the item nor the price. A bid isn't a purchase yet, and one that
-- wins later isn't counted.
local commodityBuy  -- the commodity purchase under way: { itemID, count, price, sent }
local bought = {}   -- [auctionID] = an item buyout sent: { itemID, count, price }
local purchaseStats -- [itemID] = { units, total, low, high }, built when first asked for

local function Hook(name, fn)
    if C_AuctionHouse[name] then hooksecurefunc(C_AuctionHouse, name, fn) end
end

local function SavePurchase(purchase)
    table.insert(addon.db.purchases, {
        t = time(),
        itemID = purchase.itemID,
        count = purchase.count,
        price = purchase.price, -- the whole purchase
        char = addon:CharKey(),
    })
    purchaseStats = nil
    addon:Refresh()
end

-- A commodity purchase names the item and quantity as it starts, takes its
-- price from the quote, and goes through with the confirm. A new quote
-- replaces the price.
Hook("StartCommoditiesPurchase", function(itemID, quantity)
    commodityBuy = { itemID = itemID, count = quantity }
end)

addon:On("COMMODITY_PRICE_UPDATED", function(_, totalPrice)
    if commodityBuy then commodityBuy.price = totalPrice end
end)

Hook("ConfirmCommoditiesPurchase", function(itemID, quantity)
    if commodityBuy and commodityBuy.itemID == itemID and commodityBuy.count == quantity then
        commodityBuy.sent = true
    end
end)

addon:On("COMMODITY_PURCHASE_SUCCEEDED", function()
    if commodityBuy and commodityBuy.sent and commodityBuy.price then SavePurchase(commodityBuy) end
    commodityBuy = nil
end)

addon:On("COMMODITY_PURCHASE_FAILED", function()
    if commodityBuy then commodityBuy.sent = nil end
end)

-- An item buyout names only the auction, so its item and price are looked
-- up: in every result of the item searches either frame made, however far
-- down the list; then in the rows this addon keeps, which may outlast the
-- game's; then in your bids, which the Bids tab buys out; then in the game's
-- own lookup, where the client has one. A bid of at least the buyout buys
-- one item.
local searchedKeys = {} -- item keys searched since the house opened, latest last

local function RememberKey(itemKey)
    if not (itemKey and itemKey.itemID) then return end
    for i, key in ipairs(searchedKeys) do
        if key.itemID == itemKey.itemID and key.itemLevel == itemKey.itemLevel
            and key.itemSuffix == itemKey.itemSuffix and key.battlePetSpeciesID == itemKey.battlePetSpeciesID then
            table.remove(searchedKeys, i)
            break
        end
    end
    searchedKeys[#searchedKeys + 1] = itemKey
end

addon:On("ITEM_SEARCH_RESULTS_UPDATED", RememberKey)
addon:On("ITEM_SEARCH_RESULTS_ADDED", RememberKey)
addon:On("AUCTION_HOUSE_CLOSED", function() wipe(searchedKeys) end)

-- The auction's item ID and buyout, or nil if it can't be found.
local function FindAuction(auctionID)
    for i = #searchedKeys, 1, -1 do
        local key = searchedKeys[i]
        for j = 1, C_AuctionHouse.GetNumItemSearchResults(key) or 0 do
            local result = C_AuctionHouse.GetItemSearchResultInfo(key, j)
            if result and result.auctionID == auctionID then return key.itemID, result.buyoutAmount end
        end
    end
    for itemID, result in pairs(Auction.results) do
        for _, row in ipairs(result.rows) do
            if row.auctionID == auctionID then return itemID, row.buyout end
        end
    end
    for i = 1, C_AuctionHouse.GetNumBids and C_AuctionHouse.GetNumBids() or 0 do
        local bid = C_AuctionHouse.GetBidInfo(i)
        if bid and bid.auctionID == auctionID and bid.itemKey then return bid.itemKey.itemID, bid.buyoutAmount end
    end
    if C_AuctionHouse.GetAuctionInfoByID then
        local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, auctionID)
        if ok and info and info.itemKey then return info.itemKey.itemID, info.buyoutAmount end
    end
end

Hook("PlaceBid", function(auctionID, bidAmount)
    local itemID, buyout = FindAuction(auctionID)
    if itemID and buyout and buyout > 0 and bidAmount and bidAmount >= buyout then
        bought[auctionID] = { itemID = itemID, count = 1, price = buyout }
    end
end)

addon:On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    local purchase = bought[auctionID]
    if not purchase then return end
    bought[auctionID] = nil
    SavePurchase(purchase)
end)

-- An item's purchases: units bought, what they cost in all, and the lowest
-- and highest price each. Nil if you never bought it.
function addon:PurchaseStats(itemID)
    if not purchaseStats then
        purchaseStats = {}
        for _, purchase in ipairs(self.db.purchases) do
            local item = purchaseStats[purchase.itemID]
            if not item then
                item = { units = 0, total = 0 }
                purchaseStats[purchase.itemID] = item
            end
            local each = purchase.price / purchase.count
            item.units = item.units + purchase.count
            item.total = item.total + purchase.price
            item.low = math.min(item.low or each, each)
            item.high = math.max(item.high or each, each)
        end
    end
    return purchaseStats[itemID]
end

--------------------------------------------------------------------------------
-- Posting
--------------------------------------------------------------------------------

-- Buyout only, no starting bid, as Blizzard's own sell tab does in buyout
-- mode. PostItem silently drops a price with copper in it, so it is rounded
-- down to whole silver first.
function Auction:Post(itemID, location, commodity, quantity, unit, duration)
    -- What it costs, worked out while the item is still in the bags.
    local deposit = self:Deposit(itemID, location, commodity, duration, quantity)
    local ok, err
    if commodity then
        ok, err = pcall(C_AuctionHouse.PostCommodity, location, duration, quantity, unit)
    else
        unit = math.floor(unit / 100) * 100
        ok, err = pcall(C_AuctionHouse.PostItem, location, duration, quantity, nil, unit)
    end
    -- The return value isn't a success flag: PostCommodity returns false on
    -- listings that do go up. Success is AUCTION_HOUSE_AUCTION_CREATED.
    if not ok then
        addon:SetStatus("The game refused the listing: " .. tostring(err):gsub("^.-:%d+: ", ""))
        return false
    end
    SetPending("posting", { itemID = itemID, quantity = quantity, unit = unit, deposit = deposit })
    addon:SetStatus("Posting...")
    addon:Refresh()
    return true
end

addon:On("AUCTION_HOUSE_AUCTION_CREATED", function()
    local posting = Auction.posting
    if not posting then return end
    Auction.posting = nil
    addon:SetStatus(("Posted %d %s at %s each"):format(posting.quantity,
        addon:ItemName(posting.itemID) or "", addon.Money(posting.unit, true)))
    addon:Fire("POSTED", posting)
    Auction:Search(posting.itemID)
    Auction:QueryOwned()
end)

function Auction:Deposit(itemID, location, commodity, duration, quantity)
    local ok, deposit
    if commodity then
        ok, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, duration, quantity)
    elseif location then
        ok, deposit = pcall(C_AuctionHouse.CalculateItemDeposit, location, duration, quantity)
    end
    if ok then return deposit end
end

--------------------------------------------------------------------------------
-- Your auctions
--------------------------------------------------------------------------------

local ownedQueued, checkAfterQuery = false, false

-- With check, a price check of everything you have up follows, for the
-- undercut view.
function Auction:QueryOwned(check)
    if check then checkAfterQuery = true end
    if ownedQueued then return end
    ownedQueued = true
    local sent = Send(function()
        ownedQueued = false
        pcall(C_AuctionHouse.QueryOwnedAuctions, {})
    end)
    if not sent then ownedQueued = false end
end

-- A commodity's buyoutAmount is per unit and an item's is for the whole
-- auction, but a sold auction's is always the whole sale, the amount
-- Blizzard's frame shows as incoming. Worked out again when the client
-- learns an item key, since a guess from the stack size can be wrong.
local function PriceOwned()
    for _, auction in ipairs(Auction.owned or {}) do
        local perUnit = false
        if not auction.sold then
            perUnit = addon:IsCommodity(auction.itemID, nil, auction.itemKey)
            if perUnit == nil then perUnit = addon:GuessCommodity(auction.itemID) end
        end
        local buyout, quantity = auction.buyout, auction.quantity
        auction.unit = buyout and (perUnit and buyout or buyout / quantity)
        auction.total = buyout and (perUnit and buyout * quantity or buyout)
    end
end

addon:On("ITEM_KEY_ITEM_INFO_RECEIVED", function()
    if not Auction.owned then return end
    PriceOwned()
    addon:Refresh()
end)

-- How far under one of your auctions the cheapest offer is, each; nil when
-- it isn't undercut or wasn't checked. Half a copper of slack for the
-- per-unit price of multi-item auctions.
function Auction:UndercutBy(auction)
    local cheapest = self.ownedMin[auction.itemID]
    if auction.sold or not (cheapest and auction.unit) or cheapest >= auction.unit - 0.5 then return nil end
    return auction.unit - cheapest
end

-- How many are up for less than one of your auctions: auctions of an item,
-- units of a commodity, from a search made since the last undercut check;
-- nil before that search is in. more: the rows kept all cost less, and the
-- house holds more.
function Auction:CheaperThan(auction)
    local result = self.results[auction.itemID]
    if not (result and auction.unit and self.ownedCheckedAt and result.at >= self.ownedCheckedAt) then return nil end
    local count = 0
    for _, row in ipairs(result.rows) do
        if row.unit >= auction.unit - 0.5 then return count, false end
        count = count + row.quantity
    end
    return count, result.partial
end

-- After the check, each undercut item gets a search of its own, for how
-- many offers cost less.
local function SearchUndercut()
    local searched = {}
    for _, auction in ipairs(Auction.owned or {}) do
        local itemID = auction.itemID
        if not searched[itemID] and Auction:UndercutBy(auction) then
            searched[itemID] = true
            Auction:Search(itemID, true)
        end
    end
end

addon:On("OWNED_AUCTIONS_UPDATED", function()
    local rows, listed, active = {}, {}, {}
    for i = 1, C_AuctionHouse.GetNumOwnedAuctions() or 0 do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        local itemID = info and info.itemKey and info.itemKey.itemID
        if itemID then
            -- Status is nil on some clients; that counts as active.
            local sold = Enum.AuctionStatus and info.status == Enum.AuctionStatus.Sold or false
            local quantity = math.max(1, info.quantity or 1)
            rows[#rows + 1] = {
                auctionID = info.auctionID,
                itemID = itemID,
                itemKey = info.itemKey,
                quantity = quantity,
                -- An item sold to a bid may carry only the bid.
                buyout = sold and (info.buyoutAmount or info.bidAmount) or info.buyoutAmount,
                sold = sold,
                timeLeft = info.timeLeftSeconds,
                -- A sold auction's time left runs until its gold is mailed.
                arrives = sold and info.timeLeftSeconds and time() + info.timeLeftSeconds or nil,
            }
            if not sold then
                listed[itemID] = (listed[itemID] or 0) + quantity
                active[#active + 1] = itemID
            end
        end
    end
    Auction.owned = rows
    PriceOwned()
    addon.db.listed[addon:CharKey()] = { t = time(), items = listed }
    addon:Fire("OWNED")
    addon:Refresh()

    if checkAfterQuery then
        checkAfterQuery = false
        wipe(Auction.ownedMin)
        Auction.ownedCheckedAt = GetTime()
        Auction:ScanPrices(active, "your auctions", {
            includeVendor = true,
            onBatch = function(found)
                for itemID, price in pairs(found) do Auction.ownedMin[itemID] = price end
            end,
            onDone = SearchUndercut,
        })
    end
end)

function Auction:Cancel(auctionID)
    local ok, err = pcall(C_AuctionHouse.CancelAuction, auctionID)
    if not ok then
        addon:SetStatus("The game refused the cancel: " .. tostring(err):gsub("^.-:%d+: ", ""))
        return
    end
    SetPending("canceling", auctionID)
    addon:SetStatus("Canceling...")
    addon:Refresh()
end

addon:On("AUCTION_CANCELED", function()
    local auctionID = Auction.canceling
    if not auctionID then return end
    Auction.canceling = nil
    -- It leaves the list at once, so a quick next click can't pick it again
    -- before your auctions are in.
    for i, auction in ipairs(Auction.owned or {}) do
        if auction.auctionID == auctionID then
            table.remove(Auction.owned, i)
            break
        end
    end
    addon:SetStatus("Auction canceled; it comes back by mail")
    addon:Refresh()
    Auction:QueryOwned()
end)

--------------------------------------------------------------------------------
-- Opening, closing and errors
--------------------------------------------------------------------------------

addon:On("AUCTION_HOUSE_SHOW", function()
    Auction.isOpen = true
    addon:Fire("AH_SHOW")
    -- Keeps the Listed counts current.
    Auction:QueryOwned()
end)

addon:On("AUCTION_HOUSE_CLOSED", function()
    Auction.isOpen = false
    wipe(queue)
    scan = nil
    wipe(waitingScans)
    full = nil
    ownedQueued, checkAfterQuery = false, false
    Auction:CancelQuote()
    Auction.buying, Auction.posting, Auction.canceling, Auction.searching = nil, nil, nil, nil
    -- Offers and auction IDs go stale away from the auction house.
    wipe(Auction.results)
    wipe(quietSearches)
    wipe(Auction.ownedMin)
    Auction.owned = nil
    addon:SetStatus("")
    addon:Fire("AH_HIDE")
    addon:Refresh()
end)

addon:On("AUCTION_HOUSE_SHOW_ERROR", function()
    local quote = Auction.quote
    local quoteWaiting = quote and (quote.pending or quote.confirming)
    if not (Auction.buying or Auction.posting or Auction.canceling or quoteWaiting) then return end
    Auction.buying, Auction.posting, Auction.canceling = nil, nil, nil
    if quoteWaiting then Auction.quote = nil end
    addon:SetStatus("The auction house refused that")
    addon:Refresh()
end)

addon:On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    Pump()
    addon:Refresh()
end)

addon:On("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", function() addon:Refresh() end)

-- A dropped request gets no answer; don't wait for it. A browse job waits
-- for its timeout instead, as the request dropped may be another one, and
-- ending it would cut a long scan short.
addon:On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    Auction.searching = nil
    if Auction.quote and Auction.quote.pending then Auction.quote = nil end
    if scan and scan.waiting and not scan.query then
        scan.waiting = nil
        Auction:NextBatch()
    end
    addon:Refresh()
end)
