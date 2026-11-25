-- The price history window: one item's cheapest price over time as a graph,
-- a point a day for the last 30 days and a point a week before that. Item
-- menus open it, as do the Buy and Sell tabs' Price history and a click on
-- the Prices tab's bars; while it is open, it follows the Buy and Sell tabs
-- to each new item. At the auction house it opens docked under the frame's
-- right corner; elsewhere in the middle of the screen.

local _, addon = ...
local UI = addon.UI

local DAY = 86400
local WIDTH, HEIGHT = 560, 330
local PLOT_LEFT, PLOT_RIGHT = 70, 14 -- inside the inset: room for prices left of the graph
local PLOT_TOP, PLOT_BOTTOM = 12, 24 -- and for dates under it
local GAP_DAYS = 8                   -- points further apart stay unjoined: days without a scan
local LINE_COLOR = { 0.35, 0.7, 1 }
local GRID_COLOR = { 1, 1, 1, 0.08 }
local RANGES = { "30 days", "All" }
local RANGE_DAYS = { 30 }            -- days each range shows; All has none
local LABEL = { 1, 0.82, 0 }

local frame
local hooked -- whether the auction frame's tab changes place it again

local function DateText(day)
    return date("!%b %d", day * DAY)
end

-- A week's point sits in the middle of its week.
local function PointDay(point)
    return point.weekly and point.day + 3 or point.day
end

-- Lines, dots and labels are kept and reused from one drawing to the next.
local function Acquire(pool, create)
    pool.used = pool.used + 1
    local region = pool[pool.used]
    if not region then
        region = create()
        pool[pool.used] = region
    end
    region:Show()
    return region
end

local function ReleaseAll()
    for _, pool in pairs(frame.pools) do
        for i = 1, #pool do pool[i]:Hide() end
        pool.used = 0
    end
end

local function Label()
    return UI.Text(frame.plot, "GameFontDisableSmall")
end

