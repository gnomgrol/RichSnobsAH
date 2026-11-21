-- The one window: your lists, the craft queue, the price lookup or your
-- sales on the left; Buy, Sell, Auctions, Snipe and Stay cheapest on the
-- right; above them a bar with the status line and the Full Auction House
-- Scan. At the auction house it all sits in a fourth tab of Blizzard's
-- auction frame, after Buy, Sell and Auctions. Away from it, the left side
-- is a window of its own that can be moved. Both show the same frames,
-- moved to whichever is open.

local _, addon = ...
local UI = addon.UI

local LEFT_WIDTH = 538 -- room for the list rows' indent
local WIDTH = 8 + LEFT_WIDTH + 8
local HEIGHT = 488

-- The panes start below the bar. In the auction frame the bar clears its
-- portrait, the tab ends where Blizzard's own tabs end, above its money
-- display, and the frame widens for the right side.
local CONTENT_TOP = 58
local PORTRAIT_WIDTH = 58
local TAB_BOTTOM = 27
local TAB_EXTRA_WIDTH = 200

local SCAN_TEXT = "Full Auction House Scan"

local frame          -- the window, away from the auction house
local content        -- the panes and the status line, in the window or the tab
local panel, mode    -- the auction frame's fourth tab and its display mode
local reopenWindow = false -- the window was open when the auction house opened
local panelHiddenAt  -- GetTime() when the tab last hid

local function AtAuctionHouse()
    return panel ~= nil and addon.Auction.isOpen and AuctionHouseFrame:IsShown()
end

local function ShowTab(index)
    frame.buy:SetShown(index == 1)
    frame.sell:SetShown(index == 2)
    frame.auctions:SetShown(index == 3)
    frame.snipe:SetShown(index == 4)
    frame.stay:SetShown(index == 5)
end

-- Picking Prices puts the cursor in its search box.
local function ShowLeftTab(index)
    frame.list:SetShown(index == 1)
    frame.queue:SetShown(index == 2)
    frame.prices:SetShown(index == 3)
    frame.sales:SetShown(index == 4)
    if index == 3 and content:IsVisible() then frame.prices.search:SetFocus() end
end

local function UpdateStatus()
    if not frame then return end
    local status = addon.status or {}
    frame.statusText:SetText(status.text or "")
    if status.total and status.total > 0 then
        frame.progress:SetValue(status.done / status.total)
        frame.progress:Show()
    else
        frame.progress:Hide()
    end
end

-- The house allows one full scan per 15 minutes; the button counts down.
local function UpdateScanAll()
    local wait = addon.Auction:FullScanWait()
    local text = wait > 0 and ("%s (%d min)"):format(SCAN_TEXT, math.ceil(wait / 60)) or SCAN_TEXT
    if frame.scanAll:GetText() ~= text then frame.scanAll:SetText(text) end
    frame.scanAll:SetEnabled(addon.Auction.isOpen and wait == 0)
end

-- Puts the content in the window or the tab. Only the tab has the right side
-- and the full scan. The craft buttons are secure, so the content can't move
-- in combat. Returns whether it is in the container.
local function MoveContent(container)
    if InCombatLockdown() then return content:GetParent() == container end
    local inTab = container == panel
    content:SetParent(container)
    content:SetFrameLevel(container:GetFrameLevel() + 1)
    content:ClearAllPoints()
    if inTab then
        content:SetAllPoints()
    else
        content:SetPoint("TOPLEFT", 8, -CONTENT_TOP)
        content:SetPoint("BOTTOMRIGHT", -8, 8)
    end
    frame.bar:SetPoint("BOTTOMLEFT", content, "TOPLEFT", inTab and PORTRAIT_WIDTH or 0, 7)
    frame.right:SetShown(inTab)
    frame.scanAll:SetShown(inTab)
    if inTab then
        frame.progress:SetPoint("RIGHT", frame.scanAll, "LEFT", -10, 0)
    else
        frame.progress:SetPoint("RIGHT", frame.bar, "RIGHT")
    end
    if panel then panel.note:SetShown(not inTab) end
    return true
