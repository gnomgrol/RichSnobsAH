-- The Snipe tab: the deals the rounds found, each with a Buy button, then
-- every watched item with its price now, its max and its usual price.
-- Below them, how far under the usual price the max sits, the watching
-- state with the button that starts and stops it, and a big button that
-- buys the top deal. Right-click an item to set its own max.

local _, addon = ...
local UI = addon.UI
local Auction = addon.Auction
local Snipe = addon.Snipe

local ROW_HEIGHT = 20
local CELL = 64 -- each of the three price columns

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local GRAY = { 0.5, 0.5, 0.5 }
local GREEN = { 0.25, 0.9, 0.25 }
local RED = { 1, 0.3, 0.3 }
local BLUE = { 0.4, 0.73, 1 } -- a max of your own

local DEALS = { name = "Deals", color = GOLD, heads = { "Each", "Profit", "" } }
local WATCHED = { name = "Watching", color = WHITE, heads = { "Now", "Max", "Usual" } }

local function ByName(a, b)
    local x, y = addon:ItemName(a) or "", addon:ItemName(b) or ""
    if x ~= y then return x < y end
    return a < b
end

-- The most profit first; deals without a usual price after them.
local function ByProfit(a, b)
    if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
    if a.profit and a.profit ~= b.profit then return a.profit > b.profit end
    return ByName(a.itemID, b.itemID)
end

