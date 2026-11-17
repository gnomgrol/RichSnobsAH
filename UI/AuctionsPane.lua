-- The Cancel tab: your auctions grouped as Undercut, Cheapest and Sold,
-- checked against the cheapest offers in one batched request, then each
-- undercut item searched for by how many and how much; a cancel button on
-- each, and what the sold ones bring in after the cut, and when.

local _, addon = ...
local UI = addon.UI
local Auction = addon.Auction

local ROW_HEIGHT = 20

local GROUPS = {
    { key = "undercut", name = "Undercut", color = { 1, 0.3, 0.3 } },
    { key = "cheapest", name = "Cheapest", color = { 0.25, 0.9, 0.25 } },
    { key = "unchecked", name = "Not checked", color = { 1, 1, 1 } },
    { key = "sold", name = "Sold", color = { 1, 0.82, 0 } },
}

local function GroupOf(auction)
    if auction.sold then return "sold" end
    if not Auction.ownedMin[auction.itemID] or not auction.unit then return "unchecked" end
    return Auction:UndercutBy(auction) and "undercut" or "cheapest"
end

-- "3 cheaper, by 1s 20c": how many are up for less than yours (auctions,
-- or units of a commodity) and how far under it the cheapest is, each. The
-- count comes once that item's own search is in.
local function UndercutText(auction)
    local by = "by " .. addon.Money(Auction:UndercutBy(auction), true)
    local count, more = Auction:CheaperThan(auction)
    if not count then return by end
    return ("%s%s cheaper, %s"):format(BreakUpLargeNumbers(count), more and "+" or "", by)
end

local function ByName(a, b)
    local x, y = addon:ItemName(a.itemID) or "", addon:ItemName(b.itemID) or ""
    if x ~= y then return x < y end
    return a.auctionID < b.auctionID
end

-- What the sold auctions bring in after the cut, and the first and last time
-- their gold is mailed, of those still to come that the game gave a time for.
local function Incoming()
    local money, first, last, now = 0, nil, nil, time()
    for _, auction in ipairs(Auction.owned or {}) do
        if auction.sold then
            money = money + (auction.total or 0) * 0.95
            local arrives = auction.arrives
            if arrives and arrives > now then
                first = math.min(first or arrives, arrives)
                last = math.max(last or arrives, arrives)
            end
        end
    end
    return money, first, last
end

-- "in 12 min", or "in 3-58 min" when the payments are spread out.
local function ArrivalText(first, last)
    local soon, late = addon.Age(first), addon.Age(last)
    if soon == late then return "in " .. soon end
    if soon:match("%a+$") == late:match("%a+$") then return ("in %s-%s"):format(soon:match("^%d+"), late) end
    return ("in %s to %s"):format(soon, late)
end

