-- The DE buy tab, at the auction house: the deals of the last scan, most
-- profit first, each with how many of its auctions pay once they were
-- searched, its price, what its materials bring after the cut, and the
-- profit, also as a percent of the price; hover one for its materials. A
-- click chooses a deal for the big button over the top one, and a click on
-- it again lets go. Below them what to scan for: a range of the item level
-- bands the materials change at and the best quality; armor, weapons, and
-- whether you disenchant at an Arcane Salvager, which makes greens worth
-- more; the least profit, the price the big button asks first above, and
-- the Scan button, which pauses a scan that runs so its deals so far can be
-- bought, and resumes it. Then the scan's progress, or the last scan's
-- state, and the big button, which buys the marked deal, an item a click.

local _, addon = ...
local UI = addon.UI
local Auction = addon.Auction
local DE = addon.Disenchant

local ROW_HEIGHT = 20
local HEADS = { "Price", "Value", "Profit", "%" }
local WIDTHS = { 64, 64, 64, 40 } -- the three price columns, then the profit's percent of the price
local RARITIES = { { quality = 2, label = "Green" }, { quality = 3, label = "Blue" }, { quality = 4, label = "Epic" } }

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
    if deal and not UI.ModifiedClick(deal.itemID) then DE:Choose(deal.itemID) end
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
    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints()
    row.selection:SetColorTexture(1, 0.82, 0, 0.18)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.cells = {}
    local right = -2
    for i = #WIDTHS, 1, -1 do
        local cell = UI.Text(row, nil, "RIGHT")
        cell:SetWidth(WIDTHS[i] - 4)
        cell:SetPoint("RIGHT", right, 0)
        right = right - WIDTHS[i]
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
        row.selection:Hide()
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
    -- and its item level, then price, value and profit, in gold and as a
    -- percent of the price. The big button's deal is marked.
    local deal = data.deal
    row.icon:SetTexture(addon:ItemIcon(deal.itemID))
    row.icon:Show()
    row.selection:SetShown(data.target)
    row.name:SetFontObject("GameFontHighlightSmall")
    row.name:SetTextColor(QualityColor(deal.quality))
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetText(("%s%s  |cff808080%d|r"):format(addon:ItemName(deal.itemID) or "...",
        deal.count and (" x%d"):format(deal.count) or "", deal.level))
    for _, cell in ipairs(row.cells) do cell:SetFontObject("GameFontHighlightSmall") end
    SetCell(row, 1, addon.Money(deal.price))
    SetCell(row, 2, addon.Money(deal.value))
    SetCell(row, 3, addon.Money(deal.profit), GREEN)
    SetCell(row, 4, ("%d%%"):format(math.floor(deal.profit / deal.price * 100 + 0.5)), GREEN)
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

-- A dropdown of the best quality the scan looks for.
local function RarityMenu(parent)
    local menu = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    menu:SetWidth(70)
    menu:SetupMenu(function(_, root)
        for _, rarity in ipairs(RARITIES) do
            root:CreateRadio(rarity.label, function() return addon.db.disenchant.maxQuality == rarity.quality end,
                function() DE:Set("maxQuality", rarity.quality) end)
        end
    end)
    menu:HookScript("OnEnter", function(self) UI.Tooltip(self, "Max rarity", "The best quality the scan looks for") end)
    menu:HookScript("OnLeave", GameTooltip_Hide)
    return menu
end

-- An edit box for a price setting, like 1g 50s, or 0: it sets it on losing
-- focus and shows it again afterwards; Escape throws the typing away.
local function MoneyBox(parent, width, key)
    local function Shown() return UI.PlainMoney(addon.db.disenchant[key]) end
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetScript("OnEditFocusLost", function(self)
        local text = self:GetText()
        local copper = UI.ParseMoney(text) or (tonumber(text) == 0 and 0)
        if copper then DE:Set(key, copper) end
        self:SetText(Shown())
    end)
    box:SetScript("OnEnterPressed", EditBox_ClearFocus)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText(Shown())
        self:ClearFocus()
    end)
    -- The setting, unless you're typing.
    function box:Update()
        if not self:HasFocus() then self:SetText(Shown()) end
    end
    return box
end

-- The big button's deal: the one being bought, else the one you chose, else
-- the top one.
local function NextDeal(deals)
    local item = Auction.buying
    for _, deal in ipairs(deals) do
        if item and item.itemID == deal.itemID then return deal end
    end
    return DE:Chosen() or deals[1]
end

