-- The Prices tab: look up any item the addon has a price for by typing part
-- of its name, with or without the auction house open. Names come from the
-- client's item data, which loads on request, so results fill in as it does.
-- Each row has bars of the item's cheapest price per day over 30 days.

local _, addon = ...
local UI = addon.UI

local ROW_HEIGHT = 20
local SEARCH_DELAY = 0.15 -- seconds; typing and name loads are gathered
local YELLOW = { 1, 0.85, 0.2 }

local TREND_DAYS = 30
local BAR_WIDTH = 3
local BAR_BOTTOM = 3            -- the bars stand this far above the row's bottom
local BAR_LOW, BAR_HIGH = 2, 14 -- the heights of the cheapest and dearest day
local MIN_SPAN = 0.2            -- the scale spans at least this share of the average
local BAR_COLOR = { 0.8, 0.8, 0.8, 0.9 }

local COLUMNS = {
    { key = "price", label = "Price", width = 72, tip = "Cheapest auction last seen" },
    { key = "seen", label = "Seen", width = 56, tip = "How long ago that price was seen" },
    { key = "trend", label = "30 days", width = TREND_DAYS * BAR_WIDTH + 8,
      tip = "Each day's cheapest price, today at the right. Click for the price history." },
    { key = "vendor", label = "Vendor", width = 72, tip = "Bought from a vendor" },
}

local pane
local lowerNames = {} -- [itemID] = the name in lower case, once the client has it

--------------------------------------------------------------------------------
-- Searching
--------------------------------------------------------------------------------

-- Every item with an auction or vendor price, and everything on your lists.
local function Candidates()
    local ids, seen = {}, {}
    local function Add(itemID)
        if itemID and not seen[itemID] then
            seen[itemID] = true
            ids[#ids + 1] = itemID
        end
    end
    for itemID in pairs(addon.db.prices) do Add(itemID) end
    for itemID in pairs(addon.db.vendor) do Add(itemID) end
    for _, list in ipairs(addon.db.lists) do
        for _, itemID in ipairs(addon:ListItemIDs(list)) do Add(itemID) end
    end
    return ids
end

-- Items whose names contain the query, by name. A name the client doesn't
-- have yet is requested; its arrival redraws, and the search runs again.
local function Matches(query)
    local found = {}
    for _, itemID in ipairs(Candidates()) do
        local lower = lowerNames[itemID]
        if not lower then
            local name = addon:ItemName(itemID)
            if name then
                lower = name:lower()
                lowerNames[itemID] = lower
            end
        end
        if lower and lower:find(query, 1, true) then found[#found + 1] = itemID end
    end
    table.sort(found, function(a, b)
        local x, y = lowerNames[a], lowerNames[b]
        if x ~= y then return x < y end
        return a < b
    end)
    return found
end

local function CountPrices()
    local n = 0
    for _ in pairs(addon.db.prices) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function OnRowClick(row, button)
    local itemID = row.data and row.data.itemID
    if not itemID then return end
    if button == "RightButton" then
        addon:ShowItemMenu(row, itemID)
    elseif UI.ModifiedClick(itemID) then
        return
    elseif row.cells.trend:IsMouseOver() then
        addon:ShowHistory(itemID)
    else
        -- At the auction house the Buy tab shows it.
        addon:Select({ itemID = itemID }, "buy")
    end
end

local function OnRowEnter(row)
    local itemID = row.data and row.data.itemID
    if not itemID then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(itemID)
    GameTooltip:Show()
end

local function InitRow(row)
    if row.initialized then return end
    row.initialized = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints()
    row.selection:SetColorTexture(1, 0.82, 0, 0.18)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)

    row.cells = {}
    local right = -4
    for i = #COLUMNS, 1, -1 do
        local column = COLUMNS[i]
        local cell
        if column.key == "trend" then
            cell = CreateFrame("Frame", nil, row)
            cell:SetHeight(ROW_HEIGHT)
            cell.bars = {}
            local left = column.width - 4 - TREND_DAYS * BAR_WIDTH
            for day = 1, TREND_DAYS do
                local bar = cell:CreateTexture(nil, "ARTWORK")
                bar:SetWidth(BAR_WIDTH)
                bar:SetPoint("BOTTOMLEFT", left + (day - 1) * BAR_WIDTH, BAR_BOTTOM)
                bar:SetColorTexture(unpack(BAR_COLOR))
                cell.bars[day] = bar
            end
        else
            cell = UI.Text(row, nil, "RIGHT")
        end
        cell:SetWidth(column.width - 4)
        cell:SetPoint("RIGHT", right, 0)
        right = right - column.width
        row.cells[column.key] = cell
    end
    row.cells.vendor:SetTextColor(unpack(YELLOW))

    row.name = UI.Text(row)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.cells[COLUMNS[1].key], "LEFT", -4, 0)

    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