end

local function Create()
    frame = CreateFrame("Frame", "RichSnobsAHFrame", UIParent, "ButtonFrameTemplate")
    frame:Hide()
    ButtonFrameTemplate_HidePortrait(frame)
    ButtonFrameTemplate_HideButtonBar(frame)
    frame.Inset:Hide()
    frame:SetTitle("RichSnobsAH")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
    local saved = addon.db.window
    if saved then
        frame:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
    else
        frame:SetPoint("CENTER")
    end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        addon.db.window = { point = point, relativePoint = relativePoint, x = x, y = y }
    end)
    tinsert(UISpecialFrames, frame:GetName())

    content = CreateFrame("Frame", nil, frame)

    -- The bar over the panes. MoveContent places its left end, and the
    -- progress bar's right end, for the window or the tab.
    frame.bar = CreateFrame("Frame", nil, content)
    frame.bar:SetHeight(22)
    frame.bar:SetPoint("BOTTOMRIGHT", content, "TOPRIGHT", 0, 7)

    -- Its right edge lines up with Blizzard's Search button on the Buy tab,
    -- 12 px in from the frame's edge (the tab itself ends 5 px in).
    frame.scanAll = UI.Button(frame.bar, SCAN_TEXT, 230, 22)
    frame.scanAll:SetPoint("RIGHT", -7, 0)
    frame.scanAll:SetScript("OnClick", function() addon.Auction:FullScan() end)
    frame.scanAll:SetScript("OnEnter", function(self)
        UI.Tooltip(self, SCAN_TEXT, "Prices every item on the auction house in one go; allowed once per 15 minutes")
    end)
    frame.scanAll:SetScript("OnLeave", GameTooltip_Hide)
    frame.scanAll:SetMotionScriptsWhileDisabled(true)

    frame.progress = CreateFrame("StatusBar", nil, frame.bar)
    frame.progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.progress:SetStatusBarColor(0.85, 0.7, 0.2)
    frame.progress:SetMinMaxValues(0, 1)
    frame.progress:SetSize(160, 10)
    local background = frame.progress:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.5)
    frame.progress:Hide()

    frame.statusText = UI.Text(frame.bar, "GameFontHighlightSmall")
    frame.statusText:SetPoint("LEFT", 2, 0)
    frame.statusText:SetPoint("RIGHT", frame.progress, "LEFT", -10, 0)

    -- The full scan's countdown ticks once a second while the bar shows.
    local sinceTick = 0
    frame.bar:SetScript("OnUpdate", function(_, elapsed)
        sinceTick = sinceTick + elapsed
        if sinceTick < 1 then return end
        sinceTick = 0
        UpdateScanAll()
    end)

    frame.left = CreateFrame("Frame", nil, content, "InsetFrameTemplate")
    frame.left:SetPoint("TOPLEFT")
    frame.left:SetPoint("BOTTOMLEFT")
    frame.left:SetWidth(LEFT_WIDTH)
    local leftTabBar = CreateFrame("Frame", nil, frame.left)
    leftTabBar:SetPoint("TOPLEFT", 6, -4)
    leftTabBar:SetSize(LEFT_WIDTH - 12, 24)
    frame.list = UI.CreateListPane(frame.left)
    frame.queue = UI.CreateQueuePane(frame.left)
    frame.prices = UI.CreatePricesPane(frame.left)
    frame.sales = UI.CreateSalesPane(frame.left)
    for _, pane in ipairs({ frame.list, frame.queue, frame.prices, frame.sales }) do
        pane:SetPoint("TOPLEFT", 0, -30)
        pane:SetPoint("BOTTOMRIGHT")
    end
    frame.leftTabs = UI.Tabs(leftTabBar, { "Lists", "Queue", "Prices", "Sales" }, ShowLeftTab)
    frame.leftTabs:Select(1)

    -- The right side takes the tab's width left over.
    frame.right = CreateFrame("Frame", nil, content, "InsetFrameTemplate")
    frame.right:SetPoint("TOPLEFT", frame.left, "TOPRIGHT", 6, 0)
    frame.right:SetPoint("BOTTOMRIGHT")
    local tabBar = CreateFrame("Frame", nil, frame.right)
    tabBar:SetPoint("TOPLEFT", 6, -4)
    tabBar:SetPoint("TOPRIGHT", -6, -4)
    tabBar:SetHeight(24)
    frame.buy = UI.CreateBuyPane(frame.right)
    frame.sell = UI.CreateSellPane(frame.right)
    frame.auctions = UI.CreateAuctionsPane(frame.right)
    frame.snipe = UI.CreateSnipePane(frame.right)
    frame.stay = UI.CreateStayPane(frame.right)
    for _, pane in ipairs({ frame.buy, frame.sell, frame.auctions, frame.snipe, frame.stay }) do
        pane:SetPoint("TOPLEFT", 0, -30)
        pane:SetPoint("BOTTOMRIGHT")
    end
    frame.tabs = UI.Tabs(tabBar, { "Buy", "Sell", "Auctions", "Snipe", "Stay cheapest" }, ShowTab)
    frame.tabs:Select(1)

    MoveContent(frame)

    frame:SetScript("OnShow", function() MoveContent(frame) end)
    content:SetScript("OnShow", function()
        UpdateStatus()
        addon:Refresh()
    end)
    content:SetScript("OnHide", function() addon.Auction:CancelQuote() end)

    addon.window = content
