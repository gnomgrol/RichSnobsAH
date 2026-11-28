-- The Disenchant tab, on the left: what in your bags disenchants, in bag
-- order, with what its materials bring after the cut and what it sells for,
-- the better of the two in green. First the items Disenchant next works
-- through, then the ones it keeps, each with why. A click picks an item for
-- the button, a kept one too, and a click on it again lets go; a right-click
-- ignores an item or stops ignoring it. Below the list: whether to keep what
-- sells for more, the Salvager tick, whether you're at a Salvager, your
-- results since they last started over, and the big button, which
-- disenchants an item a click; away from a Salvager, a green asks first.

local _, addon = ...
local UI = addon.UI
local DE = addon.Disenchant

local ROW_HEIGHT = 20
local CELL = 70    -- each of the two price columns
local REASON = 100 -- why an item is kept

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local GREEN = { 0.25, 0.9, 0.25 }
local ORANGE = { 1, 0.5, 0.25 }

local pane

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function SetCell(cell, text, color)
    cell:SetText(text)
    cell:SetTextColor(unpack(color or WHITE))
end

local function QualityColor(quality)
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then return color.r, color.g, color.b end
    return 1, 1, 1
end

local function ShowMenu(row, item)
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(addon:ItemName(item.itemID) or "")
        local ignored = addon.db.bagDisenchant.ignored[item.itemID]
        root:CreateButton(ignored and "Stop ignoring" or "Ignore", function()
            DE:SetIgnored(item.itemID, not ignored)
        end)
    end)
end

local function OnRowClick(row, button)
    local item = row.data and row.data.item
    if not item then return end
    if button == "RightButton" then
        ShowMenu(row, item)
    elseif not UI.ModifiedClick(item.itemID) then
        DE:Pick(item)
    end
end

-- The bag item's own tooltip, which names its materials.
local function OnRowEnter(row)
    local item = row.data and row.data.item
    if not item then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetBagItem(item.bag, item.slot)
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
    row.sells = UI.Text(row, nil, "RIGHT")
    row.sells:SetWidth(CELL - 4)
    row.sells:SetPoint("RIGHT", -2, 0)
    row.value = UI.Text(row, nil, "RIGHT")
    row.value:SetWidth(CELL - 4)
    row.value:SetPoint("RIGHT", -2 - CELL, 0)
    row.reason = UI.Text(row, "GameFontDisableSmall", "RIGHT")
    row.reason:SetWidth(REASON)
    row.reason:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
    row.name = UI.Text(row)
    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
end

local function UpdateRow(row, data)
    InitRow(row)
    row.data = data
    row.name:ClearAllPoints()
    row.name:SetPoint("RIGHT", row.reason, "LEFT", -6, 0)

    -- A group's head names it and the columns.
    if data.kind == "head" then
        row.icon:Hide()
        row.selection:Hide()
        row.name:SetFontObject("GameFontNormal")
        row.name:SetTextColor(unpack(GOLD))
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetText(("%s  |cff808080%d|r"):format(data.label, data.count))
        row.reason:SetText("")
        row.value:SetFontObject("GameFontNormalSmall")
        row.sells:SetFontObject("GameFontNormalSmall")
        SetCell(row.value, "Disenchant", GOLD)
        SetCell(row.sells, "Sells for", GOLD)
        return
    end

    -- An item with its item level, why it's kept, and its two prices, the
    -- better one green. The button's item is marked.
    local item = data.item
    row.icon:SetTexture(addon:ItemIcon(item.itemID))
    row.icon:Show()
    row.selection:SetShown(data.target)
    row.name:SetFontObject("GameFontHighlightSmall")
    row.name:SetTextColor(QualityColor(item.quality))
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetText(("%s  |cff808080%d|r"):format(addon:ItemName(item.itemID) or "...", item.level))
    row.reason:SetText(item.kept or "")
    row.value:SetFontObject("GameFontHighlightSmall")
    row.sells:SetFontObject("GameFontHighlightSmall")
    SetCell(row.value, item.value > 0 and addon.Money(item.value) or "-", item.value > item.sells and GREEN or WHITE)
    SetCell(row.sells, item.sells > 0 and addon.Money(item.sells) or "-", item.sells > item.value and GREEN or WHITE)
end