-- What a click on the big button does, and whether it can. While a scan
-- runs, the deals wait for it before they are checked, unless it is paused.
local function BuyWords(deal)
    local name = addon:ItemName(deal.itemID) or "..."
    local item = Auction.buying
    if item and item.itemID == deal.itemID then return ("Buying %s..."):format(name), false end
    if not deal.row and Auction.isOpen and (not DE.scanning or DE.paused) then
        return ("Checking %s..."):format(name), false
    end
    return ("Buy %s for %s (+%s)"):format(name, addon.Money(deal.price), addon.Money(deal.profit)),
        deal.row ~= nil and Auction:CanAct() and not Auction:Busy()
end

-- "28% more" or "5% less" than a ratio of 1.
local function More(ratio)
    local percent = math.floor((ratio - 1) * 100 + 0.5)
    if percent < 0 then return ("%d%% less"):format(-percent) end
    return ("%d%% more"):format(percent)
end

-- "0.4 more" or "0.2 fewer" materials.
local function Extra(units)
    if units < 0 then return ("%.1f fewer"):format(-units) end
    return ("%.1f more"):format(units)
end

-- What the Salvager tick counts greens at and where that comes from, then
-- your greens disenchanted so far against the tables; for both Disenchant
-- tabs' ticks.
function UI.SalvagerLines()
    local there, elsewhere = addon.db.disenchanted.salvager, addon.db.disenchanted.plain
    local lines = {
        ("You disenchant at one: greens give %g more dust or essence on average"):format(DE.SALVAGER_BONUS),
        "Players' data from 7,000+ disenchants; shards stay the same",
    }
    if there.count > 0 then
        lines[#lines + 1] = ("Yours so far: %s a disenchant, from %d"):format(
            Extra((there.got - there.expected) / there.count), there.count)
    end
    if elsewhere.count > 0 then
        lines[#lines + 1] = ("Your %d elsewhere gave %s than expected"):format(elsewhere.count,
            More(elsewhere.got / elsewhere.expected))
    end
    return unpack(lines)
end

-- A scan's progress: "Step 2 of 4: greens, 1,500 items", or "Paused at
-- step 2 of 4: ...".
local function Progress(progress, paused)
    local text = (paused and "Paused at step %d of %d: %s" or "Step %d of %d: %s")
        :format(progress.step, progress.steps, progress.what)
    if not (progress.items and progress.items > 0) then return paused and text or text .. "..." end
    return ("%s, %s items"):format(text, BreakUpLargeNumbers(progress.items))
end

