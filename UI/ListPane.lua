-- The left side of the window: every list as a section you can fold, its
-- crafts and items as rows of numbers, and reagents under each craft, shown
-- by clicking it. Right-click a row for its actions; drag rows to reorder
-- them; drop an item from your bags to add it.

local _, addon = ...
local UI = addon.UI

local ROW_HEIGHT = 20
-- A list's entries start under its title's text, reagents a step further.
local INDENT = 18
local PLUS = "Interface\\Buttons\\UI-PlusButton-Up"
local MINUS = "Interface\\Buttons\\UI-MinusButton-Up"

local WHITE = { 1, 1, 1 }
local GRAY = { 0.5, 0.5, 0.5 }
local GREEN = { 0.25, 0.9, 0.25 }
local RED = { 1, 0.3, 0.3 }

local COLUMNS = {
    { key = "have", label = "Have", width = 50, tip = "In your bags. Reagents of a planned craft: in bags / needed" },
    { key = "listed", label = "Listed", width = 42, tip = "On the auction house, all your characters, as of today's visits" },
    { key = "craft", label = "Craft", width = 40, tip = "Crafts the reagents in your bags allow" },
    { key = "cost", label = "Cost", width = 64, tip = "Craft cost per item; gray if a reagent has no price yet" },
    { key = "price", label = "Price", width = 64, tip = "Cheapest auction last seen; for a reagent, a vendor's price when lower" },
    { key = "profit", label = "Profit", width = 64, tip = "Price minus the 5% cut and the cost" },
}

local pane

--------------------------------------------------------------------------------
-- Numbers per row
--------------------------------------------------------------------------------

local function EntryValues(entry)
    local values = {}
    if entry.itemID then
        values.have = addon:BagCount(entry.itemID)
        values.listed = addon:ListedCount(entry.itemID)
        values.price = addon:GetAHPrice(entry.itemID)
    end
    if entry.recipeID then
        values.craft = addon:CraftableCount(entry)
        values.cost, values.complete = addon:CraftCost(entry)
        values.profit = addon:Profit(entry)
    end
    return values
end

-- A column sort orders the rows inside each list, for display only.
local function SortedEntries(list)
    if not pane.sortKey then return list.entries end
    local sorted, values = {}, {}
    for i, entry in ipairs(list.entries) do
        sorted[i] = entry
        values[entry] = EntryValues(entry)[pane.sortKey]
    end
    table.sort(sorted, function(a, b)
        local x, y = values[a], values[b]
        if x == nil then return false end
        if y == nil then return true end
        if pane.sortDesc then return x > y end
        return x < y
    end)
    return sorted
end

