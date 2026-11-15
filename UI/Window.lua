-- The one window: your lists, the craft queue or the price lookup on the
-- left; Buy, Sell and My auctions on the right while the auction house is
-- open, docked to the right edge of Blizzard's auction frame at its height.
-- Away from the auction house it shows the left side alone and can be moved.

local _, addon = ...
local UI = addon.UI

local LEFT_WIDTH = 538 -- room for the list rows' indent
local RIGHT_WIDTH = 262
local HEIGHT = 480
local DOCKED_WIDTH = 8 + LEFT_WIDTH + 6 + RIGHT_WIDTH + 8
local UNDOCKED_WIDTH = 8 + LEFT_WIDTH + 8

local frame
local openedForAuctionHouse = false

-- An icon just outside the auction frame's right edge, where the window
-- docks, brings the window back after you closed it there. It is made on
-- the first visit and shows only while the window is closed.
local auctionHouseButton

local function UpdateAuctionHouseButton()
    if auctionHouseButton then auctionHouseButton:SetShown(not (frame and frame:IsShown())) end
end

local function Docked()
    return addon.Auction.isOpen and AuctionHouseFrame and AuctionHouseFrame:IsShown()
end

local function Layout()
    if not frame then return end
    local docked = Docked()
    frame:ClearAllPoints()
    if docked then
        -- Top and bottom follow the auction frame, so the two are one height.
        frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 2, 0)
        frame:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "BOTTOMRIGHT", 2, 0)
    else
        local saved = addon.db.window
        if saved then
            frame:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
        else
            frame:SetPoint("CENTER")
        end
        frame:SetHeight(HEIGHT)
    end
    frame:SetWidth(docked and DOCKED_WIDTH or UNDOCKED_WIDTH)
    frame.right:SetShown(docked)
    frame.docked = docked
end

local function ShowTab(index)
    frame.buy:SetShown(index == 1)
    frame.sell:SetShown(index == 2)
    frame.auctions:SetShown(index == 3)
end

-- Picking Prices puts the cursor in its search box.
local function ShowLeftTab(index)
    frame.list:SetShown(index == 1)
    frame.queue:SetShown(index == 2)
    frame.prices:SetShown(index == 3)
    if index == 3 and frame:IsShown() then frame.prices.search:SetFocus() end
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

