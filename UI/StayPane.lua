-- The Stay cheapest tab: the items of the lists ticked Stay cheapest that
-- you have in your bags or up for sale, grouped as To post (the cheapest
-- isn't yours: undercut, your cheapest gone, or none of yours up), Cheapest
-- (yours), Under floor, None in bags and Not checked; each with the
-- cheapest offer now (red when it's under yours), your lowest and its
-- floor. Right-click one for its floor. Below: the round's posts and
-- deposits with the duration, whether the checks run with Start and Stop,
-- Cancel extras for the items with none left in your bags, and the big
-- Post next.

local _, addon = ...
local UI = addon.UI
local Auction = addon.Auction
local Stay = addon.Stay

local ROW_HEIGHT = 20
local CELL = 76 -- each of the three price columns: room for gold, silver and copper

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local GRAY = { 0.5, 0.5, 0.5 }
local GREEN = { 0.25, 0.9, 0.25 }
local RED = { 1, 0.3, 0.3 }

local DURATIONS = { "2 hours", "8 hours", "24 hours" }
local HEADS = { "Now", "Yours", "Floor" }
local GROUPS = {
    { key = "post", name = "To post", color = GOLD },
    { key = "yours", name = "Cheapest", color = GREEN },
    { key = "floor", name = "Under floor", color = RED },
    { key = "empty", name = "None in bags", color = GRAY },
    { key = "unchecked", name = "Not checked", color = WHITE },
}

-- The items by group, each group in list order.
local function BuildElements(items)
    local grouped = {}
    for _, itemID in ipairs(items) do
        local key = Stay:Group(itemID)
        grouped[key] = grouped[key] or {}
        table.insert(grouped[key], itemID)
    end
    local elements = {}
    for _, group in ipairs(GROUPS) do
        local ids = grouped[group.key]
        if ids then
            elements[#elements + 1] = { kind = "group", group = group, count = #ids }
            for _, itemID in ipairs(ids) do
                elements[#elements + 1] = { kind = "item", group = group, itemID = itemID }
            end
        end
    end
    return elements
end

-- The menu's owner is UIParent: a row can hide when a round redraws the list,
-- and a menu closes with its owner.
local function OnRowClick(row, button)
    local data = row.data
    if not data or data.kind == "group" then return end
    if button == "RightButton" then
        UI.ShowFloorMenu(UIParent, data.itemID)
    else
        UI.ModifiedClick(data.itemID)
    end
end

local function OnRowEnter(row)
    local data = row.data
    if not data or data.kind == "group" then return end
    local itemID = data.itemID
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(itemID)
    local location = addon:FindInBags(itemID, true)
    local price = location and Stay:Price(itemID, addon:IsCommodity(itemID, location))
    if price then GameTooltip:AddDoubleLine("Next post at", addon.Money(price, true), 1, 0.82, 0, 1, 1, 1) end
    GameTooltip:Show()
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
    row.name = UI.Text(row)
    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
end

local function UpdateRow(row, data)
    InitRow(row)
    row.data = data
    row.name:ClearAllPoints()
    row.name:SetPoint("RIGHT", row.cells[1], "LEFT", -4, 0)

    -- A group's row names its columns.
    if data.kind == "group" then
        row.icon:Hide()
        row.name:SetFontObject("GameFontNormal")
        row.name:SetTextColor(unpack(data.group.color))
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetText(("%s  |cff808080%d|r"):format(data.group.name, data.count))
        for i, head in ipairs(HEADS) do
            row.cells[i]:SetFontObject("GameFontNormalSmall")
            SetCell(row, i, head, GOLD)
        end
        return
    end

    -- An item: how many are in your bags, the cheapest offer ("none" when
    -- nobody has any up; red when it's under yours), your lowest and the
    -- floor.
    local itemID = data.itemID
    row.icon:SetTexture(addon:ItemIcon(itemID))
    row.icon:Show()
    row.name:SetFontObject("GameFontHighlightSmall")
    row.name:SetTextColor(addon:QualityColor(itemID))
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetText(("%s x%d"):format(addon:ItemName(itemID) or "...", addon:BagCount(itemID)))
    for i = 1, 3 do row.cells[i]:SetFontObject("GameFontHighlightSmall") end
    local cheapest, yours, floor = Stay.cheapest[itemID], Stay:Yours(itemID), addon:Floor(itemID)
    local now = cheapest and addon.Money(cheapest, true) or cheapest == false and "none" or "-"
    SetCell(row, 1, now, Stay:State(itemID) == "undercut" and RED or WHITE)
    SetCell(row, 2, yours and addon.Money(yours, true) or "-")
    SetCell(row, 3, floor and addon.Money(floor, true) or "-", data.group.key == "floor" and RED or WHITE)
end

function UI.CreateStayPane(parent)
    local pane = CreateFrame("Frame", nil, parent)

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    UI.PlaceScrollList(pane.scrollBox, pane.scrollBar, -4, 116)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetPoint("TOP", 0, -40)

    -- The round's posts and deposits, and how long posts go up for: the
    -- same setting as the Sell tab's.
    pane.duration = CreateFrame("DropdownButton", nil, pane, "WowStyle1DropdownTemplate")
    pane.duration:SetWidth(120)
    pane.duration:SetPoint("BOTTOMRIGHT", -8, 84)
    pane.duration:SetupMenu(function(_, root)
        for index, label in ipairs(DURATIONS) do
            root:CreateRadio(label, function() return addon.db.duration == index end, function()
                addon.db.duration = index
                addon:Refresh()
            end)
        end
    end)
    pane.roundText = UI.Text(pane, "GameFontHighlight")
    pane.roundText:SetPoint("BOTTOMLEFT", 10, 90)
    pane.roundText:SetPoint("RIGHT", pane.duration, "LEFT", -8, 0)

    pane.toggle = UI.Button(pane, "Start checking", 120, 22)
    pane.toggle:SetPoint("BOTTOMRIGHT", -8, 54)
    pane.toggle:SetScript("OnClick", function()
        if Stay.on then Stay:Stop() else Stay:Start() end
    end)

    -- With none left in your bags: the game wants a click for each cancel,
    -- so each click cancels the first of the extras.
    pane.cancelExtra = UI.Button(pane, "Cancel extras", 120, 22)
    pane.cancelExtra:SetPoint("RIGHT", pane.toggle, "LEFT", -6, 0)
    pane.cancelExtra:SetScript("OnClick", function() Stay:CancelExtra() end)
    pane.cancelExtra:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Cancel extras",
            "Of each item with none left in your bags, cancels your auctions but the cheapest; one per click")
    end)
    pane.cancelExtra:SetScript("OnLeave", GameTooltip_Hide)

    pane.state = UI.Text(pane, "GameFontHighlight")
    pane.state:SetPoint("BOTTOMLEFT", 10, 60)
    pane.state:SetPoint("RIGHT", pane.cancelExtra, "LEFT", -8, 0)

    -- One click per post, as the game wants: the first item to post goes up.
    pane.postNext = UI.Button(pane, "Post next", 120, 40)
    pane.postNext:SetPoint("BOTTOMLEFT", 8, 8)
    pane.postNext:SetPoint("RIGHT", -8, 0)
    pane.postNext:SetNormalFontObject("GameFontNormalLarge")
    pane.postNext:SetHighlightFontObject("GameFontHighlightLarge")
    pane.postNext:SetDisabledFontObject("GameFontDisableLarge")
    pane.postNext:SetScript("OnClick", function() Stay:PostNext() end)
    pane.postNext:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Post next", "Puts up 1 of the first item to post, a step under the cheapest offer")
    end)
    pane.postNext:SetScript("OnLeave", GameTooltip_Hide)

    -- "Checking 12 items, 2 s ago"
    function pane:UpdateState()
        if not Stay.on then
            self.state:SetText("Not checking")
            return
        end
        local text = ("Checking %d items"):format(#Stay:Items())
        if Stay.checkedAt then text = ("%s, %d s ago"):format(text, math.floor(GetTime() - Stay.checkedAt)) end
        self.state:SetText(text)
    end

    -- "Post 1 Linen Cloth at 12s 34c", with the exact price each.
    function pane:UpdatePostNext()
        local button = self.postNext
        local itemID = Stay.on and Stay:Next()
        if Auction.posting then
            button:SetText("Posting...")
            button:Disable()
        elseif not itemID then
            button:SetText(Stay.on and "Nothing to post" or "Post next")
            button:Disable()
        else
            local location = addon:FindInBags(itemID, true)
            local price = Stay:Price(itemID, addon:IsCommodity(itemID, location))
            button:SetText(("Post 1 %s at %s"):format(addon:ItemName(itemID) or "...", addon.Money(price, true)))
            button:SetEnabled(Auction:CanAct() and not Auction:Busy())
        end
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
        local items = Stay:Items()
        self.scrollBox:SetDataProvider(CreateDataProvider(BuildElements(items)), ScrollBoxConstants.RetainScrollPosition)
        if #items > 0 then
            self.message:SetText("")
        elseif Stay:AnyTicked() then
            self.message:SetText("None of the ticked lists' items are in your bags or up for sale")
        else
            self.message:SetText("Tick Stay cheapest in a list's menu to keep its items the cheapest here")
        end
        local round = Stay.round
        self.roundText:SetText(("%d %s, deposits %s"):format(round.posts, round.posts == 1 and "post" or "posts",
            addon.Money(round.deposits, true)))
        self.duration:Update()
        self.toggle:SetText(Stay.on and "Stop checking" or "Start checking")
        self.toggle:SetEnabled(Stay.on or (Auction.isOpen and #items > 0))
        local extras = #Stay:Extras()
        self.cancelExtra:SetText(extras > 0 and ("Cancel extras (%d)"):format(extras) or "Cancel extras")
        self.cancelExtra:SetEnabled(extras > 0 and Auction:CanAct() and not Auction:Busy())
        self:UpdateState()
        self:UpdatePostNext()
    end

    pane:SetScript("OnShow", function(self) self:Refresh() end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