end

-- At the auction house, the window is the auction frame's tab.
function addon:ShowWindow()
    if not frame then Create() end
    if AtAuctionHouse() then
        AuctionHouseFrame:SetDisplayMode(mode)
    elseif not InCombatLockdown() then
        frame:Show()
    end
end

function addon:Toggle()
    if AtAuctionHouse() then
        AuctionHouseFrame:SetDisplayMode(panel:IsShown() and AuctionHouseFrameDisplayMode.Buy or mode)
    elseif frame and frame:IsShown() then
        if not InCombatLockdown() then frame:Hide() end
    else
        self:ShowWindow()
    end
end

-- Shows an item in the right pane. tab: "buy" or "sell" switches to it;
-- otherwise Auctions, Snipe and Stay cheapest give way to Buy.
function addon:Select(selection, tab)
    self.selected = selection
    if frame then
        if tab == "buy" then
            frame.tabs:Select(1)
        elseif tab == "sell" then
            frame.tabs:Select(2)
        elseif frame.tabs.selected >= 3 then
            frame.tabs:Select(1)
        end
    end
    self:Refresh()
end

addon:Listen("STATUS", UpdateStatus)
addon:Listen("REFRESH", function()
    if frame then UpdateScanAll() end
end)

-- Alt-click any item, in your bags, a chat link, a profession window or
-- Blizzard's Buy views, for its menu: search for it, or add it to a list.
-- Alt alone, so Alt with Shift or Ctrl stays free for other addons.
local function AltClicked()
    return IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown()
end

-- Most of these clicks come with a link and no frame to own the menu, so all
-- these menus belong to UIParent.
local function OpenItemMenu(itemID)
    if itemID and addon.db then addon:ShowItemMenu(UIParent, itemID) end
end

if HandleModifiedItemClick then
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if AltClicked() and type(link) == "string" then OpenItemMenu((C_Item.GetItemInfoInstant(link))) end
    end)
end

-- Blizzard's right-click menu on an auction house item, the one with Set
-- Favorite, gets an Add to list submenu. It opens on a browse list row, or on
-- the item at the top of an item's view.
if Menu and Menu.ModifyMenu then
    Menu.ModifyMenu("MENU_AUCTION_HOUSE_FAVORITE", function(owner, root)
        local row = owner.GetRowData and owner:GetRowData()
        local key = row and row.itemKey or owner.GetItemKey and owner:GetItemKey()
        if not (key and key.itemID and addon.db) then return end
        root:CreateDivider()
        UI.ListButtons(root:CreateButton("Add to list"), function(list) UI.AddToList(list, key.itemID) end)
    end)
