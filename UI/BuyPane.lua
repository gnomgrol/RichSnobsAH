-- The Buy tab: the selected item's cheapest offers, and buying them.
-- Commodities: a quantity, prefilled with what the list is missing, bought
-- in two clicks (a price quote for the whole quantity, then Confirm).
-- Items: pick an auction, bought by its ID.

local _, addon = ...
local UI = addon.UI
local Auction = addon.Auction

-- What the selected list's planned crafts still lack, or one when the list
-- doesn't use the item.
local function DefaultQuantity(itemID)
    local list = addon.selected and addon.selected.list
    if list and addon:Need(list, itemID) > 0 then return addon:Missing(list, itemID) end
    return 1
end

-- The commodity cost of a quantity from the offers shown: a preview only,
-- the quote decides.
local function Estimate(rows, quantity)
    local left, total = quantity, 0
    for _, row in ipairs(rows) do
        if not row.own then
            local take = math.min(left, row.quantity)
            total = total + take * row.unit
            left = left - take
            if left == 0 then break end
        end
    end
    return total, quantity - left
end

function UI.CreateBuyPane(parent)
    local pane = CreateFrame("Frame", nil, parent)

    pane.header = UI.ItemHeader(pane)
    pane.header:SetPoint("TOPLEFT", 6, -4)
    pane.header:SetPoint("TOPRIGHT", -6, -4)

    pane.ladder = UI.Ladder(pane, 12, function(row)
        if row.auctionID and not row.own then
            pane.pickedID = row.auctionID
            pane:Refresh()
        end
    end)
    pane.ladder:SetPoint("TOPLEFT", pane.header, "BOTTOMLEFT", 0, -6)
    pane.ladder:SetPoint("TOPRIGHT", pane.header, "BOTTOMRIGHT", 0, -6)

    pane.quantityLabel = UI.Text(pane, "GameFontHighlight")
    pane.quantityLabel:SetText("Quantity")
    pane.quantityLabel:SetPoint("TOPLEFT", pane.ladder, "BOTTOMLEFT", 4, -12)
    pane.quantity = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    pane.quantity:SetSize(70, 20)
    pane.quantity:SetAutoFocus(false)
    pane.quantity:SetNumeric(true)
    pane.quantity:SetMaxLetters(6)
    pane.quantity:SetPoint("RIGHT", pane.ladder, "RIGHT", -4, 0)
    pane.quantity:SetPoint("TOP", pane.quantityLabel, "TOP", 0, 4)
    pane.quantity:SetScript("OnTextChanged", function(_, userInput)
        if not userInput then return end
        pane.autoQuantity = false
        Auction:CancelQuote()
        addon:Refresh()
    end)
    pane.quantity:SetScript("OnEnterPressed", EditBox_ClearFocus)
    pane.quantity:SetScript("OnEscapePressed", EditBox_ClearFocus)

    pane.note = UI.Text(pane, "GameFontDisableSmall")
    pane.note:SetPoint("TOPLEFT", pane.quantityLabel, "BOTTOMLEFT", 0, -6)
    pane.note:SetPoint("RIGHT", pane.ladder, "RIGHT", -4, 0)

    pane.totalLabel = UI.Text(pane, "GameFontHighlight")
    pane.totalLabel:SetPoint("TOPLEFT", pane.note, "BOTTOMLEFT", 0, -10)
    pane.total = UI.Text(pane, "GameFontHighlight", "RIGHT")
    pane.total:SetPoint("RIGHT", pane.ladder, "RIGHT", -4, 0)
    pane.total:SetPoint("TOP", pane.totalLabel, "TOP")

    pane.search = UI.Button(pane, "Search", 72, 26)
    pane.search:SetPoint("BOTTOMLEFT", 8, 8)
    pane.search:SetScript("OnClick", function() Auction:Search(pane.itemID) end)

    pane.buy = UI.Button(pane, "Buy", 160, 26)
    pane.buy:SetPoint("LEFT", pane.search, "RIGHT", 6, 0)
    pane.buy:SetPoint("RIGHT", -8, 0)
    pane.buy:SetScript("OnClick", function() pane:Buy() end)

    -- The auction to buy: the one picked, else the cheapest that isn't yours.
    function pane:PickedRow(result)
        local first
        for _, row in ipairs(result.rows) do
            if not row.own then
                if row.auctionID == self.pickedID then return row end
                first = first or row
            end
        end
        return first
    end

    function pane:Buy()
        local itemID = self.itemID
        local result = itemID and Auction.results[itemID]
        if not result then return end
        if result.commodity then
            local quote = Auction.quote
            if quote and quote.itemID == itemID and quote.total then
                Auction:ConfirmBuy()
            else
                local quantity = tonumber(self.quantity:GetText())
                if quantity and quantity > 0 then Auction:StartBuy(itemID, quantity) end
            end
        else
            local row = self:PickedRow(result)
            if row then Auction:BuyAuction(itemID, row) end
        end
    end

    function pane:SetItem(itemID)
        if self.itemID == itemID then return end
        Auction:CancelQuote()
        self.itemID = itemID
        self.pickedID = nil
        self.autoQuantity = true
        if itemID and Auction.isOpen then Auction:Search(itemID) end
    end

    function pane:UpdateCommodity(itemID, result)
        local quote = Auction.quote
        local quoted = quote and quote.itemID == itemID
        if self.autoQuantity and not quoted and not self.quantity:HasFocus() then
            local quantity = tostring(DefaultQuantity(itemID))
            if self.quantity:GetText() ~= quantity then self.quantity:SetText(quantity) end
        end
        local quantity = tonumber(self.quantity:GetText()) or 0

        local list = addon.selected and addon.selected.list
        if list and addon:Need(list, itemID) > 0 then
            self.note:SetText(("%s is missing %d; %d in your bags"):format(list.name,
                addon:Missing(list, itemID), addon:BagCount(itemID)))
        else
            self.note:SetText(("%d in your bags"):format(addon:BagCount(itemID)))
        end

        if quoted and quote.total then
            self.totalLabel:SetText("Quoted")
            self.total:SetText(addon.Money(quote.total))
        else
            local total, got = Estimate(result and result.rows or {}, quantity)
            self.totalLabel:SetText(got < quantity and ("About (only %d for sale)"):format(got) or "About")
            self.total:SetText(quantity > 0 and got > 0 and addon.Money(total) or "")
        end

        local button = self.buy
        if quoted and quote.pending then
            button:SetText("Getting price...")
            button:Disable()
        elseif quoted and quote.confirming then
            button:SetText("Buying...")
            button:Disable()
        elseif quoted and quote.total then
            button:SetText("Confirm " .. addon.Money(quote.total))
            button:Enable()
        else
            button:SetText(quantity > 0 and ("Buy %d"):format(quantity) or "Buy")
            button:SetEnabled(result and #result.rows > 0 and quantity > 0
                and Auction:CanAct() and not Auction:Busy() or false)
        end
    end

    function pane:UpdateItem(itemID, result)
        local row = result and self:PickedRow(result)
        self.note:SetText(("%d in your bags. Click an auction to pick it."):format(addon:BagCount(itemID)))
        self.totalLabel:SetText(row and "Picked" or "")
        self.total:SetText(row and addon.Money(row.buyout, true) or "")
        self.buy:SetText(row and ("Buy for " .. addon.Money(row.buyout)) or "Buy")
        self.buy:SetEnabled(row and Auction:CanAct() and not Auction:Busy() or false)
    end

    function pane:Refresh()
        if not self:IsVisible() then return end
        local itemID = addon.selected and addon.selected.itemID
        self:SetItem(itemID)

        local result = itemID and Auction.results[itemID]
        local commodity = result and result.commodity
        if commodity == nil and itemID then commodity = addon:IsCommodity(itemID) end

        local message
        if not itemID then
            message = "Pick an item in a list, or Alt-click any item"
        elseif not result then
            message = Auction.searching == itemID and "Searching..." or "Not searched yet"
        elseif #result.rows == 0 then
            message = "None for sale"
        end

        self.header:SetItem(itemID, commodity == true and "Commodity" or commodity == false and "Item" or "")
        self.header:SetShown(itemID ~= nil)
        self.ladder:SetData(result and result.rows, commodity ~= false,
            commodity == false and result and self:PickedRow(result) or nil, message)
        self.search:SetEnabled(itemID ~= nil and Auction:CanAct())

        local isCommodity = commodity ~= false
        self.quantityLabel:SetShown(itemID ~= nil and isCommodity)
        self.quantity:SetShown(itemID ~= nil and isCommodity)
        self.note:SetShown(itemID ~= nil)
        self.totalLabel:SetShown(itemID ~= nil)
        self.total:SetShown(itemID ~= nil)

        if not itemID then
            self.buy:SetText("Buy")
            self.buy:Disable()
        elseif isCommodity then
            self:UpdateCommodity(itemID, result)
        else
            self:UpdateItem(itemID, result)
        end
    end

    pane:SetScript("OnShow", function(self)
        -- Back on this tab: search again what may have changed meanwhile.
        if self.itemID and Auction.isOpen and not Auction.results[self.itemID] then Auction:Search(self.itemID) end
        self:Refresh()
    end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