local function BuildElements()
    local grouped = {}
    for _, auction in ipairs(Auction.owned or {}) do
        local key = GroupOf(auction)
        grouped[key] = grouped[key] or {}
        table.insert(grouped[key], auction)
    end
    local elements = {}
    for _, group in ipairs(GROUPS) do
        local auctions = grouped[group.key]
        if auctions then
            table.sort(auctions, ByName)
            elements[#elements + 1] = { kind = "group", group = group, count = #auctions }
            for _, auction in ipairs(auctions) do
                elements[#elements + 1] = { kind = "auction", group = group, auction = auction }
            end
        end
    end
    return elements
end

local function OnRowEnter(row)
    local data = row.data
    if not data or data.kind ~= "auction" then return end
    local auction = data.auction
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(auction.itemID)
    if auction.unit then GameTooltip:AddDoubleLine("Yours, each", addon.Money(auction.unit, true), 1, 0.82, 0, 1, 1, 1) end
    local cheapest = Auction.ownedMin[auction.itemID]
    if cheapest and not auction.sold then
        GameTooltip:AddDoubleLine("Cheapest, each", addon.Money(cheapest, true), 1, 0.82, 0, 1, 1, 1)
    end
    if auction.timeLeft and not auction.sold then
        GameTooltip:AddDoubleLine("Time left", addon.Age(auction.timeLeft), 1, 0.82, 0, 1, 1, 1)
    end
    if auction.sold and auction.arrives and auction.arrives > time() then
        GameTooltip:AddDoubleLine("Gold arrives in", addon.Age(auction.arrives - time()), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function InitRow(row)
    if row.initialized then return end
    row.initialized = true
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.cancel = UI.Button(row, "Cancel", 56, 18)
    row.cancel:SetPoint("RIGHT", -2, 0)
    row.cancel:SetScript("OnClick", function()
        local data = row.data
        if data and data.auction then Auction:Cancel(data.auction.auctionID) end
    end)
    row.price = UI.Text(row, nil, "RIGHT")
    row.price:SetPoint("RIGHT", row.cancel, "LEFT", -4, 0)
    row.name = UI.Text(row)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", function()
        local data = row.data
        if data and data.auction then UI.ModifiedClick(data.auction.itemID) end
    end)
end

local function UpdateRow(row, data)
    InitRow(row)
    row.data = data
    row.name:ClearAllPoints()
    if data.kind == "group" then
        row.icon:Hide()
        row.cancel:Hide()
        row.price:SetText("")
        row.name:SetFontObject("GameFontNormal")
        row.name:SetTextColor(unpack(data.group.color))
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetPoint("RIGHT", -4, 0)
        row.name:SetText(("%s  |cff808080%d|r"):format(data.group.name, data.count))
        return
    end

    local auction = data.auction
    row.icon:SetTexture(addon:ItemIcon(auction.itemID))
    row.icon:Show()
    row.name:SetFontObject("GameFontHighlightSmall")
    row.name:SetTextColor(addon:QualityColor(auction.itemID))
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.price, "LEFT", -4, 0)
    local name = addon:ItemName(auction.itemID) or "..."
    row.name:SetText(auction.quantity > 1 and ("%s x%d"):format(name, auction.quantity) or name)

    -- Undercut rows show by how many and how much; sold rows the whole sale,
    -- as Blizzard's frame shows it. The cut comes off in the total below.
    if data.group.key == "undercut" then
        row.price:SetText(UndercutText(auction))
    elseif auction.sold then
        row.price:SetText(addon.Money(auction.total))
    else
        row.price:SetText(addon.Money(auction.unit))
    end
    row.price:SetTextColor(unpack(data.group.color))

    row.cancel:SetShown(not auction.sold)
    row.cancel:SetEnabled(Auction:CanAct() and not Auction:Busy())
end

function UI.CreateAuctionsPane(parent)
    local pane = CreateFrame("Frame", nil, parent)

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    UI.PlaceScrollList(pane.scrollBox, pane.scrollBar, -4, 62)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetPoint("TOP", 0, -40)

    pane.incoming = UI.Text(pane, "GameFontHighlight", "RIGHT")
    pane.incoming:SetPoint("BOTTOMRIGHT", -10, 44)
    pane.incomingLabel = UI.Text(pane, "GameFontHighlight")
    pane.incomingLabel:SetPoint("BOTTOMLEFT", 10, 44)
    pane.incomingLabel:SetPoint("RIGHT", pane.incoming, "LEFT", -6, 0)

    pane.refresh = UI.Button(pane, "Check again", 120, 26)
    pane.refresh:SetPoint("BOTTOMLEFT", 8, 8)
    pane.refresh:SetPoint("RIGHT", -8, 0)
    pane.refresh:SetScript("OnClick", function() Auction:QueryOwned(true) end)

    local due
    function pane:UpdateIncoming()
        local money, first, last = Incoming()
        local now = time()
        due = first
        self.incomingLabel:SetText(first and "Incoming " .. ArrivalText(first - now, last - now) or "Incoming")
        self.incoming:SetText(addon.Money(money))
    end

    -- The countdown ticks once a second while the tab shows. When a payment
    -- comes due, your auctions are asked for again so the mailed sale drops off.
    local sinceTick = 0
    pane:SetScript("OnUpdate", function(self, elapsed)
        sinceTick = sinceTick + elapsed
        if sinceTick < 1 then return end
        sinceTick = 0
        if due and time() >= due then Auction:QueryOwned() end
        self:UpdateIncoming()
    end)

    function pane:Refresh()
        if not self:IsVisible() then return end
        self.scrollBox:SetDataProvider(CreateDataProvider(BuildElements()), ScrollBoxConstants.RetainScrollPosition)
        if not Auction.owned then
            self.message:SetText("Loading your auctions...")
        elseif #Auction.owned == 0 then
            self.message:SetText("You have no auctions up")
        else
            self.message:SetText("")
        end
        self:UpdateIncoming()
        self.refresh:SetEnabled(Auction:CanAct() and not Auction:IsScanning())
    end

    pane:SetScript("OnShow", function(self)
        Auction:QueryOwned(true)
        self:Refresh()
    end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
