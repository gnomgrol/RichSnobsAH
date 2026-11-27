-- Small pieces the panes share: buttons, tabs, the price ladder, the item
-- header, menus and text prompts.

local _, addon = ...
local UI = addon.UI

function UI.Button(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetText(text)
    button:SetSize(width or 100, height or 22)
    return button
end

function UI.Text(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    text:SetWordWrap(false)
    return text
end

-- Places a scroll list and its bar against an inset's right edge, as
-- Blizzard's auction lists do: the bar is 8 px wide but its arrow buttons
-- are 17, so the list stops 26 px short of the edge, and the bar sits 9 px
-- right of it, which keeps the arrows inside the inset's border.
function UI.PlaceScrollList(scrollBox, scrollBar, top, bottom)
    scrollBox:SetPoint("TOPLEFT", 4, top)
    scrollBox:SetPoint("BOTTOMRIGHT", -26, bottom)
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)
end

-- A title and any lines under it.
function UI.Tooltip(owner, title, ...)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title)
    for i = 1, select("#", ...) do
        local line = select(i, ...)
        if line then GameTooltip:AddLine(line, 1, 1, 1, true) end
    end
    GameTooltip:Show()
end

function UI.ItemLink(itemID)
    return itemID and select(2, C_Item.GetItemInfo(itemID))
end

-- A button that crafts, or opens the profession a craft needs: SetOpens
-- (spell) makes the click cast that spell, SetOpens(nil) makes it craft.
-- Only a secure button may cast it. Its attributes can't change in combat,
-- when the window is closed anyway.
function UI.CraftButton(parent, width, onCraft)
    local button = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate, UIPanelButtonTemplate")
    button:SetSize(width, 26)
    button:SetText("Craft")
    -- An addon's secure button acts on mouse down while "cast on key down"
    -- is on, which it is by default; this one acts on release, as it crafts.
    button:RegisterForClicks("LeftButtonUp")
    button:SetAttribute("useOnKeyDown", false)
    -- Runs after the secure click, which does nothing while there is no spell.
    button:SetScript("PostClick", function(self)
        if not self:GetAttribute("spell") then onCraft() end
    end)
    function button:SetOpens(spell)
        if InCombatLockdown() or self:GetAttribute("spell") == spell then return end
        self:SetAttribute("type", spell and "spell" or nil)
        self:SetAttribute("spell", spell)
    end
    return button
end

-- Shift-click links the item in chat, Ctrl-click previews it, as anywhere.
function UI.ModifiedClick(itemID)
    local link = UI.ItemLink(itemID)
    if link and IsModifiedClick() then
        HandleModifiedItemClick(link)
        return true
    end
end

local UNITS = { g = 10000, s = 100, c = 1 }

-- Copper from "12g 50s 3c", "50s" or a number of gold like "12.5"; nil for
-- anything else, and for nothing at all. The prompts for a price take it.
function UI.ParseMoney(text)
    text = strtrim(text):lower()
    local copper = tonumber(text)
    if copper then
        copper = copper * 10000
    else
        local found = false
        copper = 0
        local rest = text:gsub("(%d+%.?%d*)%s*([gsc])", function(amount, unit)
            copper = copper + tonumber(amount) * UNITS[unit]
            found = true
            return ""
        end)
        if not found or rest:find("%S") then return nil end
    end
    copper = math.floor(copper + 0.5)
    if copper > 0 then return copper end
end

-- "12g 50s", as ParseMoney takes it back.
function UI.PlainMoney(copper)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

-- An item's floor for Stay cheapest: set your own, or go back to break-even.
-- From the Stay cheapest tab's rows.
function UI.ShowFloorMenu(owner, itemID)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local floor, own = addon:Floor(itemID)
        root:CreateButton("Set floor...", function()
            addon:Prompt(("Least to post one %s at, like 12g 50s:"):format(addon:ItemName(itemID) or "item"),
                floor and UI.PlainMoney(floor) or "", function(text)
                    local copper = UI.ParseMoney(text)
                    if copper then
                        addon.db.floors[itemID] = copper
                        addon:Refresh()
                    else
                        addon:SetStatus("Not a price: " .. text)
                    end
                end)
        end)
        local breakEven = addon:BreakEven(itemID)
        root:CreateButton(breakEven and "Break-even, " .. addon.Money(breakEven, true) or "No floor", function()
            addon.db.floors[itemID] = nil
            addon:Refresh()
        end):SetEnabled(own)
    end)
