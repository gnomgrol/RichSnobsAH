-- Stay cheapest for whole lists: the items of the lists ticked "Stay
-- cheapest" that you have in your bags or up for sale. While on, and while
-- the RichSnobs tab shows at the auction house, one quiet price check of
-- them all runs every couple of seconds, and each item's cheapest offer is
-- held against your own lowest price. Under it, you were undercut; over it,
-- your cheapest one is gone, most likely sold. Either plays a sound, and
-- Post next puts up one more of the first item that needs it, a step under
-- the cheapest, never under its floor. With none left in your bags, Cancel
-- extras takes down all of an item's auctions but your cheapest.

local _, addon = ...
local Auction = addon.Auction

local Stay = {
    on = false,
    -- [itemID] = the cheapest offer each in the last check, false when none was up
    cheapest = {},
    checkedAt = nil, -- GetTime() when the last round ended
    round = { posts = 0, deposits = 0 },
}
addon.Stay = Stay

local ROUND_PAUSE = 2 -- seconds from one round's end to the next round
local ALERT_SOUND = SOUNDKIT and SOUNDKIT.READY_CHECK or 8960

local posted = {}    -- [itemID] = { unit, at }: your latest post, until your auctions show it
local wasYours = {}  -- [itemID] = true while your offer was the cheapest
local roundQueued = false
local running = false -- a round's check is out: a Stop and Start meanwhile waits for it
local roundStart = 0 -- GetTime() when the running round began

-- Whether a list ticked Stay cheapest has the item.
local function Ticked(itemID)
    for _, list in ipairs(addon.db.lists) do
        if list.stay then
            for _, entry in ipairs(list.entries) do
                if entry.itemID == itemID then return true end
            end
        end
    end
    return false
end

function Stay:AnyTicked()
    for _, list in ipairs(addon.db.lists) do
        if list.stay then return true end
    end
    return false
end

-- Your lowest price each up for an item, counting a post your auctions
-- don't show yet; nil when you have none up.
function Stay:Yours(itemID)
    local post = posted[itemID]
    local low = post and post.unit
    for _, auction in ipairs(Auction.owned or {}) do
        if auction.itemID == itemID and not auction.sold and auction.unit then
            low = math.min(low or auction.unit, auction.unit)
        end
    end
    return low
end

