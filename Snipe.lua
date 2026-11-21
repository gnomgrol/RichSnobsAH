-- Sniping: watches the items on lists ticked Snipe for offers far under
-- their usual price. While watching, and while the RichSnobs tab shows at
-- the auction house, a quiet price check of them runs every couple of
-- seconds. An item whose cheapest offer is at or under its max is searched,
-- its cheap offers become a deal, and a sound plays. A Buy click on a deal
-- asks for a price quote, which is confirmed at once when it stays within
-- the max.

local _, addon = ...
local Auction = addon.Auction

local Snipe = {
    watching = false,
    -- [itemID] = { itemID, commodity, count, total, unit = the cheapest each,
    -- row = an item's cheapest auction, profit = after the cut at the usual price }
    deals = {},
    checkedAt = nil, -- GetTime() when the last round ended
}
addon.Snipe = Snipe

local ROUND_PAUSE = 2  -- seconds from one round's end to the next round
local CONFIRM_WAIT = 3 -- seconds an automatic confirm waits for its answer
local AFTER_CUT = 95   -- percent of a sale left after the house's cut
local ALERT_SOUND = SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959

local searched = {}    -- [itemID] = the cheapest price the last search was for
local buying           -- the deal a Buy click asked a quote for
local manual = false   -- the game wanted a click for a confirm: confirms wait for one
local roundQueued = false

-- The items on the lists ticked Snipe, each once, in list order.
function Snipe:Items()
    local items, seen = {}, {}
    for _, list in ipairs(addon.db.lists) do
        if list.snipe then
            for _, entry in ipairs(list.entries) do
                local itemID = entry.itemID
                if itemID and not seen[itemID] then
                    seen[itemID] = true
                    items[#items + 1] = itemID
                end
            end
        end
    end
    return items
end

local function IsWatched(itemID)
    for _, watched in ipairs(Snipe:Items()) do
        if watched == itemID then return true end
    end
    return false
end

-- The most to pay for one: your own max, else the cut under its usual price;
-- nil without either. own: the max is yours.
function Snipe:Max(itemID)
    local own = addon.db.snipe.max[itemID]
    if own then return own, true end
    local usual = addon:UsualPrice(itemID)
    if usual then return math.floor(usual * (100 - addon.db.snipe.cut) / 100), false end
end

-- The offers at or under the max that aren't yours, as many as your gold
-- covers. Nil when there are none.
local function MakeDeal(itemID, result, max)
    local deal = { itemID = itemID, commodity = result.commodity, count = 0, total = 0 }
    local money = GetMoney()
    for _, row in ipairs(result.rows) do
        if not row.own and row.unit <= max then
            local take = math.min(row.quantity, math.floor((money - deal.total) / row.unit))
            if take > 0 then
                deal.count = deal.count + take
                deal.total = deal.total + take * row.unit
                if not deal.unit or row.unit < deal.unit then
                    deal.unit = row.unit
                    if not result.commodity then deal.row = row end
                end
            end
        end
    end
    if deal.count == 0 then return nil end
    local usual = addon:UsualPrice(itemID)
    if usual then deal.profit = math.floor(usual * deal.count * AFTER_CUT / 100) - deal.total end
    return deal
end

local function Alert(deal)
    PlaySound(ALERT_SOUND, "Master")
    if FlashClientIcon then FlashClientIcon() end
    addon:SetStatus(("Deal: %d %s for %s"):format(deal.count, addon:ItemName(deal.itemID) or "",
        addon.Money(deal.total)))
end

-- Every search answer for a watched item, a round's or any other, makes or
-- clears its deal. A new deal, a cheaper one or more of it sounds the alert.
addon:Listen("RESULTS", function(itemID)
    if not Snipe.watching then return end
    local max, result = Snipe:Max(itemID), Auction.results[itemID]
    if not (max and result and IsWatched(itemID)) then return end
    local old, deal = Snipe.deals[itemID], MakeDeal(itemID, result, max)
    Snipe.deals[itemID] = deal
    if deal and (not old or deal.unit < old.unit or deal.count > old.count) then Alert(deal) end
end)

--------------------------------------------------------------------------------
-- The rounds
--------------------------------------------------------------------------------

-- At the auction house, while the RichSnobs tab shows: on Blizzard's tabs
-- the checks would swap the items in its browse list.
local function CanRun()
    return Auction.isOpen and addon.window ~= nil and addon.window:IsVisible()
end

local Round

local function QueueRound()
    if roundQueued then return end
    roundQueued = true
    C_Timer.After(ROUND_PAUSE, function()
        roundQueued = false
        Round()
    end)
end

-- A price check only brings each item's cheapest offer. One at or under the
-- max gets a search, unless the last search was for that same price.
local function OnBatch(found, batch)
    for _, itemID in ipairs(batch) do
        local price, max = found[itemID], Snipe:Max(itemID)
        if price and max and price <= max then
            if searched[itemID] ~= price then
                searched[itemID] = price
                Auction:Search(itemID, true, true)
            end
        else
            searched[itemID] = nil
            Snipe.deals[itemID] = nil
        end
    end
end

-- Only items with a max are checked; a paused round looks again later.
function Round()
    if not Snipe.watching then return end
    if not CanRun() then return QueueRound() end
    local ids = {}
    for _, itemID in ipairs(Snipe:Items()) do
        if Snipe:Max(itemID) then ids[#ids + 1] = itemID end
    end
    Auction:ScanPrices(ids, "snipe", {
        quiet = true,
        includeVendor = true,
        onBatch = OnBatch,
        onDone = function()
            Snipe.checkedAt = GetTime()
            QueueRound()
        end,
    })
end

function Snipe:Start()
    if self.watching then return end
    self.watching = true
    self.checkedAt = nil
    Round()
    addon:Refresh()
end

function Snipe:Stop()
    self.watching = false
    wipe(self.deals)
    wipe(searched)
    buying = nil
    addon:Refresh()
end

addon:Listen("AH_HIDE", function()
    if Snipe.watching then Snipe:Stop() end
end)

-- After a new max or cut, the deals are worked out again from the offers in
-- hand, and the next round searches again whatever is under the new max.
local function Recheck()
    wipe(searched)
    for itemID in pairs(Snipe.deals) do
        local max, result = Snipe:Max(itemID), Auction.results[itemID]
        Snipe.deals[itemID] = max and result and MakeDeal(itemID, result, max) or nil
    end
    addon:Refresh()
end

-- copper: nil goes back to the cut under the usual price.
function Snipe:SetMax(itemID, copper)
    addon.db.snipe.max[itemID] = copper
    Recheck()
end

function Snipe:SetCut(percent)
    addon.db.snipe.cut = percent
    Recheck()
end

--------------------------------------------------------------------------------
-- Buying
--------------------------------------------------------------------------------

-- The quote waiting for a click on its deal's Confirm.
function Snipe:WaitingQuote(deal)
    local quote = Auction.quote
    if quote and quote.itemID == deal.itemID and quote.total and not quote.confirming then return quote end
end

-- From a click: a commodity's deal asks for a quote for all of it, or
-- confirms the quote waiting for a click; an item auction is bought out.
function Snipe:Buy(deal)
    if not deal.commodity then
        Auction:BuyAuction(deal.itemID, deal.row)
    elseif self:WaitingQuote(deal) then
        Auction:ConfirmBuy()
    else
        buying = deal
        Auction:StartBuy(deal.itemID, deal.count)
    end
end

local function SearchAgain(itemID)
    searched[itemID] = nil
    Auction:Search(itemID, true, true)
end

-- A quote that costs no more than the max for each is confirmed at once, so
-- one click buys. Offers can go between the search and the click; a quote
-- over the max is dropped, and the item searched again.
addon:Listen("QUOTE", function(quote)
    local deal = buying
    buying = nil
    if not (deal and quote.itemID == deal.itemID and quote.quantity == deal.count) then return end
    local max = Snipe:Max(deal.itemID)
    if not max or quote.total > max * quote.quantity then
        Auction:CancelQuote()
        addon:SetStatus("Some of the cheap ones are gone; searching again")
        SearchAgain(deal.itemID)
        addon:Refresh()
        return
    end
    if manual then return end
    Auction:ConfirmBuy()
    if not (Auction.quote == quote and quote.confirming) then return end
    addon:SetStatus(("Buying %d %s for %s..."):format(quote.quantity, addon:ItemName(quote.itemID) or "",
        addon.Money(quote.total)))
    -- No answer means the game wants a click for it: the deal's button then
    -- says Confirm, and so it does for the rest of the session.
    C_Timer.After(CONFIRM_WAIT, function()
        if Auction.quote == quote and quote.confirming then
            quote.confirming = nil
            manual = true
            addon:SetStatus("Click Confirm to buy")
            addon:Refresh()
        end
    end)
end)

addon:On("COMMODITY_PRICE_UNAVAILABLE", function()
    local deal = buying
    buying = nil
    if deal then SearchAgain(deal.itemID) end
end)
