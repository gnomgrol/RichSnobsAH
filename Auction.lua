-- The auction house on Forever's retail-style C_AuctionHouse: price checks,
-- searches, buying, posting and your own auctions.
--
-- Searches wait their turn on the throttled channel. Buying, posting and
-- canceling need a hardware event, so they run straight from a click and
-- never from the queue. Search results are shared with Blizzard's frame.

local _, addon = ...

local Auction = {
    isOpen = false,
    results = {},    -- [itemID] = { commodity = bool, rows = { row, ... } }
    owned = nil,     -- your auctions from the last query
    ownedMin = {},   -- [itemID] = cheapest unit price in the last undercut check
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
            addon:SetStatus("No answer from the auction house; check My auctions")
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
-- unless options.includeVendor. options.onBatch(found) gets each answer as
-- [itemID] = cheapest unit price; options.onDone runs at the end.
function Auction:ScanPrices(itemIDs, label, options)
    options = options or {}
    if not self.isOpen then
        addon:SetStatus("Open the auction house to check prices")
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
        addon:SetStatus(("Nothing to check in %s"):format(label))
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

function Auction:IsScanning()
    return scan ~= nil
end

function Auction:NextBatch()
    local current = scan
    if not current then return end
    current.index = current.index + 1
    local batch = current.batches[current.index]

    if not batch then
        addon:SetStatus(("Prices checked: %s"):format(current.label))
        if current.options.onDone then current.options.onDone() end
        scan = table.remove(waitingScans, 1)
        if scan then self:NextBatch() end
        addon:Refresh()
        return
    end

    addon:SetStatus(("Checking prices: %s"):format(current.label), current.index - 1, #current.batches)
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

-- Every browse answer, ours or one from Blizzard's frame, updates prices.
local function RecordBrowse(results)
    local found = {}
    for _, result in ipairs(results or {}) do
        local itemID = result.itemKey and result.itemKey.itemID
        local price = result.minPrice
        if itemID and price and price > 0 and (not found[itemID] or price < found[itemID]) then
            found[itemID] = price
        end
    end
    for itemID, price in pairs(found) do addon:SetPrice(itemID, price) end
    return found
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

addon:On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    local found = RecordBrowse(C_AuctionHouse.GetBrowseResults())
    local current = scan
    if current and current.waiting and AnswersBatch(found, current.waiting) then
        current.waiting = nil
        if current.options.onBatch then current.options.onBatch(found) end
        Auction:NextBatch()
    end
end)

addon:On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(added)
    RecordBrowse(added)
end)

--------------------------------------------------------------------------------
-- Scan everything: the whole house in one snapshot
--------------------------------------------------------------------------------

local FULL_SCAN_COOLDOWN = 15 * 60  -- the house allows one snapshot per 15 minutes
local FULL_SCAN_TIMEOUT = 60        -- seconds to wait for the snapshot to arrive
local READ_PER_FRAME = 1000         -- rows read per frame, so the game doesn't freeze

local full -- the scan waiting or being read: { total, index, cheapest = { [itemID] = unit } }

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

    local current = { cheapest = {} }
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

-- Snapshot rows are 0-based and carry the stack's whole buyout, so the
-- price per unit is buyout / count. Bid-only auctions have no buyout.
local function ReadSnapshot(current)
    if full ~= current then return end
    local cheapest = current.cheapest
    local last = math.min(current.index + READ_PER_FRAME, current.total) - 1
    for i = current.index, last do
        local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
        if itemID and buyout and buyout > 0 and count and count > 0 then
            local unit = buyout / count
            if not cheapest[itemID] or unit < cheapest[itemID] then cheapest[itemID] = unit end
        end
    end
    current.index = last + 1

    if current.index < current.total then
        addon:SetStatus("Reading the whole auction house", current.index, current.total)
        C_Timer.After(0, function() ReadSnapshot(current) end)
        return
    end

    local now, items = time(), 0
    for itemID, unit in pairs(cheapest) do
        addon.db.prices[itemID] = { p = math.floor(unit + 0.5), t = now }
        items = items + 1
    end
    full = nil
    addon:SetStatus(("Scanned %s auctions: prices for %s items"):format(
        BreakUpLargeNumbers(current.total), BreakUpLargeNumbers(items)))
    addon:Refresh()
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