function UI.CreateDisenchantPane(parent)
    local pane = CreateFrame("Frame", nil, parent)
    local function Settings() return addon.db.disenchant end

    pane.scrollBox = CreateFrame("Frame", nil, pane, "WowScrollBoxList")
    pane.scrollBar = CreateFrame("EventFrame", nil, pane, "MinimalScrollBar")
    UI.PlaceScrollList(pane.scrollBox, pane.scrollBar, -4, 168)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", UpdateRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(pane.scrollBox, pane.scrollBar, view)

    pane.message = UI.Text(pane, "GameFontDisableSmall", "CENTER")
    pane.message:SetPoint("TOP", 0, -40)

    -- What to look for: the item level bands and the best quality...
    pane.levelLabel = UI.Text(pane, "GameFontHighlight")
    pane.levelLabel:SetPoint("BOTTOMLEFT", 10, 144)
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
    pane.rarityLabel = UI.Text(pane, "GameFontHighlight")
    pane.rarityLabel:SetPoint("LEFT", pane.toBand, "RIGHT", 16, 0)
    pane.rarityLabel:SetText("Max rarity")
    pane.rarity = RarityMenu(pane)
    pane.rarity:SetPoint("LEFT", pane.rarityLabel, "RIGHT", 8, 0)

    -- ...armor, weapons, and whether you disenchant at an Arcane Salvager...
    pane.armor = UI.Check(pane, "Armor", function(on) DE:Set("armor", on) end)
    pane.armor:SetPoint("BOTTOMLEFT", 6, 108)
    pane.weapons = UI.Check(pane, "Weapons", function(on) DE:Set("weapons", on) end)
    pane.weapons:SetPoint("LEFT", pane.armor.label, "RIGHT", 14, -1)
    pane.salvager = UI.Check(pane, "Salvager", function(on) DE:Set("salvager", on) end)
    pane.salvager:SetPoint("LEFT", pane.weapons.label, "RIGHT", 14, -1)
    pane.salvager:SetScript("OnEnter", function(self) UI.Tooltip(self, "Arcane Salvager", UI.SalvagerLines()) end)
    pane.salvager:SetScript("OnLeave", GameTooltip_Hide)

    -- ...the least profit a deal leaves, the price the big button asks first
    -- above, and the Scan button.
    pane.profitLabel = UI.Text(pane, "GameFontHighlight")
    pane.profitLabel:SetPoint("BOTTOMLEFT", 10, 86)
    pane.profitLabel:SetText("Min profit")
    pane.minProfit = MoneyBox(pane, 80, "minProfit")
    pane.minProfit:SetPoint("LEFT", pane.profitLabel, "RIGHT", 10, 0)
    pane.minProfit:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Min profit", "Like 1g 50s, or 0 for any profit")
    end)
    pane.minProfit:SetScript("OnLeave", GameTooltip_Hide)

    pane.askLabel = UI.Text(pane, "GameFontHighlight")
    pane.askLabel:SetPoint("LEFT", pane.minProfit, "RIGHT", 14, 0)
    pane.askLabel:SetText("Ask over")
    pane.askOver = MoneyBox(pane, 60, "askOver")
    pane.askOver:SetPoint("LEFT", pane.askLabel, "RIGHT", 10, 0)
    pane.askOver:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Ask over", "Buying one dearer asks first; 0 never asks")
    end)
    pane.askOver:SetScript("OnLeave", GameTooltip_Hide)

    pane.scan = UI.Button(pane, "Scan", 100, 22)
    pane.scan:SetPoint("BOTTOMRIGHT", -8, 80)
    -- While a scan runs, the button pauses it, and resumes it; its tooltip
    -- follows a click under the pointer.
    local function ScanTip(button)
        if DE.paused then
            UI.Tooltip(button, "Resume", "Goes on with the scan")
        elseif DE.scanning then
            UI.Tooltip(button, "Pause", "Holds the scan so you can buy the deals so far")
        end
    end
    pane.scan:SetScript("OnClick", function(self)
        if DE.paused then
            DE:Resume()
        elseif DE.scanning then
            DE:Pause()
        else
            DE:Scan()
        end
        if self:IsMouseOver() then ScanTip(self) end
    end)
    pane.scan:SetScript("OnEnter", ScanTip)
    pane.scan:SetScript("OnLeave", GameTooltip_Hide)

    -- The scan's progress; after it, how many deals in how many items, and when.
    pane.state = UI.Text(pane, "GameFontHighlight")
    pane.state:SetPoint("BOTTOMLEFT", 10, 60)
    pane.state:SetPoint("RIGHT", -8, 0)

    -- One big button for the marked deal, as on the Snipe tab, and what the
    -- hotkey clicks here. One dearer than Ask over asks first.
    pane.buyNext = UI.Button(pane, "No deals", 120, 40, "RichSnobsAHDEBuyNext")
    pane.hotkeyButton = pane.buyNext
    pane.buyNext:SetPoint("BOTTOMLEFT", 8, 8)
    pane.buyNext:SetPoint("RIGHT", -8, 0)
    pane.buyNext:SetNormalFontObject("GameFontNormalLarge")
    pane.buyNext:SetHighlightFontObject("GameFontHighlightLarge")
    pane.buyNext:SetDisabledFontObject("GameFontDisableLarge")
    pane.buyNext:SetScript("OnClick", function(self)
        local deal = self.deal
        if not deal then return end
        local askOver = Settings().askOver
        if askOver > 0 and deal.price > askOver then
            addon:Confirm(("Buy %s for %s (+%s)?"):format(addon:ItemName(deal.itemID) or "...",
                addon.Money(deal.price), addon.Money(deal.profit)), function() DE:Buy(deal) end)
        else
            DE:Buy(deal)
        end
    end)
    pane.buyNext:SetScript("OnEnter", function(self)
        UI.Tooltip(self, "Buy", "One item of the marked deal: the top one, or one you click")
    end)
    pane.buyNext:SetScript("OnLeave", GameTooltip_Hide)

    -- The deal it shows is kept for the click, so it buys what it says.
    function pane:UpdateBuyNext(deal)
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
            self.state:SetText(DE.scanning and Progress(DE.progress, DE.paused) or "")
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
        local target = NextDeal(deals)
        local elements = {}
        if #deals > 0 then
            elements[1] = { kind = "head", count = #deals }
            for _, deal in ipairs(deals) do
                elements[#elements + 1] = { kind = "deal", deal = deal, target = deal == target }
            end
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
        self.rarity:Update()
        self.minProfit:Update()
        self.askOver:Update()
        self.scan:SetText(DE.paused and "Resume" or DE.scanning and "Pause" or "Scan")
        self.scan:SetEnabled(DE.scanning or Auction.isOpen and (settings.armor or settings.weapons))
        self:UpdateBuyNext(target)
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
