-- The Disenchant tab: the deals of the last scan, most profit first, each
-- with how many of its auctions pay once they were searched, its price, what
-- its materials bring after the cut, and the profit; hover one for its
-- materials. Below them what to scan for: armor, weapons, a range of the
-- item level bands the materials change at, and the least profit; whether
-- you disenchant at an Arcane Salvager, which makes greens worth more; and
-- the Scan button. Then the scan's progress, or the last scan's state, and a
-- big button that buys the top deal, an item a click.

local _, addon = ...
local UI = addon.UI
local Auction = addon.Auction
local DE = addon.Disenchant

local ROW_HEIGHT = 20
local CELL = 64 -- each of the three price columns
local HEADS = { "Price", "Value", "Profit" }

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local GREEN = { 0.25, 0.9, 0.25 }

local function SetCell(row, i, text, color)
    local cell = row.cells[i]
    cell:SetText(text or "")
    cell:SetTextColor(unpack(color or WHITE))
end

-- From the browse the deal came from, which needs nothing from the item cache.
local function QualityColor(quality)
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then return color.r, color.g, color.b end
    return 1, 1, 1
end

local function OnRowClick(row)
    local deal = row.data and row.data.deal
    if deal then UI.ModifiedClick(deal.itemID) end
end

-- The item's tooltip names its materials.
local function OnRowEnter(row)
    local deal = row.data and row.data.deal
    if not deal then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(deal.itemID)
    GameTooltip:Show()
end

local function InitRow(row)
    if row.initialized then return end
    row.initialized = true
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

    -- The first row names the columns.
    if data.kind == "head" then
        row.icon:Hide()
        row.name:SetFontObject("GameFontNormal")
        row.name:SetTextColor(unpack(GOLD))
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetText(("Deals  |cff808080%d|r"):format(data.count))
        for i, head in ipairs(HEADS) do
            row.cells[i]:SetFontObject("GameFontNormalSmall")
            SetCell(row, i, head, GOLD)
        end
        return
    end

    -- A deal: the item, how many of its auctions pay once they were searched,
    -- and its item level, then price, value and profit.
    local deal = data.deal
    row.icon:SetTexture(addon:ItemIcon(deal.itemID))
    row.icon:Show()
    row.name:SetFontObject("GameFontHighlightSmall")
    row.name:SetTextColor(QualityColor(deal.quality))
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetText(("%s%s  |cff808080%d|r"):format(addon:ItemName(deal.itemID) or "...",
        deal.count and (" x%d"):format(deal.count) or "", deal.level))
    for i = 1, 3 do row.cells[i]:SetFontObject("GameFontHighlightSmall") end
    SetCell(row, 1, addon.Money(deal.price))
    SetCell(row, 2, addon.Money(deal.value))
    SetCell(row, 3, addon.Money(deal.profit), GREEN)
end

-- A tick box with its label beside it; a click on the label ticks it too.
local function Check(parent, label, onClick)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetSize(24, 24)
    box.label = UI.Text(parent, "GameFontHighlight")
    box.label:SetPoint("LEFT", box, "RIGHT", 2, 1)
    box.label:SetText(label)
    box:SetHitRectInsets(0, -(box.label:GetStringWidth() + 4), 0, 0)
    box:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return box
end

-- A dropdown of the item level bands: isSelected(band), and pick(band) on a click.
local function BandMenu(parent, isSelected, pick)
    local menu = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    menu:SetWidth(70)
    menu:SetupMenu(function(_, root)
        for _, band in ipairs(DE.BANDS) do
            root:CreateRadio(band.label, function() return isSelected(band) end, function() pick(band) end)
        end
    end)
    menu:HookScript("OnEnter", function(self)
        UI.Tooltip(self, "Item level", "Disenchanting goes by item level, not the level to wear")
    end)
    menu:HookScript("OnLeave", GameTooltip_Hide)
    return menu
end

-- An edit box that hands its text to commit when it loses focus, and shows
-- shown() again afterwards; Escape throws the typing away.
local function Box(parent, width, commit, shown)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetScript("OnEditFocusLost", function(self)
        commit(self:GetText())
        self:SetText(shown())
    end)
    box:SetScript("OnEnterPressed", EditBox_ClearFocus)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText(shown())
        self:ClearFocus()
    end)
    return box
end

-- The big button's deal: the one being bought, else the top one.
local function NextDeal(deals)
    local item = Auction.buying
    for _, deal in ipairs(deals) do
        if item and item.itemID == deal.itemID then return deal end
    end
    return deals[1]
end