local function Draw()
    local itemID, plot = frame.itemID, frame.plot
    frame.icon:SetTexture(addon:ItemIcon(itemID))
    frame.name:SetText(addon:ItemName(itemID) or "...")
    frame.name:SetTextColor(addon:QualityColor(itemID))
    ReleaseAll()
    frame.points, frame.hovered = nil, nil

    local all = addon:PriceHistory(itemID)
    local today = addon:Today()
    local days = RANGE_DAYS[frame.range]
    local since = days and today - days + 1
    local points = {}
    for _, point in ipairs(all or {}) do
        if not since or point.day >= since then points[#points + 1] = point end
    end
    if #points == 0 then
        frame.message:SetText(all and ("No prices in the last %d days"):format(days or 0)
            or "No prices yet. Scans and price checks at the auction house record them.")
        frame.message:Show()
        frame.summary:SetText("")
        return
    end
    frame.message:Hide()

    local low, high, total = math.huge, 0, 0
    for _, point in ipairs(points) do
        low, high, total = math.min(low, point.price), math.max(high, point.price), total + point.price
    end
    local pad = math.max((high - low) * 0.1, high * 0.05)
    local bottom, top = math.max(0, low - pad), high + pad
    -- The range runs to today, so days since the last price show as space.
    local first = since or PointDay(points[1])
    local last = math.max(today, PointDay(points[#points]))
    if last - first < 1 then first = last - 1 end
    local width, height = plot:GetSize()

    -- Four price lines with their prices.
    for i = 0, 3 do
        local y = height * i / 3
        local grid = Acquire(frame.pools.grid, function()
            local texture = plot:CreateTexture(nil, "BACKGROUND")
            texture:SetColorTexture(unpack(GRID_COLOR))
            texture:SetHeight(1)
            return texture
        end)
        grid:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
        grid:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y)
        local label = Acquire(frame.pools.labels, Label)
        label:ClearAllPoints()
        label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y)
        label:SetText(addon.Money(bottom + (top - bottom) * i / 3))
    end

    -- Dates at both ends and in the middle.
    local function DateLabel(day, point, x)
        local label = Acquire(frame.pools.labels, Label)
        label:ClearAllPoints()
        label:SetPoint(point, plot, "BOTTOMLEFT", x, -6)
        label:SetText(DateText(day))
    end
    DateLabel(first, "TOPLEFT", 0)
    if last - first >= 6 then DateLabel(math.floor((first + last) / 2), "TOP", width / 2) end
    DateLabel(last, "TOPRIGHT", width)

    local previous
    for _, point in ipairs(points) do
        point.x = (PointDay(point) - first) / (last - first) * width
        point.y = (point.price - bottom) / (top - bottom) * height
        if previous and plot.CreateLine and PointDay(point) - PointDay(previous) <= GAP_DAYS then
            local line = Acquire(frame.pools.lines, function()
                local created = plot:CreateLine(nil, "ARTWORK")
                created:SetThickness(2)
                created:SetColorTexture(unpack(LINE_COLOR))
                return created
            end)
            line:SetStartPoint("BOTTOMLEFT", plot, previous.x, previous.y)
            line:SetEndPoint("BOTTOMLEFT", plot, point.x, point.y)
        end
        local dot = Acquire(frame.pools.dots, function()
            local texture = plot:CreateTexture(nil, "OVERLAY")
            texture:SetSize(5, 5)
            texture:SetColorTexture(unpack(LINE_COLOR))
            return texture
        end)
        dot:SetPoint("CENTER", plot, "BOTTOMLEFT", point.x, point.y)
        -- A week's average is fainter than a day's price.
        dot:SetAlpha(point.weekly and 0.5 or 1)
        previous = point
    end
    frame.points = points

    frame.summary:SetText(("Lowest %s     Average %s     Highest %s"):format(
        addon.Money(low), addon.Money(total / #points), addon.Money(high)))
end

-- The point nearest the cursor gets a marker and its prices in a tooltip.
local function OnHover(plot)
    local points = frame.points
    if not points then return end
    local cursor = GetCursorPosition()
    cursor = cursor / plot:GetEffectiveScale() - plot:GetLeft()
    local best, distance
    for _, point in ipairs(points) do
        local d = math.abs(point.x - cursor)
        if not distance or d < distance then best, distance = point, d end
    end
    if not best or best == frame.hovered then return end
    frame.hovered = best

    frame.marker:ClearAllPoints()
    frame.marker:SetPoint("TOP", plot, "TOPLEFT", best.x, 0)
    frame.marker:SetPoint("BOTTOM", plot, "BOTTOMLEFT", best.x, 0)
    frame.marker:Show()
    frame.focus:ClearAllPoints()
    frame.focus:SetPoint("CENTER", plot, "BOTTOMLEFT", best.x, best.y)
    frame.focus:Show()

    local r, g, b = unpack(LABEL)
    GameTooltip:SetOwner(plot, "ANCHOR_CURSOR")
    GameTooltip:SetText(best.weekly and ("Week of %s"):format(DateText(best.day)) or DateText(best.day))
    GameTooltip:AddDoubleLine(best.weekly and "Cheapest, average" or "Cheapest", addon.Money(best.price, true),
        r, g, b, 1, 1, 1)
    if best.count then
        GameTooltip:AddDoubleLine(best.weekly and "Available, average" or "Available",
            BreakUpLargeNumbers(math.floor(best.count + 0.5)), r, g, b, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function Create()
    frame = CreateFrame("Frame", "RichSnobsAHHistoryFrame", UIParent, "ButtonFrameTemplate")
    frame:Hide()
    ButtonFrameTemplate_HidePortrait(frame)
    ButtonFrameTemplate_HideButtonBar(frame)
    frame.Inset:Hide()
    frame:SetTitle("Price history")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.moved = true
    end)
    tinsert(UISpecialFrames, frame:GetName())
    frame.pools = { grid = { used = 0 }, labels = { used = 0 }, lines = { used = 0 }, dots = { used = 0 } }

    -- The item: its tooltip on hover, Shift-click links it.
    local item = CreateFrame("Button", nil, frame)
    item:SetPoint("TOPLEFT", 14, -30)
    item:SetSize(330, 24)
    frame.icon = item:CreateTexture(nil, "ARTWORK")
    frame.icon:SetSize(22, 22)
    frame.icon:SetPoint("LEFT")
    frame.name = UI.Text(item, "GameFontNormal")
    frame.name:SetPoint("LEFT", frame.icon, "RIGHT", 6, 0)
    frame.name:SetPoint("RIGHT")
    item:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(frame.itemID)
        GameTooltip:Show()
    end)
    item:SetScript("OnLeave", GameTooltip_Hide)
    item:SetScript("OnClick", function() UI.ModifiedClick(frame.itemID) end)

    local tabBar = CreateFrame("Frame", nil, frame)
    tabBar:SetSize(110, 24)
    tabBar:SetPoint("TOPRIGHT", -10, -30)
    frame.tabs = UI.Tabs(tabBar, RANGES, function(index)
        frame.range = index
        if frame.itemID then Draw() end
    end)

    local inset = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    inset:SetPoint("TOPLEFT", 8, -58)
    inset:SetPoint("BOTTOMRIGHT", -8, 30)
    local plot = CreateFrame("Frame", nil, inset)
    plot:SetPoint("TOPLEFT", PLOT_LEFT, -PLOT_TOP)
    plot:SetSize(WIDTH - 16 - PLOT_LEFT - PLOT_RIGHT, HEIGHT - 88 - PLOT_TOP - PLOT_BOTTOM)
    plot:EnableMouse(true)
    plot:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", OnHover) end)
    plot:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        frame.hovered = nil
        frame.marker:Hide()
        frame.focus:Hide()
        GameTooltip:Hide()
    end)
    frame.plot = plot

    frame.marker = plot:CreateTexture(nil, "OVERLAY")
    frame.marker:SetColorTexture(1, 1, 1, 0.25)
    frame.marker:SetWidth(1)
    frame.marker:Hide()
    frame.focus = plot:CreateTexture(nil, "OVERLAY", nil, 1)
    frame.focus:SetSize(7, 7)
    frame.focus:SetColorTexture(1, 1, 1, 1)
    frame.focus:Hide()

    frame.message = UI.Text(inset, "GameFontDisable", "CENTER")
    frame.message:SetPoint("CENTER")
    frame.summary = UI.Text(frame)
    frame.summary:SetPoint("BOTTOMLEFT", 14, 11)

    frame.range = #RANGES -- All
end

-- At the auction house: under the frame with the right edges lined up, so
-- it grows to the left, and below the frame's tabs where it would cover
-- one, as on Blizzard's own tabs, which leave the frame narrower. A change
-- of tab places it again. Elsewhere: the middle of the screen.
local function Place()
    frame:ClearAllPoints()
    local house = AuctionHouseFrame
    if not (house and house:IsShown()) then
        frame:SetPoint("CENTER")
        return
    end
    local y = 0
    local left, bottom = house:GetLeft(), house:GetBottom()
    for _, tab in ipairs(house.Tabs or {}) do
        local right, tabBottom = tab:GetRight(), tab:GetBottom()
        if tab:IsShown() and left and bottom and right and tabBottom and right - left > house:GetWidth() - WIDTH then
            y = math.min(y, tabBottom - bottom)
        end
    end
    frame:SetPoint("TOPRIGHT", house, "BOTTOMRIGHT", 0, y)
    if not hooked then
        hooked = true
        hooksecurefunc(house, "SetDisplayMode", function()
            if frame:IsShown() and not frame.moved then Place() end
        end)
    end
end

-- Dragged while open, it stays where it was put; closed, it opens in its
-- place again.
function addon:ShowHistory(itemID)
    if not itemID then return end
    if not frame then Create() end
    if not frame:IsShown() then frame.moved = nil end
    if not frame.moved then Place() end
    frame.itemID = itemID
    frame:Show()
    frame:Raise()
    frame.tabs:Select(frame.range)
end

-- The Buy or Sell tab moved on to another item: an open history shows it
-- too, where it is.
function addon:HistoryFollows(itemID)
    if not (frame and frame:IsShown()) or frame.itemID == itemID then return end
    frame.itemID = itemID
    Draw()
end

-- New prices, and item names as they load, redraw it.
addon:Listen("REFRESH", function()
    if frame and frame:IsShown() then Draw() end
end)