-- The items Disenchant next works through, then the ones kept, each group
-- under its head; and how many the button has to go.
local function Elements(items, target)
    local queue, kept = {}, {}
    for _, item in ipairs(items) do
        local group = item.kept and kept or queue
        group[#group + 1] = { kind = "item", item = item, target = item == target }
    end
    local elements = {}
    for _, group in ipairs({ { "Disenchant next", queue }, { "Kept", kept } }) do
        local label, rows = group[1], group[2]
        if #rows > 0 then
            elements[#elements + 1] = { kind = "head", label = label, count = #rows }
            for _, row in ipairs(rows) do elements[#elements + 1] = row end
        end
    end
    return elements, #queue
end

--------------------------------------------------------------------------------
-- Your results
--------------------------------------------------------------------------------

-- Materials as { itemID, n }, most first.
local function Sorted(materials)
    local list = {}
    for itemID, n in pairs(materials) do list[#list + 1] = { itemID = itemID, n = n } end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.itemID < b.itemID
    end)
    return list
end

-- "Since Nov 27: 14 disenchanted, worth 2g 14s, paid 1g 40s for 10"
local function ResultsText()
    local results = addon.db.disenchantResults
    if results.count == 0 then return "No disenchants counted yet" end
    local text = ("Since %s %d: %d disenchanted, worth %s"):format(date("%b", results.since),
        tonumber(date("%d", results.since)), results.count, addon.Money(DE:ResultsWorth()))
    if results.paidFor > 0 then
        text = text .. (", paid %s for %d"):format(addon.Money(results.paid), results.paidFor)
    end
    return text
end

-- Each material your disenchants gave, with what it brings after the cut,
-- then the last disenchants, each with what it gave.
local function ShowResults(owner)
    local results = addon.db.disenchantResults
    if results.count == 0 then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText("Your disenchants")
    for _, material in ipairs(Sorted(results.materials)) do
        local price = DE:MaterialPrice(material.itemID)
        GameTooltip:AddDoubleLine(("%d %s"):format(material.n, addon:ItemName(material.itemID) or "..."),
            price and addon.Money(material.n * price * DE.AFTER_CUT) or "-", 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Last disenchants", unpack(GOLD))
    for _, last in ipairs(results.last) do
        local words = {}
        for _, material in ipairs(Sorted(last.materials)) do
            words[#words + 1] = ("%d %s"):format(material.n, addon:ItemName(material.itemID) or "...")
        end
        GameTooltip:AddLine(("%s: %s"):format(last.itemID and addon:ItemName(last.itemID) or "Unknown item",
            table.concat(words, ", ")), 1, 1, 1, true)
    end
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- The button
--------------------------------------------------------------------------------

-- Only a secure button's click may cast Disenchant at an item. Just before
-- the click, PreClick aims the button at the item it shows, if that is
-- still in its bag slot and not locked; the click casts Disenchant there;
-- PostClick takes the aim off again, so the button never casts at an item
-- it doesn't show. It acts on the mouse's release, like the Craft buttons.
-- Its aim can't change in combat, when the window is closed anyway.
local AIM = { "type", "spell", "target-bag", "target-slot" }

-- A green gives more materials at an Arcane Salvager, so away from one the
-- button asks first instead. Yes lets greens go without one until you're
-- next at one; as the popup can't cast, the next click disenchants. Nothing
-- asks when the game won't say whether its buff is on you.
local ASK = "Not at an Arcane Salvager, where greens give more materials.\n\n"
    .. "Disenchant greens anyway until you're next at one?"
local withoutSalvager

local function AsksFirst(item)
    return item.quality == 2 and DE:Boosted() == false and not withoutSalvager
end

-- Named, for the hotkey's binding, which clicks it as the mouse does.
local function DisenchantButton(parent)
    local button = CreateFrame("Button", "RichSnobsAHDisenchantNext", parent,
        "SecureActionButtonTemplate, UIPanelButtonTemplate")
    button:SetHeight(40)
    button:SetNormalFontObject("GameFontNormalLarge")
    button:SetHighlightFontObject("GameFontHighlightLarge")
    button:SetDisabledFontObject("GameFontDisableLarge")
    button:RegisterForClicks("LeftButtonUp")
    button:SetAttribute("useOnKeyDown", false)
    button:SetScript("PreClick", function(self)
        local item = self.item
        if InCombatLockdown() or not item or not self:IsVisible() then return end
        local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
        if not (info and info.itemID == item.itemID and not info.isLocked) then return end
        if AsksFirst(item) then
            addon:Confirm(ASK, function() withoutSalvager = true end)
            return
        end
        self:SetAttribute("type", "spell")
        self:SetAttribute("spell", DE.SPELL)
        self:SetAttribute("target-bag", item.bag)
        self:SetAttribute("target-slot", item.slot)
        DE:Aim(item)
    end)
    button:SetScript("PostClick", function(self)
        if InCombatLockdown() then return end
        for _, key in ipairs(AIM) do self:SetAttribute(key, nil) end
    end)
    return button
end

-- The item the button disenchants and what it says; no item when it can't.
local function ButtonState(items, queued)
    if not DE:Known() then return nil, "You don't know Disenchant" end
    local busy, busyItem = DE:Disenchanting()
    if busy then
        return nil, busyItem and ("Disenchanting %s..."):format(addon:ItemName(busyItem) or "") or "Disenchanting..."
    end
    local item = DE:BagTarget(items)
    if not item then return nil, "Nothing to disenchant" end
    if addon:FreeBagSlots() == 0 then return nil, "Bags full" end
    local name = addon:ItemName(item.itemID) or "..."
    if item.kept then return item, ("Disenchant %s (%s)"):format(name, item.kept) end
    return item, ("Disenchant %s (%d left)"):format(name, queued)
end

--------------------------------------------------------------------------------
-- The pane
--------------------------------------------------------------------------------

function UI.CreateDisenchantBagsPane(parent)
    pane = CreateFrame("Frame", nil, parent)

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    UI.PlaceScrollList(pane.scrollBox, pane.scrollBar, -4, 112)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetPoint("TOP", 0, -40)

    -- What Disenchant next leaves for selling, and the Salvager.
    pane.keepSellers = UI.Check(pane, "Keep what sells for more", function(on) DE:SetKeepSellers(on) end)
    pane.keepSellers:SetPoint("BOTTOMLEFT", 6, 82)
    pane.keepSellers:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Keep what sells for more",
            "Leaves out items a vendor, or the auction house when unbound, pays more for than their materials bring")
    end)
    pane.keepSellers:SetScript("OnLeave", GameTooltip_Hide)
    pane.salvager = UI.Check(pane, "Salvager", function(on) DE:Set("salvager", on) end)
    pane.salvager:SetPoint("LEFT", pane.keepSellers.label, "RIGHT", 14, -1)
    pane.salvager:SetScript("OnEnter", function(self) UI.Tooltip(self, "Arcane Salvager", UI.SalvagerLines()) end)
    pane.salvager:SetScript("OnLeave", GameTooltip_Hide)

    -- Whether the Salvager's buff is on you.
    pane.boost = UI.Text(pane, "GameFontHighlight", "RIGHT")
    pane.boost:SetPoint("BOTTOMRIGHT", -10, 88)

    -- Your results, with what they gave on hover, and a button to start over.
    pane.reset = UI.Button(pane, "Reset", 70, 22)
    pane.reset:SetPoint("BOTTOMRIGHT", -8, 54)
    pane.reset:SetScript("OnClick", function()
        addon:Confirm("Start your disenchant results over?", function() DE:ResetResults() end)
    end)
    pane.results = CreateFrame("Frame", nil, pane)
    pane.results:SetHeight(22)
    pane.results:SetPoint("BOTTOMLEFT", 10, 54)
    pane.results:SetPoint("RIGHT", pane.reset, "LEFT", -8, 0)
    pane.results:EnableMouse(true)
    pane.results:SetScript("OnEnter", ShowResults)
    pane.results:SetScript("OnLeave", GameTooltip_Hide)
    pane.results.text = UI.Text(pane.results, "GameFontHighlightSmall")
    pane.results.text:SetAllPoints()

    pane.button = DisenchantButton(pane)
    pane.hotkeyButton = pane.button
    pane.button:SetPoint("BOTTOMLEFT", 8, 8)
    pane.button:SetPoint("RIGHT", -8, 0)
    pane.button:SetMotionScriptsWhileDisabled(true)
    pane.button:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Disenchant", "One item a click: the one you picked, else the first under Disenchant next")
    end)
    pane.button:SetScript("OnLeave", GameTooltip_Hide)

    -- The button names its item, kept for its click, so it disenchants what it says.
    function pane:UpdateButton()
        if InCombatLockdown() then return end
        local item, text = ButtonState(self.items or {}, self.queued or 0)
        self.button.item = item
        self.button:SetText(text)
        self.button:SetEnabled(item ~= nil)
        local boosted = DE:Boosted()
        if boosted then withoutSalvager = nil end
        self.boost:SetText(boosted and "Salvager boost on" or boosted == false and "Not at a Salvager" or "")
        self.boost:SetTextColor(unpack(boosted and GREEN or ORANGE))
    end

    function pane:Refresh()
        if not self:IsVisible() then return end
        local items = DE:BagItems()
        local elements, queued = Elements(items, DE:BagTarget(items))
        self.items, self.queued = items, queued
        self.scrollBox:SetDataProvider(CreateDataProvider(elements), ScrollBoxConstants.RetainScrollPosition)
        self.message:SetText(#items == 0 and "Nothing in your bags disenchants" or "")
        self.keepSellers:SetChecked(addon.db.bagDisenchant.keepSellers)
        self.salvager:SetChecked(addon.db.disenchant.salvager)
        self.results.text:SetText(ResultsText())
        self.reset:SetEnabled(addon.db.disenchantResults.count > 0)
        self:UpdateButton()
    end

    -- A disenchant on its way runs out, and the Salvager's buff comes and
    -- goes, without a redraw: the button looks again once a second.
    local sinceTick = 0
    pane:SetScript("OnUpdate", function(self, elapsed)
        sinceTick = sinceTick + elapsed
        if sinceTick < 1 then return end
        sinceTick = 0
        self:UpdateButton()
    end)

    pane:SetScript("OnShow", function(self) self:Refresh() end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