end

-- The scale spans at least a fifth of the average, so small swings look small.
local function DrawTrend(cell, itemID)
    local stats = addon:PriceStats(itemID, TREND_DAYS)
    if not stats then
        for _, bar in ipairs(cell.bars) do bar:Hide() end
        return
    end
    local span = math.max(stats.high - stats.low, stats.avg * MIN_SPAN)
    local base = (stats.low + stats.high - span) / 2
    for day, bar in ipairs(cell.bars) do
        local price = stats.byDay[day]
        if price then
            bar:SetHeight(BAR_LOW + (price - base) / span * (BAR_HIGH - BAR_LOW))
            bar:Show()
        else
            bar:Hide()
        end
    end
end

local function UpdateRow(row, data)
    InitRow(row)
    row.data = data
    local itemID = data.itemID
    row.icon:SetTexture(addon:ItemIcon(itemID))
    row.name:SetText(addon:ItemName(itemID) or "...")
    row.name:SetTextColor(addon:QualityColor(itemID))

    local price, seen = addon:GetAHPrice(itemID)
    local vendor = addon.db.vendor[itemID]
    row.cells.price:SetText(price and addon.Money(price) or "")
    row.cells.seen:SetText(seen and addon.Age(time() - seen) or "")
    row.cells.vendor:SetText(vendor and addon.Money(vendor) or "")
    DrawTrend(row.cells.trend, itemID)

    local selected = addon.selected
    row.selection:SetShown(selected ~= nil and selected.itemID == itemID)
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

-- Searches wait a moment, so fast typing and a burst of loaded names cost
-- one search, not one each.
local queued = false
local function QueueRefresh()
    if queued then return end
    queued = true
    C_Timer.After(SEARCH_DELAY, function()
        queued = false
        pane:Refresh()
    end)
end

function UI.CreatePricesPane(parent)
    pane = CreateFrame("Frame", nil, parent)

    pane.search = CreateFrame("EditBox", nil, pane, "SearchBoxTemplate")
    pane.search:SetPoint("TOPLEFT", 12, -4)
    pane.search:SetPoint("TOPRIGHT", -8, -4)
    pane.search:SetHeight(20)
    pane.search:SetAutoFocus(false)
    if pane.search.Instructions then pane.search.Instructions:SetText("Item name") end
    pane.search:HookScript("OnTextChanged", QueueRefresh)

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    pane.scrollBox:SetPoint("TOPLEFT", 4, -50)
    pane.scrollBox:SetPoint("BOTTOMRIGHT", -16, 4)
    pane.scrollBar:SetPoint("TOPLEFT", pane.scrollBox, "TOPRIGHT", 4, 0)
    pane.scrollBar:SetPoint("BOTTOMLEFT", pane.scrollBox, "BOTTOMRIGHT", 4, 0)

    pane.headers = CreateHeaders(pane)
    pane.headers:SetPoint("BOTTOMLEFT", pane.scrollBox, "TOPLEFT", 0, 4)
    pane.headers:SetPoint("BOTTOMRIGHT", pane.scrollBox, "TOPRIGHT", 0, 4)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetPoint("TOPLEFT", pane.scrollBox, "TOPLEFT", 0, -30)
    pane.message:SetPoint("TOPRIGHT", pane.scrollBox, "TOPRIGHT", 0, -30)

    function pane:Refresh()
        if not self:IsVisible() then return end
        local query = strtrim(self.search:GetText() or ""):lower()
        local elements = {}
        if query ~= "" then
            for _, itemID in ipairs(Matches(query)) do elements[#elements + 1] = { itemID = itemID } end
        end
        -- A new query starts at the top; a redraw of the same one keeps the place.
        local samePlace = query == self.query
        self.query = query
        self.scrollBox:SetDataProvider(CreateDataProvider(elements), samePlace)

        if query == "" then
            local count = CountPrices()
            self.message:SetText(count == 0 and "No prices yet; check prices at the auction house first"
                or ("Prices for %s items. Type part of a name to look one up."):format(BreakUpLargeNumbers(count)))
        elseif #elements == 0 then
            self.message:SetText("No item with a known price matches")
        else
            self.message:SetText("")
        end
    end

    pane:SetScript("OnShow", function(self) self:Refresh() end)
    -- Hidden, the box would otherwise keep the keyboard.
    pane:SetScript("OnHide", function(self) self.search:ClearFocus() end)
    addon:Listen("REFRESH", function()
        if pane:IsVisible() then QueueRefresh() end
    end)

    return pane
end
