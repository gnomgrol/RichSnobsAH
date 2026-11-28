-- The Sell tab: post the selected item at a price prefilled one step under
-- the cheapest other seller, or under the offer you click, with the deposit
-- and the profit after the cut.
-- Next steps through the items on your lists that are in your bags, except
-- on lists marked not for sale. Any item can be dropped on the header, or
-- right-clicked in your bags while this tab shows (Window.lua). The hotkey
-- posts, or steps on once the item is gone.

local _, addon = ...
local UI = addon.UI
local Auction = addon.Auction

local DURATIONS = { "2 hours", "8 hours", "24 hours" }

-- The inputs sit just above the buttons: from the pane's bottom, the
-- buttons' 34, a gap of 12, and the quantity, price, duration, deposit and
-- profit lines' 112. The offers fill the space above.
local CONTROLS_TOP = 158

local GREEN = { 0.25, 0.9, 0.25 }
local RED = { 1, 0.3, 0.3 }

-- The next item on your lists, after current, that is in your bags and can
-- be sold. A list marked not for sale is skipped, but an item it shares with
-- another list still comes up there.
local function NextSellable(current)
    local candidates, seen = {}, {}
    for _, list in ipairs(addon.db.lists) do
        if not list.notForSale then
            for _, entry in ipairs(list.entries) do
                local itemID = entry.itemID
                if itemID and not seen[itemID] and addon:FindInBags(itemID, true) then
                    seen[itemID] = true
                    candidates[#candidates + 1] = { itemID = itemID, list = list, entry = entry }
                end
            end
        end
    end
    if #candidates == 0 then return nil end
    local index = 0
    for i, candidate in ipairs(candidates) do
        if candidate.itemID == current then
            index = i
            break
        end
    end
    return candidates[index % #candidates + 1]
end

local function Line(pane, label, anchor, gap)
    local left = UI.Text(pane, "GameFontHighlight")
    left:SetText(label)
    left:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 10))
    local right = UI.Text(pane, "GameFontHighlight", "RIGHT")
    right:SetPoint("RIGHT", pane, "RIGHT", -10, 0)
    right:SetPoint("TOP", left, "TOP")
    return left, right
end

