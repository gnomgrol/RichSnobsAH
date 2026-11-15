-- The My auctions tab: your auctions grouped as Undercut, Cheapest and Sold,
-- checked against the cheapest offers in one batched request, a cancel
-- button on each, and what the sold ones bring in after the cut.

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
    local cheapest = Auction.ownedMin[auction.itemID]
    if not cheapest or not auction.unit then return "unchecked" end
    -- Half a copper of slack for the per-unit price of multi-item auctions.
    if cheapest < auction.unit - 0.5 then return "undercut" end
    return "cheapest"
end

local function ByName(a, b)
    local x, y = addon:ItemName(a.itemID) or "", addon:ItemName(b.itemID) or ""
    if x ~= y then return x < y end
    return a.auctionID < b.auctionID
end

local function BuildElements()
    local grouped, incoming = {}, 0
    for _, auction in ipairs(Auction.owned or {}) do
        local key = GroupOf(auction)
        grouped[key] = grouped[key] or {}
        table.insert(grouped[key], auction)
        if auction.sold then incoming = incoming + (auction.total or 0) * 0.95 end
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
    return elements, incoming
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

    -- Undercut rows show the price that beat yours; sold rows the whole sale,
    -- as Blizzard's frame shows it. The cut comes off in the total below.
    if data.group.key == "undercut" then
        row.price:SetText(addon.Money(Auction.ownedMin[auction.itemID]))
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
    pane.scrollBox:SetPoint("TOPLEFT", 4, -4)
    pane.scrollBox:SetPoint("BOTTOMRIGHT", -16, 62)
    pane.scrollBar:SetPoint("TOPLEFT", pane.scrollBox, "TOPRIGHT", 4, 0)
    pane.scrollBar:SetPoint("BOTTOMLEFT", pane.scrollBox, "BOTTOMRIGHT", 4, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetPoint("TOP", 0, -40)

    pane.incomingLabel = UI.Text(pane, "GameFontHighlight")
    pane.incomingLabel:SetText("Incoming after the cut")
    pane.incomingLabel:SetPoint("BOTTOMLEFT", 10, 44)
    pane.incoming = UI.Text(pane, "GameFontHighlight", "RIGHT")
    pane.incoming:SetPoint("BOTTOMRIGHT", -10, 44)

    pane.refresh = UI.Button(pane, "Check again", 120, 26)
    pane.refresh:SetPoint("BOTTOMLEFT", 8, 8)
    pane.refresh:SetPoint("RIGHT", -8, 0)
    pane.refresh:SetScript("OnClick", function() Auction:QueryOwned(true) end)

    function pane:Refresh()
        if not self:IsVisible() then return end
        local elements, incoming = BuildElements()
        self.scrollBox:SetDataProvider(CreateDataProvider(elements), ScrollBoxConstants.RetainScrollPosition)
        if not Auction.owned then
            self.message:SetText("Loading your auctions...")
        elseif #Auction.owned == 0 then
            self.message:SetText("You have no auctions up")
        else
            self.message:SetText("")
        end
        self.incoming:SetText(addon.Money(incoming))
        self.refresh:SetEnabled(Auction:CanAct() and not Auction:IsScanning())
    end

    pane:SetScript("OnShow", function(self)
        Auction:QueryOwned(true)
        self:Refresh()
    end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