local function BuildElements()
    local elements = {}
    for _, list in ipairs(addon.db.lists) do
        elements[#elements + 1] = { kind = "list", list = list }
        if not list.collapsed then
            for _, entry in ipairs(SortedEntries(list)) do
                elements[#elements + 1] = { kind = "entry", list = list, entry = entry, itemID = entry.itemID }
                if entry.expanded then
                    for _, reagent in ipairs(entry.reagents or {}) do
                        elements[#elements + 1] = {
                            kind = "reagent", list = list, entry = entry, reagent = reagent, itemID = reagent.itemID,
                        }
                    end
                end
            end
        end
    end
    elements[#elements + 1] = { kind = "new" }
    if #addon.db.lists == 0 then elements[#elements + 1] = { kind = "hint" } end
    return elements
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function Selection(data)
    return { itemID = data.itemID, list = data.list, entry = data.entry, reagent = data.reagent }
end

local function IsSelected(data)
    local selected = addon.selected
    if not selected then return false end
    if data.kind == "entry" then return selected.entry == data.entry and not selected.reagent end
    if data.kind == "reagent" then return selected.reagent == data.reagent end
    return false
end

local function Toggle(data)
    if data.kind == "list" then
        data.list.collapsed = not data.list.collapsed or nil
    elseif data.entry then
        data.entry.expanded = not data.entry.expanded or nil
    end
    addon:Refresh()
end

-- An item held on the cursor goes on the list it is dropped on.
local function DropCursorItem(data)
    local kind, itemID = GetCursorInfo()
    if kind ~= "item" or not itemID then return false end
    ClearCursor()
    local list = (data and data.list) or (addon.selected and addon.selected.list) or addon.db.lists[1]
        or addon:NewList("New list")
    UI.AddToList(list, itemID)
    return true
end

local function NewListPrompt()
    addon:Prompt("Name of the new list:", "", function(name) addon:NewList(name) end)
end

local function HasStoredAmounts(list)
    for _, entry in ipairs(list.entries) do
        if entry.recipeID and entry.amount then return true end
    end
    return false
end

-- Opens or closes the reagents of every craft on a list; opening them also
-- opens the list.
local function SetAllExpanded(list, expanded)
    if expanded then list.collapsed = nil end
    for _, entry in ipairs(list.entries) do
        if entry.reagents and #entry.reagents > 0 then entry.expanded = expanded or nil end
    end
    addon:Refresh()
end

local function ListMenu(root, list)
    local open, closed = 0, 0
    for _, entry in ipairs(list.entries) do
        if entry.reagents and #entry.reagents > 0 then
            if entry.expanded then open = open + 1 else closed = closed + 1 end
        end
    end
    root:CreateTitle(list.name)
    root:CreateButton("Expand all", function() SetAllExpanded(list, true) end)
        :SetEnabled(closed > 0 or (list.collapsed and open > 0) or false)
    root:CreateButton("Collapse all", function() SetAllExpanded(list, false) end):SetEnabled(open > 0)
    root:CreateButton("Check prices", function()
        addon.Auction:ScanPrices(addon:ListItemIDs(list), list.name)
    end):SetEnabled(addon.Auction.isOpen and not addon.Auction:IsScanning())
    -- Each craft with a stored amount goes into the queue at that amount.
    root:CreateButton("Plan all stored amounts", function()
        addon:SetStatus(("%s: %d crafts planned"):format(list.name, addon:PlanList(list)))
    end):SetEnabled(HasStoredAmounts(list))
    root:CreateButton("Rename...", function()
        addon:Prompt(("New name for %s:"):format(list.name), list.name, function(name)
            addon:RenameList(list, name)
        end)
    end)
    root:CreateButton("Delete...", function()
        addon:Confirm(("Delete the list %s and its %d entries?"):format(list.name, #list.entries), function()
            addon:DeleteList(list)
        end)
    end)
end

-- "Craft 10", or "Craft 6 of 10" when your bags fall short of the plan.
-- The Queue tab uses it too.
function UI.CraftLabel(count, planned)
    if count < planned then return ("Craft %d of %d"):format(count, planned) end
    return ("Craft %d"):format(count)
end

-- Asks for the amount Plan sets and stores it; after(amount) runs once one
-- is stored.
local function PromptAmount(entry, after)
    local default = entry.amount or math.max(addon:Planned(entry), 1)
    addon:Prompt(("Crafts to plan each time for %s (0 clears it):"):format(addon:EntryName(entry)),
        tostring(default), function(text)
            local n = tonumber(text)
            if not n or n < 0 then return end
            addon:SetPlanAmount(entry, n)
            if after and entry.amount then after(entry.amount) end
        end)
end

-- A craft's plan buttons, in its menu here and in the Queue tab. Plan sets
-- the plan to the stored amount at once; with none stored yet, it asks for
-- one first.
function UI.AddPlanButtons(root, entry)
    local amount = entry.amount
    if amount then
        root:CreateButton(("Plan %d"):format(amount), function() addon:SetPlanned(entry, amount) end)
    else
        root:CreateButton("Plan...", function()
            PromptAmount(entry, function(n) addon:SetPlanned(entry, n) end)
        end)
    end
    root:CreateButton("Plan amount...", function() PromptAmount(entry) end)
    if addon:Planned(entry) > 0 then
        root:CreateButton("Remove from queue", function() addon:SetPlanned(entry, 0) end)
    end
end

local function EntryMenu(root, data)
    local entry, itemID, isOpen = data.entry, data.itemID, addon.Auction.isOpen
    root:CreateTitle(addon:EntryName(entry))
    if itemID then
        root:CreateButton("Search", function()
            addon:Select(Selection(data), "buy")
            addon.Auction:Search(itemID)
        end):SetEnabled(isOpen)
        root:CreateButton("Sell", function() addon:Select(Selection(data), "sell") end)
            :SetEnabled(isOpen and addon:BagCount(itemID) > 0)
        root:CreateButton("Price history", function() addon:ShowHistory(itemID) end)
    end
    if entry.recipeID then
        local can, why = addon.Prof:CraftState(entry)
        local count, planned = addon:CraftBatch(entry)
        root:CreateButton(can and UI.CraftLabel(count, planned) or ("Craft: %s"):format(why), function()
            addon.Prof:Craft(entry, count)
        end):SetEnabled(can and count > 0)
        if can then
            local all = addon:CraftableCount(entry) or 0
            root:CreateButton(("Craft all (%d)"):format(all), function() addon.Prof:Craft(entry, all) end)
                :SetEnabled(all > 0)
        end
        UI.AddPlanButtons(root, entry)
    end
    if #addon.db.lists > 1 then
        local move = root:CreateButton("Move to list")
        for _, list in ipairs(addon.db.lists) do
            if list ~= data.list then
                move:CreateButton(list.name, function() addon:MoveEntryToList(entry, data.list, list) end)
            end
        end
    end
    root:CreateButton("Remove", function() addon:RemoveEntry(data.list, entry) end)
end

local function ReagentMenu(root, data)
    local itemID = data.itemID
    root:CreateTitle(addon:ItemName(itemID) or "")
    root:CreateButton("Search", function()
        addon:Select(Selection(data), "buy")
        addon.Auction:Search(itemID)
    end):SetEnabled(addon.Auction.isOpen)
    root:CreateButton("Price history", function() addon:ShowHistory(itemID) end)
    local add = root:CreateButton("Add to list")
    for _, list in ipairs(addon.db.lists) do
        add:CreateButton(list.name, function() addon:AddItem(list, itemID) end)
    end
    if addon.db.vendor[itemID] then
        root:CreateButton("Forget vendor price", function() addon:ForgetVendorPrice(itemID) end)
    end
end

local function ShowMenu(row, data)
    MenuUtil.CreateContextMenu(row, function(_, root)
        if data.kind == "list" then
            ListMenu(root, data.list)
        elseif data.kind == "entry" then
            EntryMenu(root, data)
        else
            ReagentMenu(root, data)
        end
    end)
end

--------------------------------------------------------------------------------
-- Dragging rows
--------------------------------------------------------------------------------

local function RowUnderCursor()
    local found
    pane.scrollBox:ForEachFrame(function(frame)
        if frame:IsMouseOver() then found = frame end
    end)
    return found
end

-- Rows are rebuilt on every redraw, so a row is matched by what it shows.
local function SameRow(a, b)
    return a.kind == b.kind and a.list == b.list and a.entry == b.entry and a.reagent == b.reagent
end

local function OnDragStart(row)
    local data = row.data
    if not data or (data.kind ~= "entry" and data.kind ~= "list") then return end
    if data.kind == "entry" and pane.sortKey then
        addon:SetStatus("Clear the column sort to reorder")
        return
    end
    pane.dragging = data
end

local function OnDragStop()
    local dragged = pane.dragging
    pane.dragging = nil
    pane.scrollBox:ForEachFrame(function(frame) frame.dropLine:Hide() end)
    local frame = RowUnderCursor()
    local target = frame and frame.data
    if not dragged or not target or not target.list then return end

    -- The drop line marks the top of the target row, so a row dragged down
    -- lands above it: one place less once the row has left its old spot.
    local function Landing(from, to)
        if from < to then return to - 1 end
        return to
    end

    if dragged.kind == "list" then
        local from, to = tIndexOf(addon.db.lists, dragged.list), tIndexOf(addon.db.lists, target.list)
        if from and to then addon:MoveList(from, Landing(from, to)) end
        return
    end

    -- An entry goes above the row it lands on, in that row's list; dropped
    -- on a list's title it goes to the top.
    local entry, toList = dragged.entry, target.list
    if target.entry == entry then return end
    addon:MoveEntryToList(entry, dragged.list, toList)
    local from = tIndexOf(toList.entries, entry)
    local to = target.entry and tIndexOf(toList.entries, target.entry) or 1
    if from and to then addon:MoveEntry(toList, from, Landing(from, to)) end
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function SetCell(row, key, text, color)
    local cell = row.cells[key]
    cell:SetText(text or "")
    cell:SetTextColor(unpack(color or WHITE))
end

local function SetCount(row, key, n)
    if n then SetCell(row, key, BreakUpLargeNumbers(n), n == 0 and GRAY or WHITE) end
end

local function OnRowClick(row, button)
    local data = row.data
    if not data or DropCursorItem(data) then return end
    if data.kind == "new" then
        NewListPrompt()
    elseif data.kind == "hint" then
        return
    elseif button == "RightButton" then
        ShowMenu(row, data)
    elseif data.kind == "list" then
        Toggle(data)
    elseif not UI.ModifiedClick(data.itemID) then
        addon:Select(Selection(data))
        -- A click on a craft also opens or closes its reagents.
        local reagents = data.kind == "entry" and data.entry.reagents
        if reagents and #reagents > 0 then Toggle(data) end
    end
end

local function OnRowEnter(row)
    local data = row.data
    if not data or not data.entry then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if data.itemID then
        GameTooltip:SetItemByID(data.itemID)
    else
        GameTooltip:SetText(addon:EntryName(data.entry))
    end
    local entry = data.kind == "entry" and data.entry
    if entry and entry.recipeID then
        if not entry.itemID then
            local cost = addon:CraftCost(entry)
            if cost then GameTooltip:AddDoubleLine("Cost per craft", addon.Money(cost), 1, 0.82, 0, 1, 1, 1) end
        end
        if (entry.yield or 1) ~= 1 then
            GameTooltip:AddLine(("Makes %s per craft"):format(entry.yield), 1, 1, 1)
        end
        local planned = addon:Planned(entry)
        if planned > 0 then GameTooltip:AddLine(("Planned: %d crafts"):format(planned), 1, 1, 1) end
        if entry.amount then GameTooltip:AddLine(("Plan amount: %d"):format(entry.amount), 1, 1, 1) end
    end
    GameTooltip:Show()
end

local function InitRow(row)
    if row.initialized then return end
    row.initialized = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:RegisterForDrag("LeftButton")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.tint = row:CreateTexture(nil, "BACKGROUND")
    row.tint:SetAllPoints()
    row.tint:SetColorTexture(1, 1, 1, 0.05)
    row.selection = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.selection:SetAllPoints()
    row.selection:SetColorTexture(1, 0.82, 0, 0.18)
    row.dropLine = row:CreateTexture(nil, "OVERLAY")
    row.dropLine:SetColorTexture(1, 0.82, 0, 1)
    row.dropLine:SetHeight(2)
    row.dropLine:SetPoint("TOPLEFT")
    row.dropLine:SetPoint("TOPRIGHT")

    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetSize(14, 14)
    row.toggle:SetScript("OnClick", function() Toggle(row.data) end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)

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

    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnDragStart", OnDragStart)
    row:SetScript("OnDragStop", OnDragStop)
    row:SetScript("OnReceiveDrag", function(self) DropCursorItem(self.data) end)
end

local function UpdateRow(row, data)
    InitRow(row)
    row.data = data
    local kind, entry = data.kind, data.entry
    row.toggle:Hide()
    row.icon:Hide()
    row.dropLine:Hide()
    row.tint:SetShown(kind == "reagent")
    row.selection:SetShown(IsSelected(data))
    for _, cell in pairs(row.cells) do cell:SetText("") end
    row.name:ClearAllPoints()
    row.name:SetFontObject("GameFontHighlightSmall")
    row.name:SetTextColor(1, 1, 1)

    if kind == "list" then
        row.toggle:SetNormalTexture(data.list.collapsed and PLUS or MINUS)
        row.toggle:SetPoint("LEFT", 4, 0)
        row.toggle:Show()
        row.name:SetFontObject("GameFontNormal")
        row.name:SetPoint("LEFT", row.toggle, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", -4, 0)
        row.name:SetText(("%s  |cff808080%d|r"):format(data.list.name, #data.list.entries))
        return
    end

    if kind == "new" or kind == "hint" then
        row.name:SetFontObject("GameFontDisableSmall")
        row.name:SetPoint("LEFT", 22, 0)
        row.name:SetPoint("RIGHT", -4, 0)
        row.name:SetText(kind == "new" and "+ New list"
            or "Drag items here, or use Add to list in a profession window")
        return
    end

    local left = kind == "reagent" and 2 * INDENT or INDENT
    row.icon:SetPoint("LEFT", left + 4, 0)
    row.icon:Show()
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.cells.have, "LEFT", -4, 0)

    if kind == "entry" then
        local values = EntryValues(entry)
        row.icon:SetTexture(addon:EntryIcon(entry))
        row.name:SetText(addon:EntryName(entry))
        row.name:SetTextColor(addon:QualityColor(entry.itemID))
        SetCount(row, "have", values.have)
        SetCount(row, "listed", values.listed)
        SetCount(row, "craft", values.craft)
        if values.cost then SetCell(row, "cost", addon.Money(values.cost), values.complete and WHITE or GRAY) end
        if values.price then SetCell(row, "price", addon.Money(values.price)) end
        if values.profit then SetCell(row, "profit", addon.Money(values.profit), values.profit >= 0 and GREEN or RED) end
        return
    end

    -- A reagent: have against what the planned crafts need (just have when
    -- none is planned), its buy price, and its craft cost when another entry
    -- makes it.
    local reagent = data.reagent
    row.icon:SetTexture(addon:ItemIcon(reagent.itemID))
    row.name:SetText(("%dx %s"):format(reagent.count, addon:ItemName(reagent.itemID) or "..."))
    row.name:SetTextColor(addon:QualityColor(reagent.itemID))
    local have, planned = addon:BagCount(reagent.itemID), addon:Planned(entry)
    if planned > 0 then
        local need = reagent.count * planned
        SetCell(row, "have", ("%d/%d"):format(have, need), have >= need and GREEN or RED)
    else
        SetCount(row, "have", have)
    end
    local price = addon:BuyPrice(reagent.itemID)
    if price then SetCell(row, "price", addon.Money(price)) end
    local craft = addon:Index().crafts[reagent.itemID]
    if craft and craft ~= entry then
        local cost, complete = addon:CraftCost(craft)
        if cost then SetCell(row, "cost", addon.Money(cost), complete and WHITE or GRAY) end
    end
end

--------------------------------------------------------------------------------
-- Column headers
--------------------------------------------------------------------------------

local function UpdateHeaders()
    for _, column in ipairs(COLUMNS) do
        local button = pane.headers[column.key]
        local active = pane.sortKey == column.key
        button.arrow:SetShown(active)
        button.arrow:SetRotation(active and not pane.sortDesc and math.pi or 0)
        button.label:SetFontObject(active and "GameFontHighlightSmall" or "GameFontNormalSmall")
    end
end

-- Each click on a column: highest first, lowest first, back to your order.
local function CycleSort(key)
    if pane.sortKey ~= key then
        pane.sortKey, pane.sortDesc = key, true
    elseif pane.sortDesc then
        pane.sortDesc = false
    else
        pane.sortKey = nil
    end
    UpdateHeaders()
    addon:Refresh()
end

local function CreateHeaders(parent)
    local headers = CreateFrame("Frame", nil, parent)
    headers:SetHeight(18)
    local right = -4
    for i = #COLUMNS, 1, -1 do
        local column = COLUMNS[i]
        local button = CreateFrame("Button", nil, headers)
        button:SetSize(column.width, 18)
        button:SetPoint("RIGHT", right, 0)
        right = right - column.width
        button.label = UI.Text(button, "GameFontNormalSmall", "RIGHT")
        button.label:SetPoint("RIGHT")
        button.label:SetText(column.label)
        button.arrow = button:CreateTexture(nil, "OVERLAY")
        button.arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
        button.arrow:SetPoint("RIGHT", button.label, "LEFT", -2, 0)
        button.arrow:Hide()
        button:SetScript("OnClick", function() CycleSort(column.key) end)
        button:SetScript("OnEnter", function(self) UI.Tooltip(self, column.label, column.tip) end)
        button:SetScript("OnLeave", GameTooltip_Hide)
        headers[column.key] = button
    end
    local item = UI.Text(headers, "GameFontNormalSmall")
    item:SetPoint("LEFT", INDENT + 4, 0)
    item:SetText("Item")
    return headers
end

--------------------------------------------------------------------------------
-- The pane
--------------------------------------------------------------------------------

-- The house allows one full scan per 15 minutes; the button counts down.
local function UpdateScanAll()
    local wait = addon.Auction:FullScanWait()
    local text = wait > 0 and ("Scan everything (%d min)"):format(math.ceil(wait / 60)) or "Scan everything"
    if pane.scanAll:GetText() ~= text then pane.scanAll:SetText(text) end
    pane.scanAll:SetEnabled(addon.Auction.isOpen and wait == 0)
end

-- The Craft button works on the selected craft row, as its menu does.
local function SelectedCraft()
    local selected = addon.selected
    local entry = selected and not selected.reagent and selected.entry
    if entry and entry.recipeID then return entry end
end

-- Whether the selected craft can go now, how many of how many planned; if
-- not, why, and the spell that opens its profession when that would do.
local function CraftButtonState()
    local entry = SelectedCraft()
    if not entry then return false, 0, 0, "Select a craft in your list" end
    local can, why, spell = addon.Prof:CraftState(entry)
    local count, planned = addon:CraftBatch(entry)
    if not can then return false, count, planned, (why:gsub("^%l", string.upper)), spell end
    if count == 0 then return false, 0, planned, "Not enough reagents in your bags" end
    return true, count, planned
end

-- Craft opens the profession while its window is closed; Craft all crafts
-- everything the bags allow, plan or not.
local function UpdateCraft()
    local entry = SelectedCraft()
    local can, count, planned, _, spell = CraftButtonState()
    pane.craft:SetOpens(not can and spell or nil)
    pane.craft:SetText(can and UI.CraftLabel(count, planned) or spell and ("Open " .. entry.prof) or "Craft")
    pane.craft:SetEnabled(can or spell ~= nil)
    local all = can and addon:CraftableCount(entry) or 0
    pane.craftAll:SetText(all > 0 and ("Craft all (%d)"):format(all) or "Craft all")
    pane.craftAll:SetEnabled(all > 0)
end

function UI.CreateListPane(parent)
    pane = CreateFrame("Frame", nil, parent)

    -- The buttons sit level with the Buy and Sell buttons on the right.
    pane.check = UI.Button(pane, "Check prices", 110, 26)
    pane.check:SetPoint("BOTTOMLEFT", 8, 8)
    pane.check:SetScript("OnClick", function()
        local ids = {}
        for _, list in ipairs(addon.db.lists) do addon:ListItemIDs(list, ids) end
        addon.Auction:ScanPrices(ids, "all lists")
    end)
    pane.check:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Check prices", "Prices every item and reagent on your lists, 50 per request")
    end)
    pane.check:SetScript("OnLeave", GameTooltip_Hide)
    pane.check:SetMotionScriptsWhileDisabled(true)

    pane.scanAll = UI.Button(pane, "Scan everything", 170, 26)
    pane.scanAll:SetPoint("LEFT", pane.check, "RIGHT", 6, 0)
    pane.scanAll:SetScript("OnClick", function() addon.Auction:FullScan() end)
    pane.scanAll:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Scan everything", "Prices every item on the auction house in one go; allowed once per 15 minutes")
    end)
    pane.scanAll:SetScript("OnLeave", GameTooltip_Hide)
    pane.scanAll:SetMotionScriptsWhileDisabled(true)

    pane.craft = UI.CraftButton(pane, 120, function()
        local entry = SelectedCraft()
        if entry then addon.Prof:Craft(entry, (addon:CraftBatch(entry))) end
    end)
    pane.craft:SetPoint("LEFT", pane.scanAll, "RIGHT", 6, 0)
    pane.craft:SetScript("OnEnter", function(self)
        local entry = SelectedCraft()
        local can, count, planned, why, spell = CraftButtonState()
        if can then
            why = count < planned and ("Your bags have reagents for %d of the %d planned"):format(count, planned)
                or planned == 0 and "One craft, since none is planned; plan more in the craft's menu"
                or "Each finished craft takes one off the plan"
        elseif spell then
            why = ("Opens %s"):format(entry.prof)
        end
        UI.Tooltip(self, entry and addon:EntryName(entry) or "Craft", why)
    end)
    pane.craft:SetScript("OnLeave", GameTooltip_Hide)
    pane.craft:SetMotionScriptsWhileDisabled(true)

    pane.craftAll = UI.Button(pane, "Craft all", 104, 26)
    pane.craftAll:SetPoint("LEFT", pane.craft, "RIGHT", 6, 0)
    pane.craftAll:SetScript("OnClick", function()
        local entry = SelectedCraft()
        if entry then addon.Prof:Craft(entry, addon:CraftableCount(entry) or 0) end
    end)
    pane.craftAll:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Craft all", "As many as the reagents in your bags allow, plan or not")
    end)
    pane.craftAll:SetScript("OnLeave", GameTooltip_Hide)
    pane.craftAll:SetMotionScriptsWhileDisabled(true)

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    pane.scrollBox:SetPoint("TOPLEFT", 4, -26)
    pane.scrollBox:SetPoint("BOTTOMRIGHT", -16, 40)
    pane.scrollBar:SetPoint("TOPLEFT", pane.scrollBox, "TOPRIGHT", 4, 0)
    pane.scrollBar:SetPoint("BOTTOMLEFT", pane.scrollBox, "BOTTOMRIGHT", 4, 0)

    pane.headers = CreateHeaders(pane)
    pane.headers:SetPoint("BOTTOMLEFT", pane.scrollBox, "TOPLEFT", 0, 4)
    pane.headers:SetPoint("BOTTOMRIGHT", pane.scrollBox, "TOPRIGHT", 0, 4)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    -- Items dropped on the empty space under the rows.
    local dropZone = CreateFrame("Frame", nil, pane)
    dropZone:SetAllPoints(pane.scrollBox)
    dropZone:SetFrameLevel(math.max(0, pane.scrollBox:GetFrameLevel() - 1))
    dropZone:EnableMouse(true)
    dropZone:SetScript("OnReceiveDrag", function() DropCursorItem(nil) end)
    dropZone:SetScript("OnMouseUp", function() DropCursorItem(nil) end)

    -- The full scan's countdown ticks once a second. While dragging a row, a
    -- line marks where it will land.
    local sinceTick = 0
    pane:SetScript("OnUpdate", function(_, elapsed)
        sinceTick = sinceTick + elapsed
        if sinceTick >= 1 then
            sinceTick = 0
            UpdateScanAll()
        end
        if not pane.dragging then return end
        local over = RowUnderCursor()
        pane.scrollBox:ForEachFrame(function(frame)
            frame.dropLine:SetShown(frame == over and frame.data.list ~= nil
                and not SameRow(frame.data, pane.dragging))
        end)
    end)

    function pane:Refresh()
        if not self:IsVisible() then return end
        self.check:SetEnabled(addon.Auction.isOpen and not addon.Auction:IsScanning())
        UpdateScanAll()
        UpdateCraft()
        self.scrollBox:SetDataProvider(CreateDataProvider(BuildElements()), ScrollBoxConstants.RetainScrollPosition)
    end

    pane:SetScript("OnShow", function(self) self:Refresh() end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