function UI.CreateSellPane(parent)
    local pane = CreateFrame("Frame", nil, parent)

    -- An item the auction house won't take shows the game's own error.
    pane.header = UI.ItemHeader(pane, function(itemID, location)
        if location and not C_AuctionHouse.IsSellItemValid(location, true) then return end
        addon:Select({ itemID = itemID }, "sell")
    end)
    pane.header:SetPoint("TOPLEFT", 6, -4)
    pane.header:SetPoint("TOPRIGHT", -6, -4)

    -- A click on an offer prices yours one step under it, or at its price
    -- when it's yours, and marks it until the price or the item changes.
    pane.ladder = UI.Ladder(pane, function(row)
        local result = pane.itemID and Auction.results[pane.itemID]
        if not (result and row.unit) then return end
        pane.target = row.unit
        pane.autoPrice = false
        pane:SetPrice(Auction:PriceUnder(row, result.commodity))
        addon:Refresh()
    end)
    pane.ladder:SetPoint("TOPLEFT", pane.header, "BOTTOMLEFT", 0, -6)
    pane.ladder:SetPoint("BOTTOMRIGHT", -6, CONTROLS_TOP + 12)

    -- Quantity: commodities from all your stacks at once, items one per post.
    -- Max goes back to as many as can be posted, which then follows your bags.
    pane.quantityLabel = UI.Text(pane, "GameFontHighlight")
    pane.quantityLabel:SetText("Quantity")
    pane.quantityLabel:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", 10, CONTROLS_TOP)
    pane.max = UI.Button(pane, "Max", 44, 20)
    pane.max:SetPoint("RIGHT", pane, "RIGHT", -10, 0)
    pane.max:SetPoint("TOP", pane.quantityLabel, "TOP", 0, 4)
    pane.max:SetScript("OnClick", function()
        pane.autoQuantity = true
        pane.quantity:ClearFocus()
        addon:Refresh()
    end)
    -- "of 12" between the box and Max; an item's "one per post" takes their place.
    pane.quantityNote = UI.Text(pane, "GameFontDisableSmall", "RIGHT")
    pane.quantityNote:SetPoint("RIGHT", pane.max, "LEFT", -6, 0)
    pane.quantity = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    pane.quantity:SetSize(60, 20)
    pane.quantity:SetAutoFocus(false)
    pane.quantity:SetNumeric(true)
    pane.quantity:SetMaxLetters(6)
    pane.quantity:SetPoint("RIGHT", pane.quantityNote, "LEFT", -8, 0)
    pane.quantity:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            pane.autoQuantity = false
            addon:Refresh()
        end
    end)
    pane.quantity:SetScript("OnEnterPressed", EditBox_ClearFocus)
    pane.quantity:SetScript("OnEscapePressed", EditBox_ClearFocus)

    pane.priceLabel = UI.Text(pane, "GameFontHighlight")
    pane.priceLabel:SetText("Each")
    pane.priceLabel:SetPoint("TOPLEFT", pane.quantityLabel, "BOTTOMLEFT", 0, -16)
    -- MoneyInputFrameTemplate names its boxes after the frame, so it needs a name.
    pane.price = CreateFrame("Frame", "RichSnobsAHSellPrice", pane, "MoneyInputFrameTemplate")
    pane.price:SetPoint("LEFT", pane.priceLabel, "LEFT", 62, 0)
    -- A change that is just the price SetPrice wrote isn't the player's.
    local function PriceChanged()
        if pane.settingPrice or MoneyInputFrame_GetCopper(pane.price) == pane.writtenPrice then return end
        pane.autoPrice, pane.target = false, nil
        addon:Refresh()
    end
    if MoneyInputFrame_SetOnValueChangedFunc then
        MoneyInputFrame_SetOnValueChangedFunc(pane.price, PriceChanged)
    else
        pane.price.onValueChangedFunc = PriceChanged
    end

    pane.durationLabel = UI.Text(pane, "GameFontHighlight")
    pane.durationLabel:SetText("Duration")
    pane.durationLabel:SetPoint("TOPLEFT", pane.priceLabel, "BOTTOMLEFT", 0, -16)
    pane.duration = CreateFrame("DropdownButton", nil, pane, "WowStyle1DropdownTemplate")
    pane.duration:SetWidth(120)
    pane.duration:SetPoint("RIGHT", pane, "RIGHT", -10, 0)
    pane.duration:SetPoint("TOP", pane.durationLabel, "TOP", 0, 5)
    pane.duration:SetupMenu(function(_, root)
        for index, label in ipairs(DURATIONS) do
            root:CreateRadio(label, function() return addon.db.duration == index end, function()
                addon.db.duration = index
                addon:Refresh()
            end)
        end
    end)

    pane.depositLabel, pane.deposit = Line(pane, "Deposit", pane.durationLabel, 14)
    pane.profitLabel, pane.profit = Line(pane, "Profit after the cut", pane.depositLabel, 6)

    pane.next = UI.Button(pane, "Next", 72, 26)
    pane.next:SetPoint("BOTTOMLEFT", 8, 8)
    pane.next:SetScript("OnClick", function()
        local nextItem = NextSellable(pane.itemID)
        if nextItem then
            addon:Select(nextItem, "sell")
        else
            addon:SetStatus("Nothing to sell from your lists is in your bags")
        end
    end)
    pane.next:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Next", "The next item on your lists that is in your bags; lists not for sale are skipped")
    end)
    pane.next:SetScript("OnLeave", GameTooltip_Hide)

    pane.post = UI.Button(pane, "Post", 160, 26)
    pane.post:SetPoint("LEFT", pane.next, "RIGHT", 6, 0)
    pane.post:SetPoint("RIGHT", -8, 0)
    pane.post:SetScript("OnClick", function() pane:Post() end)

    -- What the hotkey clicks here, a button of no size: Post when it can;
    -- else Next, once none of the item is left in your bags or none is
    -- picked. While its price is coming, nothing.
    pane.hotkeyButton = CreateFrame("Button", "RichSnobsAHSellNext", pane)
    pane.hotkeyButton:SetScript("OnClick", function()
        if pane.post:IsEnabled() then
            pane:Post()
        elseif not (pane.itemID and addon:FindInBags(pane.itemID, true)) then
            pane.next:Click()
        end
    end)

    function pane:GetPrice()
        return MoneyInputFrame_GetCopper(self.price) or 0
    end

    function pane:SetPrice(copper)
        if self:GetPrice() == copper then return end
        self.writtenPrice = copper
        self.settingPrice = true
        MoneyInputFrame_SetCopper(self.price, copper)
        self.settingPrice = false
    end

    function pane:SetItem(itemID)
        if self.itemID == itemID then return end
        self.itemID = itemID
        self.autoPrice, self.autoQuantity, self.target = true, true, nil
        self:SetPrice(0)
        if itemID and Auction.isOpen then Auction:Search(itemID) end
    end

    function pane:Post()
        local itemID = self.itemID
        local location = itemID and addon:FindInBags(itemID, true)
        if not location then
            addon:SetStatus("None of these in your bags can be sold")
            return
        end
        local commodity = addon:IsCommodity(itemID, location)
        if commodity == nil then
            local result = Auction.results[itemID]
            commodity = result and result.commodity
        end
        if commodity == nil then
            addon:SetStatus("Search this item first, so the auction house says how it sells")
            return
        end
        local quantity = 1
        if commodity then
            -- What the button shows: the typed number, capped at what can be posted.
            local ok, most = pcall(C_AuctionHouse.GetAvailablePostCount, location)
            quantity = math.min(tonumber(self.quantity:GetText()) or 0, ok and most or addon:BagCount(itemID))
        end
        local unit = self:GetPrice()
        if quantity < 1 or unit < 1 then return end
        if Auction:Post(itemID, location, commodity, quantity, unit, addon.db.duration) then
            self.autoQuantity = true
        end
    end

    function pane:Refresh()
        if not self:IsVisible() then return end
        local itemID = addon.selected and addon.selected.itemID
        self:SetItem(itemID)

        local location = itemID and addon:FindInBags(itemID, Auction.isOpen)
        local result = itemID and Auction.results[itemID]
        local commodity = result and result.commodity
        if commodity == nil and itemID then commodity = addon:IsCommodity(itemID, location) end
        local count = itemID and addon:BagCount(itemID) or 0

        local message
        if not itemID then
            message = "Pick an item in a list, right-click one in your bags, or press Next"
        elseif not result then
            message = Auction.searching == itemID and "Searching..." or "Not searched yet"
        elseif #result.rows == 0 then
            message = "Nobody is selling this"
        end
        self.header:SetItem(itemID, itemID and ("%d in your bags"):format(count) or "")
        -- The clicked offer stays marked through new searches while its price is up.
        local target
        for _, row in ipairs(self.target and result and result.rows or {}) do
            if row.unit == self.target then
                target = row
                break
            end
        end
        self.ladder:SetData(result and result.rows, commodity ~= false, target, message)

        local most = 0
        if location then
            if commodity then
                local ok, n = pcall(C_AuctionHouse.GetAvailablePostCount, location)
                most = ok and n or count
            else
                most = 1
            end
        end
        if self.autoQuantity and not self.quantity:HasFocus() then
            local text = tostring(most)
            if self.quantity:GetText() ~= text then self.quantity:SetText(text) end
        end
        local quantity = math.min(tonumber(self.quantity:GetText()) or 0, most)
        local perPost = commodity == false
        self.quantityNote:SetText(perPost and "one per post" or commodity and ("of %d"):format(most) or "")
        self.quantityNote:ClearAllPoints()
        self.quantityNote:SetPoint("RIGHT", self.max, perPost and "RIGHT" or "LEFT", perPost and 0 or -6, 0)
        self.quantity:SetShown(not perPost)
        self.max:SetShown(not perPost)

        if self.autoPrice and itemID then
            local price = Auction:SuggestPrice(itemID, commodity) or addon:GetAHPrice(itemID)
            if price and commodity == false then price = math.max(100, math.floor(price / 100) * 100) end
            if price then self:SetPrice(math.floor(price)) end
        end
        local unit = self:GetPrice()

        local deposit = itemID and quantity > 0 and Auction:Deposit(itemID, location, commodity, addon.db.duration, quantity)
        self.deposit:SetText(deposit and addon.Money(deposit, true) or "")
        -- The Stay cheapest tab sets the same duration.
        self.duration:Update()

        local craft = addon:CraftFor(itemID)
        local cost, complete
        if craft then cost, complete = addon:CraftCost(craft) end
        if cost and complete and unit > 0 and quantity > 0 then
            local profit = (unit * 0.95 - cost) * quantity
            self.profit:SetText(addon.Money(profit))
            self.profit:SetTextColor(unpack(profit >= 0 and GREEN or RED))
        else
            self.profit:SetText(craft and "no cost yet" or "not a craft")
            self.profit:SetTextColor(0.5, 0.5, 0.5)
        end

        local busy = Auction.posting ~= nil or Auction:Busy()
        self.post:SetText(quantity > 0 and unit > 0 and ("Post %d for %s"):format(quantity, addon.Money(unit * quantity))
            or "Post")
        self.post:SetEnabled(location ~= nil and commodity ~= nil and quantity > 0 and unit > 0
            and Auction:CanAct() and not busy)
    end

    pane:SetScript("OnShow", function(self)
        if self.itemID and Auction.isOpen and not Auction.results[self.itemID] then Auction:Search(self.itemID) end
        self:Refresh()
    end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
