-- The Sales tab: every sale, newest first, with what it brought in after
-- the house's cut and, for your crafts, the profit; income totals below.
-- Sales come from the mail as you take the gold (Sales.lua).

local _, addon = ...
local UI = addon.UI

local ROW_HEIGHT = 20
local GREEN = { 0.25, 0.9, 0.25 }
local RED = { 1, 0.3, 0.3 }

local COLUMNS = {
    { key = "when", label = "When", width = 56, tip = "When you took the gold" },
    { key = "count", label = "Sold", width = 44, tip = "How many" },
    { key = "income", label = "Income", width = 80, tip = "The sale after the house's cut" },
    { key = "profit", label = "Profit", width = 80, tip = "Income less the craft cost when sold" },
}

local pane

local function Income(sale)
    return sale.price - sale.cut
end

-- Nil for items you don't craft, or whose cost wasn't known when sold.
local function Profit(sale)
    if sale.cost then return Income(sale) - sale.cost * sale.count end
end

-- Income since midnight, over the last 7 days and over the last 30.
local function Totals()
    local now = time()
    local day = date("*t", now)
    day.hour, day.min, day.sec = 0, 0, 0
    local midnight = time(day)
    local today, week, month = 0, 0, 0
    for _, sale in ipairs(addon.db.sales) do
        local income = Income(sale)
        if sale.t >= midnight then today = today + income end
        if now - sale.t <= 7 * 86400 then week = week + income end
        if now - sale.t <= 30 * 86400 then month = month + income end
    end
    return today, week, month
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function OnRowClick(row, button)
    local itemID = row.data and row.data.itemID
    if not itemID then return end
    if button == "RightButton" then
        addon:ShowItemMenu(row, itemID)
    elseif not UI.ModifiedClick(itemID) then
        addon:Select({ itemID = itemID })
    end
end

local function OnRowEnter(row)
    local sale = row.data
    if not sale then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if sale.itemID then
        GameTooltip:SetItemByID(sale.itemID)
    else
        GameTooltip:SetText(sale.name)
    end
    local r, g, b = 1, 0.82, 0
    GameTooltip:AddDoubleLine("Sold for", addon.Money(sale.price, true), r, g, b, 1, 1, 1)
    GameTooltip:AddDoubleLine("House cut", addon.Money(sale.cut, true), r, g, b, 1, 1, 1)
    if sale.cost then
        GameTooltip:AddDoubleLine("Craft cost", addon.Money(sale.cost * sale.count, true), r, g, b, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Seller", sale.char, r, g, b, 1, 1, 1)
    GameTooltip:AddLine(date("%Y-%m-%d %H:%M", sale.t), 0.6, 0.6, 0.6)
    GameTooltip:Show()
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
    local right = -4
    for i = #COLUMNS, 1, -1 do
        local column = COLUMNS[i]
        local cell = UI.Text(row, nil, "RIGHT")
        cell:SetWidth(column.width - 4)
        cell:SetPoint("RIGHT", right, 0)
        right = right - column.width
        row.cells[column.key] = cell
    end

    row.name = UI.Text(row)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.cells[COLUMNS[1].key], "LEFT", -4, 0)

    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
end

local function UpdateRow(row, sale)
    InitRow(row)
    row.data = sale
    row.icon:SetTexture(addon:ItemIcon(sale.itemID))
    row.name:SetText(sale.itemID and addon:ItemName(sale.itemID) or sale.name)
    row.name:SetTextColor(addon:QualityColor(sale.itemID))
    row.cells.when:SetText(addon.Age(time() - sale.t))
    row.cells.count:SetText(sale.count)
    row.cells.income:SetText(addon.Money(Income(sale)))
    local profit = Profit(sale)
    row.cells.profit:SetText(profit and addon.Money(profit) or "")
    if profit then row.cells.profit:SetTextColor(unpack(profit >= 0 and GREEN or RED)) end
end

local function CreateHeaders(parent)
    local headers = CreateFrame("Frame", nil, parent)
    headers:SetHeight(18)
    local right = -4
    for i = #COLUMNS, 1, -1 do
        local column = COLUMNS[i]
        local header = CreateFrame("Frame", nil, headers)
        header:SetSize(column.width, 18)
        header:SetPoint("RIGHT", right, 0)
        right = right - column.width
        local label = UI.Text(header, "GameFontNormalSmall", "RIGHT")
        label:SetPoint("RIGHT")
        label:SetText(column.label)
        header:EnableMouse(true)
        header:SetScript("OnEnter", function(self) UI.Tooltip(self, column.label, column.tip) end)
        header:SetScript("OnLeave", GameTooltip_Hide)
    end
    local item = UI.Text(headers, "GameFontNormalSmall")
    item:SetPoint("LEFT", 4, 0)
    item:SetText("Item")
    return headers
end

--------------------------------------------------------------------------------
-- The pane
--------------------------------------------------------------------------------

function UI.CreateSalesPane(parent)
    pane = CreateFrame("Frame", nil, parent)

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    UI.PlaceScrollList(pane.scrollBox, pane.scrollBar, -26, 40)

    pane.headers = CreateHeaders(pane)
    pane.headers:SetPoint("BOTTOMLEFT", pane.scrollBox, "TOPLEFT", 0, 4)
    pane.headers:SetPoint("BOTTOMRIGHT", pane.scrollBox, "TOPRIGHT", 0, 4)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetWordWrap(true)
    pane.message:SetPoint("TOPLEFT", pane.scrollBox, "TOPLEFT", 0, -30)
    pane.message:SetPoint("TOPRIGHT", pane.scrollBox, "TOPRIGHT", 0, -30)

    -- The income line sits under the list, level with the Lists tab's buttons.
    pane.totals = UI.Text(pane, "GameFontHighlight")
    pane.totals:SetPoint("LEFT", pane, "BOTTOMLEFT", 12, 21)
    pane.totals:SetPoint("RIGHT", pane, "BOTTOMRIGHT", -8, 21)

    -- The whole log is gone through only when the tab opens and after a
    -- sale. Other redraws touch just the rows in view, and the scroll list
    -- only ever makes frames for those, so a long log stays quick.
    function pane:Rebuild()
        local sales, saved = {}, addon.db.sales
        for i = #saved, 1, -1 do sales[#sales + 1] = saved[i] end
        self.scrollBox:SetDataProvider(CreateDataProvider(sales), ScrollBoxConstants.RetainScrollPosition)

        local today, week, month = Totals()
        self.totals:SetText(("Income today %s, last 7 days %s, last 30 days %s"):format(
            addon.Money(today), addon.Money(week), addon.Money(month)))
        self.message:SetText(#sales == 0
            and "No sales yet. Each sale is saved when you take the gold from its \"Auction successful\" mail."
            or "")
    end

    function pane:Refresh()
        if not self:IsVisible() then return end
        self.scrollBox:ForEachFrame(function(row)
            if row.data then UpdateRow(row, row.data) end
        end)
    end

    pane:SetScript("OnShow", function(self) self:Rebuild() end)
    addon:Listen("REFRESH", function() pane:Refresh() end)
    addon:Listen("SALES", function()
        if pane:IsVisible() then pane:Rebuild() end
    end)

    return pane
end