-- What a click on the big button does, and whether it can. While a scan
-- runs, the deals wait for it before they are checked.
local function BuyWords(deal)
    local name = addon:ItemName(deal.itemID) or "..."
    local item = Auction.buying
    if item and item.itemID == deal.itemID then return ("Buying %s..."):format(name), false end
    if not deal.row and Auction.isOpen and not DE.scanning then return ("Checking %s..."):format(name), false end
    return ("Buy %s for %s (+%s)"):format(name, addon.Money(deal.price), addon.Money(deal.profit)),
        deal.row ~= nil and Auction:CanAct() and not Auction:Busy()
end

-- "28% more" or "5% less" than a ratio of 1.
local function More(ratio)
    local percent = math.floor((ratio - 1) * 100 + 0.5)
    if percent < 0 then return ("%d%% less"):format(-percent) end
    return ("%d%% more"):format(percent)
end

-- What the Salvager tick counts greens at and where that comes from, then
-- your greens disenchanted so far.
local function SalvagerLines()
    local boost, yours = DE:SalvagerBoost()
    local there, elsewhere = addon.db.disenchanted.salvager, addon.db.disenchanted.plain
    local lines = {
        ("You disenchant at one: greens give %s%s"):format(yours and "" or "about ", More(boost)),
        yours and ("Measured on your %d greens disenchanted at one"):format(there.count)
            or ("Players' tests, until you disenchant %d greens at one"):format(DE.MEASURED_AT),
    }
    if not yours and there.count > 0 then
        lines[#lines + 1] = ("Yours so far: %s, from %d"):format(More(there.got / there.expected), there.count)
    end
    if elsewhere.count > 0 then
        lines[#lines + 1] = ("Your %d elsewhere gave %s than expected"):format(elsewhere.count,
            More(elsewhere.got / elsewhere.expected))
    end
    return unpack(lines)
end

-- A scan's progress: "Step 2 of 4: greens, 1,500 items".
local function Progress(progress)
    local text = ("Step %d of %d: %s"):format(progress.step, progress.steps, progress.what)
    if not (progress.items and progress.items > 0) then return text .. "..." end
    return ("%s, %s items"):format(text, BreakUpLargeNumbers(progress.items))
end

function UI.CreateDisenchantPane(parent)
    local pane = CreateFrame("Frame", nil, parent)
    local function Settings() return addon.db.disenchant end

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    UI.PlaceScrollList(pane.scrollBox, pane.scrollBar, -4, 138)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetPoint("TOP", 0, -40)

    -- What to look for: armor, weapons and the item level bands...
    pane.armor = Check(pane, "Armor", function(on) DE:Set("armor", on) end)
    pane.armor:SetPoint("BOTTOMLEFT", 6, 108)
    pane.weapons = Check(pane, "Weapons", function(on) DE:Set("weapons", on) end)
    pane.weapons:SetPoint("LEFT", pane.armor.label, "RIGHT", 14, -1)

    pane.levelLabel = UI.Text(pane, "GameFontHighlight")
    pane.levelLabel:SetPoint("LEFT", pane.weapons.label, "RIGHT", 22, 0)
    pane.levelLabel:SetText("Item level")
    -- From one band's low end to another's high end; the other end moves
    -- along when the two would cross.
    pane.fromBand = BandMenu(pane, function(band) return Settings().minItemLevel == band.low end, function(band)
        local settings = Settings()
        if band.low > settings.maxItemLevel then settings.maxItemLevel = band.high end
        DE:Set("minItemLevel", band.low)
    end)
    pane.fromBand:SetPoint("LEFT", pane.levelLabel, "RIGHT", 8, 0)
    pane.toLabel = UI.Text(pane, "GameFontHighlight")
    pane.toLabel:SetPoint("LEFT", pane.fromBand, "RIGHT", 6, 0)
    pane.toLabel:SetText("to")
    pane.toBand = BandMenu(pane, function(band) return Settings().maxItemLevel == band.high end, function(band)
        local settings = Settings()
        if band.high < settings.minItemLevel then settings.minItemLevel = band.low end
        DE:Set("maxItemLevel", band.high)
    end)
    pane.toBand:SetPoint("LEFT", pane.toLabel, "RIGHT", 6, 0)

    -- ...the least profit a deal leaves, whether you disenchant at an Arcane
    -- Salvager, and the Scan button.
    pane.profitLabel = UI.Text(pane, "GameFontHighlight")
    pane.profitLabel:SetPoint("BOTTOMLEFT", 10, 86)
    pane.profitLabel:SetText("Min profit")
    pane.minProfit = Box(pane, 80, function(text)
        local copper = UI.ParseMoney(text) or (tonumber(text) == 0 and 0)
        if copper then DE:Set("minProfit", copper) end
    end, function() return UI.PlainMoney(Settings().minProfit) end)
    pane.minProfit:SetPoint("LEFT", pane.profitLabel, "RIGHT", 10, 0)
    pane.minProfit:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Min profit", "Like 1g 50s, or 0 for any profit")
    end)
    pane.minProfit:SetScript("OnLeave", GameTooltip_Hide)

    pane.salvager = Check(pane, "Salvager", function(on) DE:Set("salvager", on) end)
    pane.salvager:SetPoint("LEFT", pane.minProfit, "RIGHT", 14, 0)
    pane.salvager:SetScript("OnEnter", function(self) UI.Tooltip(self, "Arcane Salvager", SalvagerLines()) end)
    pane.salvager:SetScript("OnLeave", GameTooltip_Hide)

    pane.scan = UI.Button(pane, "Scan", 100, 22)
    pane.scan:SetPoint("BOTTOMRIGHT", -8, 80)
    pane.scan:SetScript("OnClick", function() DE:Scan() end)

    -- The scan's progress; after it, how many deals in how many items, and when.
    pane.state = UI.Text(pane, "GameFontHighlight")
    pane.state:SetPoint("BOTTOMLEFT", 10, 60)
    pane.state:SetPoint("RIGHT", -8, 0)

    -- One big button for the top deal, as on the Snipe tab.
    pane.buyNext = UI.Button(pane, "No deals", 120, 40)
    pane.buyNext:SetPoint("BOTTOMLEFT", 8, 8)
    pane.buyNext:SetPoint("RIGHT", -8, 0)
    pane.buyNext:SetNormalFontObject("GameFontNormalLarge")
    pane.buyNext:SetHighlightFontObject("GameFontHighlightLarge")
    pane.buyNext:SetDisabledFontObject("GameFontDisableLarge")
    pane.buyNext:SetScript("OnClick", function(self)
        if self.deal then DE:Buy(self.deal) end
    end)
    pane.buyNext:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Buy top deal", "Buys one item: the top deal's cheapest auction")
    end)
    pane.buyNext:SetScript("OnLeave", GameTooltip_Hide)

    -- The deal it shows is kept for the click, so it buys what it says.
    function pane:UpdateBuyNext(deals)
        local deal = NextDeal(deals)
        self.buyNext.deal = deal
        if not deal then
            self.buyNext:SetText("No deals")
            self.buyNext:Disable()
            return
        end
        local text, enabled = BuyWords(deal)
        self.buyNext:SetText(text)
        self.buyNext:SetEnabled(enabled)
    end

    function pane:UpdateState()
        if DE.scanning or not DE.scannedAt then
            self.state:SetText(DE.scanning and Progress(DE.progress) or "")
            return
        end
        self.state:SetText(("%d deals in %d items, scanned %s ago%s"):format(#DE.deals, DE.scanned,
            addon.Age(time() - DE.scannedAt), DE.cutShort and "; the scan was cut short" or ""))
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
        local settings = Settings()
        local deals = DE:Deals()
        local elements = {}
        if #deals > 0 then
            elements[1] = { kind = "head", count = #deals }
            for _, deal in ipairs(deals) do elements[#elements + 1] = { kind = "deal", deal = deal } end
        end
        self.scrollBox:SetDataProvider(CreateDataProvider(elements), ScrollBoxConstants.RetainScrollPosition)

        local message = ""
        if #deals == 0 and not DE.scanning then
            message = DE.scannedAt and "No deals in the last scan"
                or Auction.isOpen and "Pick what to look for, then Scan" or "Scan at the auction house"
        end
        self.message:SetText(message)

        self.armor:SetChecked(settings.armor)
        self.weapons:SetChecked(settings.weapons)
        self.salvager:SetChecked(settings.salvager)
        self.fromBand:Update()
        self.toBand:Update()
        if not self.minProfit:HasFocus() then self.minProfit:SetText(UI.PlainMoney(settings.minProfit)) end
        self.scan:SetText(DE.scanning and "Scanning..." or "Scan")
        self.scan:SetEnabled(not DE.scanning and Auction.isOpen and (settings.armor or settings.weapons))
        self:UpdateBuyNext(deals)
        self:UpdateState()
    end

    -- Back on the tab, the top deals' auctions are looked at again.
    pane:SetScript("OnShow", function(self)
        DE:SearchTop()
        self:Refresh()
    end)
    addon:Listen("REFRESH", function() pane:Refresh() end)

    return pane
end