end

--------------------------------------------------------------------------------
-- Icon buttons on Blizzard's frames
--------------------------------------------------------------------------------

-- A small icon button; the caller places it. art: { icon = texture } for an
-- item-style icon, or { normal, pushed, highlight } for button art.
function UI.IconButton(parent, size, art, title, line, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)
    button:SetFrameLevel(parent:GetFrameLevel() + 10)
    if art.icon then
        button:SetNormalTexture(art.icon)
        button:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
        button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    else
        button:SetNormalTexture(art.normal)
        button:SetPushedTexture(art.pushed)
        button:SetHighlightTexture(art.highlight, "ADD")
    end
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self) UI.Tooltip(self, title, line) end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

--------------------------------------------------------------------------------
-- Tabs: names in a row, the active one gold and underlined
--------------------------------------------------------------------------------

function UI.Tabs(parent, names, onSelect)
    local tabs = { buttons = {} }
    local previous
    for index, name in ipairs(names) do
        local tab = CreateFrame("Button", nil, parent)
        tab.label = UI.Text(tab, "GameFontNormal", "CENTER")
        tab.label:SetPoint("CENTER", 0, 1)
        tab.label:SetText(name)
        tab:SetSize(tab.label:GetStringWidth() + 18, 24)
        tab:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        tab.line = tab:CreateTexture(nil, "ARTWORK")
        tab.line:SetColorTexture(1, 0.82, 0, 1)
        tab.line:SetHeight(2)
        tab.line:SetPoint("BOTTOMLEFT", 4, 0)
        tab.line:SetPoint("BOTTOMRIGHT", -4, 0)
        if previous then
            tab:SetPoint("LEFT", previous, "RIGHT", 2, 0)
        else
            tab:SetPoint("TOPLEFT")
        end
        tab:SetScript("OnClick", function() tabs:Select(index) end)
        tabs.buttons[index] = tab
        previous = tab
    end

    function tabs:Select(index)
        self.selected = index
        for i, tab in ipairs(self.buttons) do
            local active = i == index
            tab.line:SetShown(active)
            tab.label:SetFontObject(active and "GameFontNormal" or "GameFontDisable")
        end
        onSelect(index)
    end

    function tabs:SetShown(shown)
        for _, tab in ipairs(self.buttons) do tab:SetShown(shown) end
    end

    return tabs
end

--------------------------------------------------------------------------------
-- The item a pane is about: icon, name, a note on the right, and a button
-- to add it to a list
--------------------------------------------------------------------------------

local EMPTY_SLOT = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"

-- Puts the item on the cursor back where it came from and hands its ID and
-- location to onTake. Returns whether the cursor held an item.
function UI.TakeCursorItem(onTake)
    local kind, itemID = GetCursorInfo()
    if kind ~= "item" or not itemID then return false end
    local location = C_Cursor and C_Cursor.GetCursorItem and C_Cursor.GetCursorItem()
    ClearCursor()
    onTake(itemID, location)
    return true
end

-- The Buy and Sell tabs' item, with Price history at the right. With onDrop,
-- the header is also a slot: an item dropped on it, or clicked onto it,
-- goes to onDrop(itemID, location), and an empty one says so.
function UI.ItemHeader(parent, onDrop)
    local header = CreateFrame("Frame", nil, parent)
    header:SetHeight(28)

    header.iconButton = CreateFrame("Button", nil, header)
    header.iconButton:SetSize(24, 24)
    header.iconButton:SetPoint("LEFT")
    header.icon = header.iconButton:CreateTexture(nil, "ARTWORK")
    header.icon:SetAllPoints()
    header.iconButton:SetScript("OnEnter", function(self)
        if not header.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(header.itemID)
        GameTooltip:Show()
    end)
    header.iconButton:SetScript("OnLeave", GameTooltip_Hide)
    header.iconButton:SetScript("OnClick", function()
        if onDrop and UI.TakeCursorItem(onDrop) then return end
        UI.ModifiedClick(header.itemID)
    end)
    if onDrop then
        local function Drop() UI.TakeCursorItem(onDrop) end
        header:EnableMouse(true)
        header:SetScript("OnReceiveDrag", Drop)
        header:SetScript("OnMouseUp", Drop)
        header.iconButton:SetScript("OnReceiveDrag", Drop)
    end

    header.history = UI.Button(header, "Price history", 100, 22)
    header.history:SetPoint("RIGHT")
    header.history:SetScript("OnClick", function() addon:ShowHistory(header.itemID) end)

    header.note = UI.Text(header, "GameFontDisableSmall", "RIGHT")
    header.note:SetPoint("RIGHT", header.history, "LEFT", -6, 0)

    header.name = UI.Text(header, "GameFontNormal")
    header.name:SetPoint("LEFT", header.iconButton, "RIGHT", 6, 0)
    header.name:SetPoint("RIGHT", header.note, "LEFT", -6, 0)

    function header:SetItem(itemID, note)
        -- An open price history moves on with the item.
        if itemID and itemID ~= self.itemID then addon:HistoryFollows(itemID) end
        self.itemID = itemID
        if itemID then
            self.icon:SetTexture(addon:ItemIcon(itemID))
            self.name:SetText(addon:ItemName(itemID) or "...")
            self.name:SetTextColor(addon:QualityColor(itemID))
        else
            self.icon:SetTexture(EMPTY_SLOT)
            self.name:SetText(onDrop and "Drop an item here" or "")
            self.name:SetTextColor(0.5, 0.5, 0.5)
        end
        self.history:SetEnabled(itemID ~= nil)
        self.note:SetText(note or "")
    end

    return header