-- The ticked lists' items that you have in your bags or up for sale, each
-- once, in list order.
function Stay:Items()
    local items, seen = {}, {}
    for _, list in ipairs(addon.db.lists) do
        if list.stay then
            for _, entry in ipairs(list.entries) do
                local itemID = entry.itemID
                if itemID and not seen[itemID] then
                    seen[itemID] = true
                    if addon:BagCount(itemID) > 0 or self:Yours(itemID) then items[#items + 1] = itemID end
                end
            end
        end
    end
    return items
end

-- "yours" while your lowest is the cheapest (a tie counts), "undercut" when
-- an offer is under it, "gone" when the cheapest is over it (your cheapest
-- sold, most likely), "none" when you have none up, and "unchecked" before
-- a check or before your auctions are in. Half a copper of slack for the
-- price each of a multi-item auction.
function Stay:State(itemID)
    local cheapest = self.cheapest[itemID]
    if cheapest == nil or not Auction.owned then return "unchecked" end
    local low = self:Yours(itemID)
    if not low then return "none" end
    if not cheapest or cheapest > low + 0.5 then return "gone" end
    if cheapest < low - 0.5 then return "undercut" end
    return "yours"
end

-- What the next post of an item goes up at: a step under the cheapest
-- offer, or the last price known when nobody has any up; nil without one.
-- Item auctions take whole silver.
function Stay:Price(itemID, commodity)
    local cheapest = self.cheapest[itemID]
    local price = cheapest and Auction:PriceUnder({ unit = cheapest }, commodity) or addon:GetAHPrice(itemID)
    if price and not commodity then price = math.max(100, math.floor(price / 100) * 100) end
    return price and math.floor(price)
end

-- Whether an item is posted next, or why not: "post", "yours", "floor" (its
-- price would be under the floor), "empty" (none in your bags can be sold),
-- "unchecked" (no check yet, or no price known).
function Stay:Group(itemID)
    local state = self:State(itemID)
    if state == "unchecked" or state == "yours" then return state end
    local location = addon:FindInBags(itemID, true)
    if not location then return "empty" end
    local price = self:Price(itemID, addon:IsCommodity(itemID, location))
    if not price then return "unchecked" end
    local floor = addon:Floor(itemID)
    if floor and price < floor then return "floor" end
    return "post"
end

-- The first item to post, in list order.
function Stay:Next()
    for _, itemID in ipairs(self:Items()) do
        if self:Group(itemID) == "post" then return itemID end
    end
end

-- From a click: one more of the next item, at its price.
function Stay:PostNext()
    local itemID = self:Next()
    if not itemID then return end
    local location = addon:FindInBags(itemID, true)
    local commodity = addon:IsCommodity(itemID, location)
    if commodity == nil then
        addon:SetStatus("Search this item once first, so the auction house says how it sells")
        return
    end
    Auction:Post(itemID, location, commodity, 1, self:Price(itemID, commodity), addon.db.duration)
end

-- Of the items with none left in your bags, your auctions past the cheapest
-- one of each: item by item in list order, dearest first. Of two at the
-- same price the oldest stays, as it's first in line. One without a buyout
-- is left alone.
function Stay:Extras()
    local extras = {}
    for _, itemID in ipairs(self:Items()) do
        if not addon:FindInBags(itemID, true) then
            local mine = {}
            for _, auction in ipairs(Auction.owned or {}) do
                if auction.itemID == itemID and not auction.sold and auction.unit then mine[#mine + 1] = auction end
            end
            table.sort(mine, function(a, b)
                if a.unit ~= b.unit then return a.unit > b.unit end
                return (a.auctionID or 0) > (b.auctionID or 0)
            end)
            for i = 1, #mine - 1 do extras[#extras + 1] = mine[i] end
        end
    end
    return extras
end

-- From a click: the game wants one per cancel.
function Stay:CancelExtra()
    local auction = self:Extras()[1]
    if auction then Auction:Cancel(auction.auctionID) end
end

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

local function Alert(itemIDs)
    PlaySound(ALERT_SOUND, "Master")
    if FlashClientIcon then FlashClientIcon() end
    local name = addon:ItemName(itemIDs[1]) or ""
    addon:SetStatus(#itemIDs == 1 and ("%s: the cheapest isn't yours any more"):format(name)
        or ("%s and %d more: the cheapest isn't yours any more"):format(name, #itemIDs - 1))
end

-- Each item's cheapest, from the check. A post made since the round began
-- may be missing from it, so that item waits for the next round. An item
-- whose cheapest stopped being yours sounds the alert while there are more
-- to post; one whose cheapest is gone has your auctions asked for again.
local function OnBatch(found, batch)
    if not Stay.on then return end -- stopped while the check was out
    local flipped, gone = {}, false
    for _, itemID in ipairs(batch) do
        local post = posted[itemID]
        if not (post and post.at >= roundStart) then
            Stay.cheapest[itemID] = found[itemID] or false
            local state = Stay:State(itemID)
            if wasYours[itemID] and state ~= "yours" and state ~= "unchecked"
                and addon:FindInBags(itemID, true) then
                flipped[#flipped + 1] = itemID
            end
            wasYours[itemID] = state == "yours"
            if state == "gone" then gone = true end
        end
    end
    if gone then Auction:QueryOwned() end
    if #flipped > 0 then Alert(flipped) end
    addon:Refresh()
end

function Round()
    if not Stay.on or running then return end
    if not CanRun() then return QueueRound() end
    roundStart = GetTime()
    running = true
    local started = Auction:ScanPrices(Stay:Items(), "stay cheapest", {
        quiet = true,
        includeVendor = true,
        onBatch = OnBatch,
        onDone = function()
            running = false
            Stay.checkedAt = GetTime()
            QueueRound()
        end,
    })
    if not started then running = false end
end

-- A new round: its posts and deposits start from nothing.
function Stay:Start()
    if self.on then return end
    self.on = true
    self.checkedAt = nil
    self.round = { posts = 0, deposits = 0 }
    wipe(self.cheapest)
    wipe(posted)
    wipe(wasYours)
    Auction:QueryOwned()
    Round()
    addon:Refresh()
end

function Stay:Stop()
    self.on = false
    addon:Refresh()
end

-- Closing the house drops every check, so no round is out any more.
addon:Listen("AH_HIDE", function()
    running = false
    if Stay.on then Stay:Stop() end
end)

-- A post of a ticked list's item while on joins the round, and counts as
-- yours and the cheapest until a check or your auctions say otherwise.
addon:Listen("POSTED", function(posting)
    local itemID = posting.itemID
    if not (Stay.on and Ticked(itemID)) then return end
    Stay.round.posts = Stay.round.posts + 1
    Stay.round.deposits = Stay.round.deposits + (posting.deposit or 0)
    posted[itemID] = { unit = posting.unit, at = GetTime() }
    local cheapest = Stay.cheapest[itemID]
    if not cheapest or posting.unit < cheapest then Stay.cheapest[itemID] = posting.unit end
    wasYours[itemID] = Stay:State(itemID) == "yours"
    addon:Refresh()
end)

-- Your auctions are in: a post they show needs no remembering.
addon:Listen("OWNED", function()
    for itemID, post in pairs(posted) do
        for _, auction in ipairs(Auction.owned or {}) do
            if auction.itemID == itemID and auction.unit and math.abs(auction.unit - post.unit) < 0.5 then
                posted[itemID] = nil
                break
            end
        end
    end
end)
