-- The Queue tab: every craft with a plan, in the order of your lists, and a
-- button that crafts them one after another. The game wants a click for each
-- batch, so each press starts one; plans count down as crafts finish.

local _, addon = ...
local UI = addon.UI

local ROW_HEIGHT = 20
local GRAY = { 0.5, 0.5, 0.5 }
local GREEN = { 0.25, 0.9, 0.25 }
local RED = { 1, 0.3, 0.3 }

local COLUMNS = {
    { key = "status", label = "Status", width = 150, justify = "LEFT", tip = "Ready, or what holds the craft back" },
    { key = "plan", label = "Plan", width = 44, tip = "Crafts still planned; each finished craft takes one off" },
    { key = "craft", label = "Craft", width = 44, tip = "Crafts the reagents in your bags allow" },
}

local pane

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

-- Ready, or what holds a queued craft back, and its color.
local function Status(entry, craftable)
    local can, why = addon.Prof:CraftState(entry)
    if not can then return (why:gsub("^%l", string.upper)), GRAY end
    if craftable == 0 then return "Missing reagents", RED end
    return "Ready", GREEN
end

local function ShowMenu(row, entry)
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(addon:EntryName(entry))
        local can, why = addon.Prof:CraftState(entry)
        local count, planned = addon:CraftBatch(entry)
        root:CreateButton(can and UI.CraftLabel(count, planned) or ("Craft: %s"):format(why), function()
            addon.Prof:Craft(entry, count)
        end):SetEnabled(can and count > 0)
        UI.AddPlanButtons(root, entry)
    end)
end

local function OnRowClick(row, button)
    local data = row.data
    if not data then return end
    local entry = data.entry
    if button == "RightButton" then
        ShowMenu(row, entry)
    elseif not UI.ModifiedClick(entry.itemID) then
        -- Selected here as in Lists, so the Craft button there and the
        -- right-hand tabs show it too.
        addon:Select({ itemID = entry.itemID, list = data.list, entry = entry })
    end
end

local function OnRowEnter(row)
    local data = row.data
    if not data then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if data.entry.itemID then
        GameTooltip:SetItemByID(data.entry.itemID)
    else
        GameTooltip:SetText(addon:EntryName(data.entry))
    end
    GameTooltip:AddLine(("On %s"):format(data.list.name), 1, 1, 1)
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
        local cell = UI.Text(row, nil, column.justify or "RIGHT")
        cell:SetWidth(column.width - 8)
        cell:SetPoint("RIGHT", right, 0)
        right = right - column.width
        row.cells[column.key] = cell
    end

    row.name = UI.Text(row)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.cells[COLUMNS[1].key], "LEFT", -8, 0)

    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
end

local function UpdateRow(row, data)
    InitRow(row)
    row.data = data
    local entry = data.entry
    row.icon:SetTexture(addon:EntryIcon(entry))
    row.name:SetText(addon:EntryName(entry))
    row.name:SetTextColor(addon:QualityColor(entry.itemID))

    local planned, craftable = addon:Planned(entry), addon:CraftableCount(entry) or 0
    local status, color = Status(entry, craftable)
    row.cells.status:SetText(status)
    row.cells.status:SetTextColor(unpack(color))
    row.cells.plan:SetText(planned)
    row.cells.craft:SetText(craftable)
    row.cells.craft:SetTextColor(unpack(craftable >= planned and GREEN or RED))

    local selected = addon.selected
    row.selection:SetShown(selected ~= nil and selected.entry == entry and not selected.reagent)
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
        local justify = column.justify or "RIGHT"
        local label = UI.Text(header, "GameFontNormalSmall", justify)
        label:SetPoint(justify, justify == "LEFT" and 8 or 0, 0)
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

-- The first queued craft held back only by its closed profession window,
-- and the spell that opens it.
local function FirstToOpen()
    for _, queued in ipairs(addon:Queue()) do
        local _, _, spell = addon.Prof:CraftState(queued.entry)
        if spell then return queued.entry, spell end
    end
end

-- With nothing ready, the button opens the profession of the next craft.
local function UpdateNext(queued)
    local entry, count = addon.Prof:NextQueued()
    local closed, spell
    if not entry then closed, spell = FirstToOpen() end
    pane.craftNext:SetOpens(spell)
    pane.craftNext:SetText(closed and ("Open " .. closed.prof) or "Craft next")
    pane.craftNext:SetEnabled(entry ~= nil or closed ~= nil)
    if entry then
        pane.nextText:SetText(("%s x%d"):format(addon:EntryName(entry), count))
    elseif closed then
        pane.nextText:SetText(addon:EntryName(closed))
    else
        pane.nextText:SetText(queued > 0 and "Nothing in the queue is ready" or "")
    end
end

function UI.CreateQueuePane(parent)
    pane = CreateFrame("Frame", nil, parent)

    -- The button sits level with the buttons on the other tabs.
    pane.craftNext = UI.CraftButton(pane, 120, function()
        local entry, count = addon.Prof:NextQueued()
        if entry then addon.Prof:Craft(entry, count) end
    end)
    pane.craftNext:SetText("Craft next")
    pane.craftNext:SetPoint("BOTTOMLEFT", 8, 8)
    pane.craftNext:SetScript("OnEnter", function(self)
        UI.Tooltip(self, self:GetText(), self:GetAttribute("spell") and "Opens the profession of the next craft"
            or "The first ready craft in the queue, as many as planned or your bags allow")
    end)
    pane.craftNext:SetScript("OnLeave", GameTooltip_Hide)
    pane.craftNext:SetMotionScriptsWhileDisabled(true)

    -- What the button crafts; anchored at the button's middle on both sides.
    pane.nextText = UI.Text(pane, "GameFontHighlight")
    pane.nextText:SetPoint("LEFT", pane.craftNext, "RIGHT", 10, 0)
    pane.nextText:SetPoint("RIGHT", pane, "BOTTOMRIGHT", -8, 21)

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

    function pane:Refresh()
        if not self:IsVisible() then return end
        local queue = addon:Queue()
        self.scrollBox:SetDataProvider(CreateDataProvider(queue), ScrollBoxConstants.RetainScrollPosition)
        self.message:SetText(#queue == 0
            and "Nothing planned. Right-click a craft in Lists to plan it, or a list to plan its stored amounts."
            or "")
        UpdateNext(#queue)
    end

    pane:SetScript("OnShow", function(self) self:Refresh() end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