end

--------------------------------------------------------------------------------
-- The price ladder: one item's cheapest offers
--------------------------------------------------------------------------------

local ROW = 16

-- Exact for your own auctions; others' come as Blizzard's bands, Short to
-- Very Long, shown as its own list shows them.
local function TimeLeft(data)
    if data.timeLeft then return addon.Age(data.timeLeft) end
    if data.band and AuctionHouseUtil and AuctionHouseUtil.GetTimeLeftBandText then
        return AuctionHouseUtil.GetTimeLeftBandText(data.band)
    end
    return ""
end

-- A commodity shows unit price and how many. An item auction shows its
-- price and time left, and "x7" when seven identical ones share the row.
-- With onSelect, a click on a row passes it on. It shows as many rows as
-- its height holds.
function UI.Ladder(parent, onSelect)
    local ladder = CreateFrame("Frame", nil, parent)
    ladder.rows = {}

    ladder.leftHead = UI.Text(ladder, "GameFontNormalSmall")
    ladder.leftHead:SetPoint("TOPLEFT", 4, 0)
    ladder.rightHead = UI.Text(ladder, "GameFontNormalSmall", "RIGHT")
    ladder.rightHead:SetPoint("TOPRIGHT", -4, 0)

    ladder.message = UI.Text(ladder, "GameFontDisableSmall", "CENTER")
    ladder.message:SetPoint("TOPLEFT", 8, -ROW * 2)
    ladder.message:SetPoint("TOPRIGHT", -8, -ROW * 2)
    ladder.message:SetWordWrap(true)

    local function Row(i)
        if ladder.rows[i] then return ladder.rows[i] end
        local row = CreateFrame("Button", nil, ladder)
        row:SetHeight(ROW)
        row:SetPoint("TOPLEFT", 0, -ROW * i - 2)
        row:SetPoint("TOPRIGHT", 0, -ROW * i - 2)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.selection = row:CreateTexture(nil, "BACKGROUND")
        row.selection:SetAllPoints()
        row.selection:SetColorTexture(1, 0.82, 0, 0.18)
        row.price = UI.Text(row)
        row.price:SetPoint("LEFT", 4, 0)
        row.right = UI.Text(row, nil, "RIGHT")
        row.right:SetPoint("RIGHT", -4, 0)
        row.note = UI.Text(row, "GameFontDisableSmall", "RIGHT")
        row.note:SetPoint("RIGHT", -70, 0)
        row.price:SetPoint("RIGHT", row.note, "LEFT", -4, 0)
        row:SetScript("OnClick", function(self)
            if onSelect and self.data then onSelect(self.data) end
        end)
        ladder.rows[i] = row
        return row
    end

    -- rows: from addon.Auction.results; message: shown instead of rows.
    function ladder:SetData(rows, commodity, selected, message)
        self.lastData = { rows, commodity, selected, message }
        self.leftHead:SetText(commodity and "Unit price" or "Price")
        self.rightHead:SetText(commodity and "Available" or "Time left")
        self.message:SetText(message or "")
        -- The heading takes a row's height, and the gaps 4 more.
        local fit = math.floor((self:GetHeight() - 4) / ROW) - 1
        for i = 1, math.max(fit, #self.rows) do
            local data = i <= fit and not message and rows and rows[i] or nil
            local row = data and Row(i) or self.rows[i]
            if row then
                row.data = data
                row:SetShown(data ~= nil)
            end
            if data then
                local note = data.own and "|cff66bbffyours|r" or ""
                if commodity then
                    row.price:SetText(addon.Money(data.unit, true))
                    row.right:SetText(BreakUpLargeNumbers(data.quantity))
                else
                    row.price:SetText(addon.Money(data.buyout, true))
                    row.right:SetText(TimeLeft(data))
                    if not data.own and data.quantity > 1 then note = ("x%d"):format(data.quantity) end
                end
                row.note:SetText(note)
                row.selection:SetShown(selected ~= nil and data == selected)
            end
        end
    end

    -- A new height shows more or fewer rows.
    ladder:SetScript("OnSizeChanged", function(self)
        if self.lastData then self:SetData(unpack(self.lastData, 1, 4)) end
    end)

    return ladder
end

--------------------------------------------------------------------------------
-- Menus and prompts
--------------------------------------------------------------------------------

-- Adds an item to a list and says so: on the status line, and at the top
-- of the screen while the window is closed.
function UI.AddToList(list, itemID)
    local _, added = addon:AddItem(list, itemID)
    local text = ("%s %s %s"):format(addon:ItemName(itemID) or "Item", added and "added to" or "is already on",
        list.name)
    addon:SetStatus(text)
    if not (addon.window and addon.window:IsVisible()) then UIErrorsFrame:AddMessage(text, 1, 0.82, 0) end
end

-- Your lists as buttons under root, plus a new one; onPick gets the list.
function UI.ListButtons(root, onPick)
    for _, list in ipairs(addon.db.lists) do
        root:CreateButton(list.name, function() onPick(list) end)
    end
    root:CreateButton("New list...", function()
        addon:Prompt("Name of the new list:", "", function(name) onPick(addon:NewList(name)) end)
    end)
end

-- An item's menu: search for it at the auction house, see its price history,
-- or add it to a list. Alt-click on any item opens it too (Window.lua).
function addon:ShowItemMenu(owner, itemID)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(addon:ItemName(itemID) or "")
        root:CreateButton("Search", function()
            addon:ShowWindow()
            addon:Select({ itemID = itemID }, "buy")
            addon.Auction:Search(itemID)
        end):SetEnabled(addon.Auction.isOpen)
        root:CreateButton("Price history", function() addon:ShowHistory(itemID) end)
        root:CreateDivider()
        root:CreateTitle("Add to list")
        UI.ListButtons(root, function(list) UI.AddToList(list, itemID) end)
    end)