local function Create()
    frame = CreateFrame("Frame", "RichSnobsAHFrame", UIParent, "ButtonFrameTemplate")
    frame:Hide()
    ButtonFrameTemplate_HidePortrait(frame)
    ButtonFrameTemplate_HideButtonBar(frame)
    frame.Inset:Hide()
    frame:SetTitle("RichSnobsAH")
    frame:SetSize(UNDOCKED_WIDTH, HEIGHT)
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not self.docked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        -- Docked, the point is the dock's anchor, not a place to remember.
        if self.docked then return end
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        addon.db.window = { point = point, relativePoint = relativePoint, x = x, y = y }
    end)
    tinsert(UISpecialFrames, frame:GetName())

    frame.left = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    frame.left:SetPoint("TOPLEFT", 8, -28)
    frame.left:SetPoint("BOTTOMLEFT", 8, 30)
    frame.left:SetWidth(LEFT_WIDTH)
    local leftTabBar = CreateFrame("Frame", nil, frame.left)
    leftTabBar:SetPoint("TOPLEFT", 6, -4)
    leftTabBar:SetSize(LEFT_WIDTH - 12, 24)
    frame.list = UI.CreateListPane(frame.left)
    frame.queue = UI.CreateQueuePane(frame.left)
    frame.prices = UI.CreatePricesPane(frame.left)
    for _, pane in ipairs({ frame.list, frame.queue, frame.prices }) do
        pane:SetPoint("TOPLEFT", 0, -30)
        pane:SetPoint("BOTTOMRIGHT")
    end
    frame.leftTabs = UI.Tabs(leftTabBar, { "Lists", "Queue", "Prices" }, ShowLeftTab)
    frame.leftTabs:Select(1)

    frame.right = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    frame.right:SetPoint("TOPLEFT", frame.left, "TOPRIGHT", 6, 0)
    frame.right:SetPoint("BOTTOMLEFT", frame.left, "BOTTOMRIGHT", 6, 0)
    frame.right:SetWidth(RIGHT_WIDTH)
    local tabBar = CreateFrame("Frame", nil, frame.right)
    tabBar:SetPoint("TOPLEFT", 6, -4)
    tabBar:SetSize(RIGHT_WIDTH - 12, 24)
    frame.buy = UI.CreateBuyPane(frame.right)
    frame.sell = UI.CreateSellPane(frame.right)
    frame.auctions = UI.CreateAuctionsPane(frame.right)
    for _, pane in ipairs({ frame.buy, frame.sell, frame.auctions }) do
        pane:SetPoint("TOPLEFT", 0, -30)
        pane:SetPoint("BOTTOMRIGHT")
    end
    frame.tabs = UI.Tabs(tabBar, { "Buy", "Sell", "My auctions" }, ShowTab)
    frame.tabs:Select(1)

    frame.progress = CreateFrame("StatusBar", nil, frame)
    frame.progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.progress:SetStatusBarColor(0.85, 0.7, 0.2)
    frame.progress:SetMinMaxValues(0, 1)
    frame.progress:SetSize(160, 10)
    frame.progress:SetPoint("BOTTOMRIGHT", -14, 11)
    local background = frame.progress:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.5)
    frame.progress:Hide()

    frame.statusText = UI.Text(frame, "GameFontHighlightSmall")
    frame.statusText:SetPoint("BOTTOMLEFT", 14, 10)
    frame.statusText:SetPoint("RIGHT", frame.progress, "LEFT", -10, 0)

    frame:SetScript("OnShow", function()
        Layout()
        UpdateStatus()
        UpdateAuctionHouseButton()
        addon:Refresh()
    end)
    frame:SetScript("OnHide", function()
        openedForAuctionHouse = false
        addon.Auction:CancelQuote()
        UpdateAuctionHouseButton()
    end)

    addon.window = frame
end

function addon:ShowWindow()
    if InCombatLockdown() then return end
    if not frame then Create() end
    frame:Show()
end

function addon:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:ShowWindow()
    end
end

-- Shows an item in the right pane. tab: "buy" or "sell" switches to it;
-- otherwise My auctions gives way to Buy.
function addon:Select(selection, tab)
    self.selected = selection
    if frame then
        if tab == "buy" then
            frame.tabs:Select(1)
        elseif tab == "sell" then
            frame.tabs:Select(2)
        elseif frame.tabs.selected == 3 then
            frame.tabs:Select(1)
        end
    end
    self:Refresh()
end

addon:Listen("STATUS", UpdateStatus)

local function AddAuctionHouseButton()
    if auctionHouseButton or not AuctionHouseFrame then return end
    auctionHouseButton = UI.IconButton(AuctionHouseFrame, 30, { icon = "Interface\\Icons\\INV_Misc_Coin_02" },
        "RichSnobsAH", "Show your lists", function()
            addon:ShowWindow()
            openedForAuctionHouse = frame ~= nil and frame:IsShown()
        end)
    auctionHouseButton:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 2, -40)
    UpdateAuctionHouseButton()
end

-- The auction frame opens with the window docked beside it, and closes it
-- again if it opened it. Blizzard's frame shows on the same event, so the
-- layout waits a frame for it.
addon:Listen("AH_SHOW", function()
    C_Timer.After(0, function()
        AddAuctionHouseButton()
        if not frame or not frame:IsShown() then
            addon:ShowWindow()
            openedForAuctionHouse = frame ~= nil and frame:IsShown()
        end
        Layout()
    end)
end)

addon:Listen("AH_HIDE", function()
    if not frame then return end
    if openedForAuctionHouse then
        frame:Hide()
    else
        Layout()
    end
end)

-- Alt-click any item, in bags, chat or a profession window, to look it up
-- in the Buy tab.
if HandleModifiedItemClick then
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if not IsAltKeyDown() or not addon.Auction.isOpen or type(link) ~= "string" then return end
        local itemID = C_Item.GetItemInfoInstant(link)
        if not itemID then return end
        addon:ShowWindow()
        addon:Select({ itemID = itemID }, "buy")
    end)
end