function Auction:Search(itemID)
    if not itemID or not self.isOpen then return false end
    if self.searching == itemID then return true end
    self.searching = itemID
    addon:Refresh()
    C_Timer.After(ANSWER_TIMEOUT, function()
        if Auction.searching == itemID then
            Auction.searching = nil
            addon:Refresh()
        end
    end)
    return Send(function()
        local ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
        if not (ok and key and pcall(C_AuctionHouse.SendSearchQuery, key, PRICE_SORT, true)) then
            if Auction.searching == itemID then Auction.searching = nil end
            addon:Refresh()
        end
    end)
end

local function Finish(itemID, commodity, rows)
    addon:LearnCommodity(itemID, commodity)
    Auction.results[itemID] = { commodity = commodity, rows = rows }
    if rows[1] then addon:SetPrice(itemID, rows[1].unit) end
    if Auction.searching == itemID then Auction.searching = nil end
    addon:Fire("RESULTS", itemID)
    addon:Refresh()
end

addon:On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    local rows = {}
    for i = 1, math.min(C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0, MAX_ROWS) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice then
            rows[#rows + 1] = {
                unit = r.unitPrice,
                quantity = r.quantity or 0,
                own = (r.numOwnerItems or 0) > 0,
            }
        end
    end
    Finish(itemID, true, rows)
end)

addon:On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local itemID = itemKey and itemKey.itemID
    if not itemID then return end
    local rows = {}
    for i = 1, math.min(C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0, MAX_ROWS) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        -- Bid-only auctions can't be bought out, so they aren't offers here.
        if r and r.buyoutAmount and r.buyoutAmount > 0 then
            local quantity = math.max(1, r.quantity or 1)
            rows[#rows + 1] = {
                unit = r.buyoutAmount / quantity,
                buyout = r.buyoutAmount,
                quantity = quantity,
                auctionID = r.auctionID,
                own = r.containsOwnerItem and true or false,
                timeLeft = r.timeLeftSeconds,
            }
        end
    end
    table.sort(rows, function(a, b) return a.unit < b.unit end)
    Finish(itemID, false, rows)
end)

-- The price to post at: one step under the cheapest seller, or your own
-- price when you are the cheapest already. Commodities step by a copper
-- unless the client says it takes none; item auctions take whole silver.
function Auction:SuggestPrice(itemID, commodity)
    local result = self.results[itemID]
    local first = result and result.rows[1]
    if not first then return nil end
    if first.own then return first.unit end
    local copper = commodity and not (C_AuctionHouse.SupportsCopperValues
        and C_AuctionHouse.SupportsCopperValues() == false)
    if copper then return math.max(1, first.unit - 1) end
    return math.max(100, math.floor((first.unit - 1) / 100) * 100)
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
    SetPending("buying", { itemID = itemID, auctionID = row.auctionID, buyout = row.buyout })
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
    Auction:Search(buying.itemID)
end)

--------------------------------------------------------------------------------
-- Posting
--------------------------------------------------------------------------------

-- Buyout only, no starting bid, as Blizzard's own sell tab does in buyout
-- mode. PostItem silently drops a price with copper in it, so it is rounded
-- down to whole silver first.
function Auction:Post(itemID, location, commodity, quantity, unit, duration)
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
    SetPending("posting", { itemID = itemID, quantity = quantity, unit = unit })
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
        Auction:ScanPrices(active, "your auctions", {
            includeVendor = true,
            onBatch = function(found)
                for itemID, price in pairs(found) do Auction.ownedMin[itemID] = price end
            end,
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
    if not Auction.canceling then return end
    Auction.canceling = nil
    addon:SetStatus("Auction canceled; it comes back by mail")
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

-- A dropped request gets no answer; don't wait for it.
addon:On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    Auction.searching = nil
    if Auction.quote and Auction.quote.pending then Auction.quote = nil end
    if scan and scan.waiting then
        scan.waiting = nil
        Auction:NextBatch()
    end
    addon:Refresh()
end)