end

-- A menu of your lists, plus a new one.
function addon:ShowListPicker(owner, title, onPick)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(title)
        UI.ListButtons(root, onPick)
    end)
end

local function DialogEditBox(dialog)
    return dialog.editBox or dialog.EditBox or (dialog.GetEditBox and dialog:GetEditBox())
end

local function AcceptPrompt(dialog, data)
    data = data or dialog.data
    local text = strtrim(DialogEditBox(dialog):GetText() or "")
    if text ~= "" and data and data.onAccept then data.onAccept(text) end
end

-- Only keys are added: replacing StaticPopupDialogs itself would taint it.
StaticPopupDialogs.RICHSNOBSAH_PROMPT = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 64,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(dialog, data)
        data = data or dialog.data
        local box = DialogEditBox(dialog)
        box:SetText(data and data.default or "")
        box:HighlightText()
        box:SetFocus()
    end,
    OnAccept = AcceptPrompt,
    EditBoxOnEnterPressed = function(box, data)
        local dialog = box:GetParent()
        AcceptPrompt(dialog, data)
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(box)
        box:GetParent():Hide()
    end,
}

StaticPopupDialogs.RICHSNOBSAH_CONFIRM = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnAccept = function(dialog, data)
        data = data or dialog.data
        if data and data.onAccept then data.onAccept() end
    end,
}

function addon:Prompt(text, default, onAccept)
    StaticPopup_Show("RICHSNOBSAH_PROMPT", text, nil, { default = default, onAccept = onAccept })
end

function addon:Confirm(text, onAccept)
    StaticPopup_Show("RICHSNOBSAH_CONFIRM", text, nil, { onAccept = onAccept })
end