-- The watched items' deals, most profit first.
local function SortedDeals()
    local deals = {}
    for _, itemID in ipairs(Snipe:Items()) do
        if Snipe.deals[itemID] then deals[#deals + 1] = Snipe.deals[itemID] end
    end
    table.sort(deals, ByProfit)
    return deals
end

local function BuildElements(deals)
    local items = Snipe:Items()
    table.sort(items, ByName)
    local elements = {}
    if #deals > 0 then
        elements[#elements + 1] = { kind = "group", group = DEALS, count = #deals }
        for _, deal in ipairs(deals) do
            elements[#elements + 1] = { kind = "deal", itemID = deal.itemID, deal = deal }
        end
    end
    if #items > 0 then
        elements[#elements + 1] = { kind = "group", group = WATCHED, count = #items }
        for _, itemID in ipairs(items) do
            elements[#elements + 1] = { kind = "item", itemID = itemID }
        end
    end
    return elements
end

local function MaxLabel(own)
    return own and "Your max" or ("Max, %d%% under usual"):format(addon.db.snipe.cut)
end

local function ShowMenu(row, itemID)
    MenuUtil.CreateContextMenu(row, function(_, root)
        local max, own = Snipe:Max(itemID)
        root:CreateTitle(addon:ItemName(itemID) or "")
        root:CreateButton("Set max...", function()
            addon:Prompt(("Most to pay for one %s, like 12g 50s:"):format(addon:ItemName(itemID) or "item"),
                max and UI.PlainMoney(max) or "", function(text)
                    local copper = UI.ParseMoney(text)
                    if copper then
                        Snipe:SetMax(itemID, copper)
                    else
                        addon:SetStatus("Not a price: " .. text)
                    end
                end)
        end)
        root:CreateButton(("Use %d%% under usual"):format(addon.db.snipe.cut), function()
            Snipe:SetMax(itemID, nil)
        end):SetEnabled(own == true)
        root:CreateButton("Search", function()
            addon:Select({ itemID = itemID }, "buy")
            Auction:Search(itemID)
        end):SetEnabled(Auction.isOpen)
        root:CreateButton("Price history", function() addon:ShowHistory(itemID) end)
    end)
end

local function OnRowClick(row, button)
    local data = row.data
    if not data or data.kind == "group" then return end
    if button == "RightButton" then
        ShowMenu(row, data.itemID)
    else
        UI.ModifiedClick(data.itemID)
    end
end

local function Line(left, right)
    GameTooltip:AddDoubleLine(left, right, 1, 0.82, 0, 1, 1, 1)
end

local function OnRowEnter(row)
    local data = row.data
    if not data or data.kind == "group" then return end
    local itemID = data.itemID
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(itemID)
    local deal = data.deal
    if deal then Line(("%d for"):format(deal.count), addon.Money(deal.total)) end
    local max, own = Snipe:Max(itemID)
    Line(MaxLabel(own), max and addon.Money(max, true) or "right-click to set one")
    local usual = addon:UsualPrice(itemID)
    if usual then Line("Usual", addon.Money(usual, true)) end
    GameTooltip:Show()
end

-- What a deal's Buy does now: "buying" while the house answers, "confirm"
-- when a quote waits for a click, else "buy"; and whether it takes a click.
local function BuyState(deal)
    local quote, item = Auction.quote, Auction.buying
    if (quote and quote.itemID == deal.itemID and (quote.pending or quote.confirming))
        or (item and item.itemID == deal.itemID) then
        return "buying", false
    elseif Snipe:WaitingQuote(deal) then
        return "confirm", true
    end
    return "buy", Auction:CanAct() and not Auction:Busy()
end

-- A row's Buy: Buy, then "..." while the house answers; Confirm when a
-- quote waits for a click. The big button says what it buys.
local ROW_WORDS = { buying = "...", confirm = "Confirm", buy = "Buy" }
local BIG_WORDS = { buying = "Buying %s...", confirm = "Confirm %s", buy = "Buy %s" }

-- The big button's deal: the one a purchase is under way or waits for a
-- click for, else the top one.
local function NextDeal(deals)
    local quote, item = Auction.quote, Auction.buying
    for _, deal in ipairs(deals) do
        if (quote and quote.itemID == deal.itemID) or (item and item.itemID == deal.itemID) then return deal end
    end
    return deals[1]
end

-- "12 Linen Cloth for 3g 20s": what a click on the big button buys. A quote
-- in hand gives its own count and total; an item deal buys its cheapest
-- auction, one per click.
local function DealWords(deal)
    local name = addon:ItemName(deal.itemID) or "..."
    local quote = Auction.quote
    if quote and quote.itemID == deal.itemID and quote.total then
        return ("%d %s for %s"):format(quote.quantity, name, addon.Money(quote.total))
    elseif deal.commodity then
        return ("%d %s for %s"):format(deal.count, name, addon.Money(deal.total))
    end
    return ("1 %s for %s"):format(name, addon.Money(deal.row.buyout))
end

local function SetCell(row, i, text, color)
    local cell = row.cells[i]
    cell:SetText(text or "")
    cell:SetTextColor(unpack(color or WHITE))
end

local function InitRow(row)
    if row.initialized then return end
    row.initialized = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.cells = {}
    for i = 1, 3 do
        local cell = UI.Text(row, nil, "RIGHT")
        cell:SetWidth(CELL - 4)
        cell:SetPoint("RIGHT", -2 - (3 - i) * CELL, 0)
        row.cells[i] = cell
    end
    row.buy = UI.Button(row, "Buy", CELL - 4, 18)
    row.buy:SetPoint("RIGHT", -2, 0)
    row.buy:SetScript("OnClick", function()
        local data = row.data
        if data and data.deal then Snipe:Buy(data.deal) end
    end)
    row.name = UI.Text(row)
    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
end

local function UpdateRow(row, data)
    InitRow(row)
    row.data = data
    row.buy:Hide()
    row.name:ClearAllPoints()
    row.name:SetPoint("RIGHT", row.cells[1], "LEFT", -4, 0)

    -- A group's row names its columns.
    if data.kind == "group" then
        row.icon:Hide()
        row.name:SetFontObject("GameFontNormal")
        row.name:SetTextColor(unpack(data.group.color))
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetText(("%s  |cff808080%d|r"):format(data.group.name, data.count))
        for i, head in ipairs(data.group.heads) do
            row.cells[i]:SetFontObject("GameFontNormalSmall")
            SetCell(row, i, head, GOLD)
        end
        return
    end

    local itemID = data.itemID
    row.icon:SetTexture(addon:ItemIcon(itemID))
    row.icon:Show()
    row.name:SetFontObject("GameFontHighlightSmall")
    row.name:SetTextColor(addon:QualityColor(itemID))
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    for i = 1, 3 do row.cells[i]:SetFontObject("GameFontHighlightSmall") end
    local name = addon:ItemName(itemID) or "..."

    -- A deal: how many, what each costs on average, and the profit of
    -- selling them at the usual price after the cut.
    local deal = data.deal
    if deal then
        row.name:SetText(("%s x%d"):format(name, deal.count))
        SetCell(row, 1, addon.Money(deal.total / deal.count, true))
        SetCell(row, 2, deal.profit and addon.Money(deal.profit), deal.profit and deal.profit < 0 and RED or GREEN)
        SetCell(row, 3, "")
        local state, enabled = BuyState(deal)
        row.buy:SetText(ROW_WORDS[state])
        row.buy:SetEnabled(enabled)
        row.buy:Show()
        return
    end

    row.name:SetText(name)
    local max, own = Snipe:Max(itemID)
    local usual = addon:UsualPrice(itemID)
    SetCell(row, 1, addon.Money((addon:GetAHPrice(itemID))))
    SetCell(row, 2, max and addon.Money(max) or "-", own and BLUE or max and WHITE or GRAY)
    SetCell(row, 3, usual and addon.Money(usual))
end

function UI.CreateSnipePane(parent)
    local pane = CreateFrame("Frame", nil, parent)

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    UI.PlaceScrollList(pane.scrollBox, pane.scrollBar, -4, 108)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetPoint("TOP", 0, -40)

    -- The max: this many percent under the usual price.
    pane.cutLabel = UI.Text(pane, "GameFontHighlight")
    pane.cutLabel:SetPoint("BOTTOMLEFT", 10, 86)
    pane.cutLabel:SetText("Max")
    pane.cut = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    pane.cut:SetSize(28, 20)
    pane.cut:SetAutoFocus(false)
    pane.cut:SetNumeric(true)
    pane.cut:SetMaxLetters(2)
    pane.cut:SetPoint("LEFT", pane.cutLabel, "RIGHT", 12, 0)
    pane.cutNote = UI.Text(pane, "GameFontHighlight")
    pane.cutNote:SetPoint("LEFT", pane.cut, "RIGHT", 4, 0)
    pane.cutNote:SetText("% under the usual price")
    pane.cut:SetScript("OnEditFocusLost", function(box)
        local n = tonumber(box:GetText())
        if n and n >= 1 and n <= 99 and n ~= addon.db.snipe.cut then Snipe:SetCut(n) end
        box:SetText(tostring(addon.db.snipe.cut))
    end)
    pane.cut:SetScript("OnEnterPressed", EditBox_ClearFocus)
    pane.cut:SetScript("OnEscapePressed", function(box)
        box:SetText(tostring(addon.db.snipe.cut))
        box:ClearFocus()
    end)

    -- Watching: its state, and the button that starts and stops it.
    pane.toggle = UI.Button(pane, "Start watching", 120, 22)
    pane.toggle:SetPoint("BOTTOMRIGHT", -8, 54)
    pane.toggle:SetScript("OnClick", function()
        if Snipe.watching then Snipe:Stop() else Snipe:Start() end
    end)
    pane.state = UI.Text(pane, "GameFontHighlight")
    pane.state:SetPoint("BOTTOMLEFT", 10, 60)
    pane.state:SetPoint("RIGHT", pane.toggle, "LEFT", -8, 0)

    -- One big button for the top deal, so a fresh deal needs no aiming.
    pane.buyNext = UI.Button(pane, "No deals", 120, 40)
    pane.buyNext:SetPoint("BOTTOMLEFT", 8, 8)
    pane.buyNext:SetPoint("RIGHT", -8, 0)
    pane.buyNext:SetNormalFontObject("GameFontNormalLarge")
    pane.buyNext:SetHighlightFontObject("GameFontHighlightLarge")
    pane.buyNext:SetDisabledFontObject("GameFontDisableLarge")
    pane.buyNext:SetScript("OnClick", function(self)
        if self.deal then Snipe:Buy(self.deal) end
    end)
    pane.buyNext:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Buy next deal", "Buys the top deal in the list")
    end)
    pane.buyNext:SetScript("OnLeave", GameTooltip_Hide)

    -- The deal it shows is kept for the click, so it buys what it says.
    function pane:UpdateBuyNext(deals)
        local deal = NextDeal(deals)
        self.buyNext.deal = deal
        if not deal then
            self.buyNext:SetText(Snipe.watching and "No deals yet" or "No deals")
            self.buyNext:Disable()
            return
        end
        local state, enabled = BuyState(deal)
        self.buyNext:SetText(BIG_WORDS[state]:format(DealWords(deal)))
        self.buyNext:SetEnabled(enabled)
    end

    -- "Watching 12 items, checked 2 s ago"; items without a max aren't checked.
    function pane:UpdateState()
        if not Snipe.watching then
            self.state:SetText("Not watching")
            return
        end
        local items, checked = Snipe:Items(), 0
        for _, itemID in ipairs(items) do
            if Snipe:Max(itemID) then checked = checked + 1 end
        end
        local text = checked < #items and ("Watching %d of %d items"):format(checked, #items)
            or ("Watching %d items"):format(checked)
        if Snipe.checkedAt then
            text = ("%s, checked %d s ago"):format(text, math.floor(GetTime() - Snipe.checkedAt))
        end
        self.state:SetText(text)
    end

    local sinceTick = 0
    pane:SetScript("OnUpdate", function(self, elapsed)
        sinceTick = sinceTick + elapsed
        if sinceTick < 1 then return end
        sinceTick = 0
        self:UpdateState()
    end)

    function pane:Refresh()
        if not self:IsVisible() then return end
        local deals = SortedDeals()
        self.scrollBox:SetDataProvider(CreateDataProvider(BuildElements(deals)), ScrollBoxConstants.RetainScrollPosition)
        local any = #Snipe:Items() > 0
        self.message:SetText(any and "" or "Tick Snipe in a list's menu to watch its items")
        if not self.cut:HasFocus() then self.cut:SetText(tostring(addon.db.snipe.cut)) end
        self.toggle:SetText(Snipe.watching and "Stop watching" or "Start watching")
        self.toggle:SetEnabled(Snipe.watching or (Auction.isOpen and any))
        self:UpdateBuyNext(deals)
        self:UpdateState()
    end

    pane:SetScript("OnShow", function(self) self:Refresh() end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