end

-- Shift-click an item, in your bags, a chat link or a profession window, while
-- this tab shows Buy, and it is searched for there, as Blizzard's Buy tab
-- takes it into its search bar. With no chat box open, the game hands the
-- item's name to the auction frame's SetSearchText, which turns it down on
-- this tab; that keeps the name, and the link it came from follows as
-- InsertLink returns, in the same frame.
local shiftName, shiftTime

if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", function(link)
        local name = shiftTime == GetTime() and shiftName
        shiftName = nil
        local itemID = name and type(link) == "string" and C_Item.GetItemInfoInstant(link)
        if itemID and C_Item.GetItemInfo(link) == name then
            addon:Select({ itemID = itemID }, "buy")
            addon.Auction:Search(itemID)
        end
    end)
end

-- Made on the first visit, when Blizzard's auction frame exists. The tab is
-- one of the frame's display modes, like its own three, so Blizzard's tab
-- code shows and hides it.
local function SetUpAuctionHouse()
    if panel then return end
    if not frame then Create() end

    panel = CreateFrame("Frame", nil, AuctionHouseFrame)
    panel:SetPoint("TOPLEFT", 4, -CONTENT_TOP)
    panel:SetPoint("BOTTOMRIGHT", -5, TAB_BOTTOM)
    panel:Hide()
    panel.note = UI.Text(panel, "GameFontDisable", "CENTER")
    panel.note:SetPoint("CENTER")
    panel.note:SetText("Back after combat")
    panel:SetScript("OnShow", function(self) self.note:SetShown(not MoveContent(self)) end)
    panel:SetScript("OnHide", function() panelHiddenAt = GetTime() end)

    mode = { "RichSnobsAHPanel" }
    AuctionHouseFrame.RichSnobsAHPanel = panel
    AuctionHouseFrameDisplayMode.RichSnobsAH = mode

    local tab = CreateFrame("Button", nil, AuctionHouseFrame, "AuctionHouseFrameDisplayModeTabTemplate")
    tab.displayMode = mode
    tab:SetText("RichSnobs")
    tab:SetPoint("LEFT", AuctionHouseFrame.AuctionsTab, "RIGHT", -15, 0)
    -- The tab template joins the frame's Tabs itself.
    local tabs = AuctionHouseFrame.Tabs
    if not tIndexOf(tabs, tab) then tabs[#tabs + 1] = tab end
    tab:SetID(#tabs)
    AuctionHouseFrame.tabsForDisplayMode[mode] = #tabs
    PanelTemplates_SetNumTabs(AuctionHouseFrame, #tabs)
    PanelTemplates_TabResize(tab, 20, nil, 70)
    PanelTemplates_UpdateTabs(AuctionHouseFrame)

    hooksecurefunc(AuctionHouseFrame, "UpdateTitle", function(self)
        if self.displayMode == mode then self:SetTitle("RichSnobsAH") end
    end)

    -- The tab widens the frame for the right side; Blizzard's tabs get the
    -- frame's own width back.
    local width = AuctionHouseFrame:GetWidth()
    hooksecurefunc(AuctionHouseFrame, "SetDisplayMode", function(self)
        self:SetWidth(width + (self.displayMode == mode and TAB_EXTRA_WIDTH or 0))
    end)

    -- On the browse list, an Alt-click opens the menu instead of the item.
    -- Only replacing the method that opens it can stop that; a hook runs after.
    local browse = AuctionHouseFrame.BrowseResultsFrame
    if browse and type(browse.OnBrowseResultSelected) == "function" then
        local OpenResult = browse.OnBrowseResultSelected
        function browse:OnBrowseResultSelected(result, ...)
            if AltClicked() and result and result.itemKey then return OpenItemMenu(result.itemKey.itemID) end
            return OpenResult(self, result, ...)
        end
    end

    -- The view of one item: an Alt-click on one of its offers selects it, and
    -- one on the item at the top does nothing; the menu comes along with both.
    -- Blizzard selects an offer itself when a search answer names one, so only
    -- a selection with the pointer on the list counts as a click.
    local function HookOffers(list)
        if not (list and type(list.SetSelectedEntry) == "function") then return end
        hooksecurefunc(list, "SetSelectedEntry", function(self, row)
            if row and AltClicked() and self:IsMouseOver() then
                OpenItemMenu(row.itemID or row.itemKey and row.itemKey.itemID)
            end
        end)
    end
    -- Its icon hands clicks to the display's method, not its script, so the
    -- icon gets the hook too.
    local function HookItemDisplay(display)
        if not (display and display.HookScript) then return end
        local function OnClick(_, button)
            if button ~= "LeftButton" or not AltClicked() then return end
            local key = display:GetItemKey()
            OpenItemMenu(key and key.itemID or display:GetItemID())
        end
        display:HookScript("OnClick", OnClick)
        if display.ItemButton then display.ItemButton:HookScript("OnClick", OnClick) end
    end
    local itemBuy, commoditiesBuy = AuctionHouseFrame.ItemBuyFrame, AuctionHouseFrame.CommoditiesBuyFrame
    HookOffers(itemBuy and itemBuy.ItemList)
    HookOffers(commoditiesBuy and commoditiesBuy.ItemList)
    HookItemDisplay(itemBuy and itemBuy.ItemDisplay)
    HookItemDisplay(commoditiesBuy and commoditiesBuy.BuyDisplay and commoditiesBuy.BuyDisplay.ItemDisplay)

    if type(AuctionHouseFrame.SetSearchText) == "function" then
        hooksecurefunc(AuctionHouseFrame, "SetSearchText", function(self, text)
            if self.displayMode == mode and frame.tabs.selected == 1 then shiftName, shiftTime = text, GetTime() end
        end)
    end

    -- A right-click on a bag item puts it in Blizzard's sell slot and switches
    -- to Blizzard's sell view. When that took you off this tab, in this very
    -- frame, the slot is emptied again, the tab comes back, and the item goes
    -- to its Sell pane instead.
    hooksecurefunc(AuctionHouseFrame, "SetPostItem", function(self, itemLocation)
        if panelHiddenAt ~= GetTime() or not self:IsListingAuctions() then return end
        self:ClearPostItem()
        self:SetDisplayMode(mode)
        if itemLocation and itemLocation:IsValid() and C_AuctionHouse.IsSellItemValid(itemLocation, false) then
            addon:Select({ itemID = C_Item.GetItemID(itemLocation) }, "sell")
        end
    end)
end

-- Blizzard's frame shows on the same event and opens on Buy, so this waits a
-- frame. The window gives way to the tab, which opens when the window was
-- open or the auction house last closed on it.
addon:Listen("AH_SHOW", function()
    C_Timer.After(0, function()
        if not AuctionHouseFrame then return end
        SetUpAuctionHouse()
        reopenWindow = frame:IsShown()
        if reopenWindow and not InCombatLockdown() then frame:Hide() end
        if reopenWindow or addon.db.auctionTab then AuctionHouseFrame:SetDisplayMode(mode) end
    end)
end)

addon:Listen("AH_HIDE", function()
    if panel then addon.db.auctionTab = AuctionHouseFrame.displayMode == mode or nil end
    if reopenWindow and not InCombatLockdown() then frame:Show() end
    reopenWindow = false
end)

-- The window closes when combat starts, as it always has. Before combat
-- locks the secure craft buttons, the content also leaves the auction frame,
-- whose tab then says it comes back after combat.
addon:On("PLAYER_REGEN_DISABLED", function()
    if not frame then return end
    MoveContent(frame)
    frame:Hide()
end)

addon:On("PLAYER_REGEN_ENABLED", function()
    if panel and panel:IsShown() then MoveContent(panel) end
end)
