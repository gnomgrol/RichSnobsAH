-- Price history: a point per item per day from every price the addon sees
-- (full scans, price checks, searches; not the snipe rounds', which hunt for
-- the odd cheap offer), holding the day's lowest price and how many were up. Days older than the last 30 merge into one point per
-- week. Each item's points are packed into strings, so years of them stay
-- small and quick to load.

local _, addon = ...

local DAY = 86400
local DAILY_DAYS = 30 -- one point a day this far back, one a week before that
local USUAL_DAYS = 3  -- days of prices a usual price needs

--[[ db.history.days[itemID]  = the daily points, at most 36
     db.history.weeks[itemID] = the weekly points before them
    A point is "day,price,count" in base 36: day counts days since 1970 (UTC),
    price is copper per unit, and count is how many were up, empty when no
    count was seen. Points are oldest first, joined by ";". A weekly point
    carries the Monday of its week and the averages of that week's days.
    Recording touches only the short daily string; the weekly one grows by a
    point a week. ]]

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function Encode(n)
    n = math.floor(n + 0.5)
    if n <= 0 then return "0" end
    local text = ""
    while n > 0 do
        local digit = n % 36
        text = DIGITS:sub(digit + 1, digit + 1) .. text
        n = (n - digit) / 36
    end
    return text
end

local function Point(day, price, count)
    return Encode(day) .. "," .. Encode(price) .. "," .. (count and Encode(count) or "")
end

-- day, price, count; count is nil when none was seen.
local function Parse(point)
    local day, price, count = point:match("^(%w+),(%w+),(%w*)$")
    if not day then return nil end
    return tonumber(day, 36), tonumber(price, 36), tonumber(count, 36)
end

local function Today()
    return math.floor(time() / DAY)
end

-- Weeks start on Monday; day 4, 5 January 1970, was one.
local function WeekStart(day)
    return day - (day - 4) % 7
end

-- The first day kept as a daily point. The window starts on a Monday, so a
-- week leaves it whole and merges once.
local function FirstDaily(today)
    return WeekStart(today - DAILY_DAYS + 1)
end

-- Splits the daily points before first off into one point per week.
-- Returns those weekly points and the daily points left.
local function Thin(daily, first)
    local keep, weeks, order = {}, {}, {}
    for point in daily:gmatch("[^;]+") do
        local day, price, count = Parse(point)
        if day and price and day < first then
            local start = WeekStart(day)
            local week = weeks[start]
            if not week then
                week = { days = 0, price = 0, counted = 0, count = 0 }
                weeks[start] = week
                order[#order + 1] = start
            end
            week.days = week.days + 1
            week.price = week.price + price
            if count then
                week.counted = week.counted + 1
                week.count = week.count + count
            end
        elseif day then
            keep[#keep + 1] = point
        end
    end
    local merged = {}
    for i, start in ipairs(order) do
        local week = weeks[start]
        merged[i] = Point(start, week.price / week.days, week.counted > 0 and week.count / week.counted or nil)
    end
    return table.concat(merged, ";"), table.concat(keep, ";")
end

-- Adds a price seen now: the day keeps its lowest price and the latest count.
function addon:RecordHistory(itemID, price, count)
    if not itemID or not price or price <= 0 then return end
    local history = self.db.history
    local daily = history.days[itemID] or ""
    local today = Today()

    local cut = daily:find(";[^;]*$")
    local head, last = "", daily
    if cut then head, last = daily:sub(1, cut - 1), daily:sub(cut + 1) end
    local day, low, seen = Parse(last)
    if day == today then
        price = math.min(price, low)
        count = count or seen
        daily = head
    end
    local point = Point(today, price, count)
    daily = daily == "" and point or daily .. ";" .. point

    local first = FirstDaily(today)
    local oldest = Parse(daily:match("^[^;]+"))
    if oldest and oldest < first then
        local weeks
        weeks, daily = Thin(daily, first)
        local before = history.weeks[itemID]
        history.weeks[itemID] = before and before .. ";" .. weeks or weeks
    end
    history.days[itemID] = daily
end

-- Today's day number, as points count days.
function addon:Today()
    return Today()
end

-- Every point, oldest first: { day, price, count, weekly }; a weekly point's
-- day is the Monday of its week. Nil without any.
function addon:PriceHistory(itemID)
    if not itemID then return nil end
    local points = {}
    local function Add(text, weekly)
        for point in (text or ""):gmatch("[^;]+") do
            local day, price, count = Parse(point)
            if day and price then
                points[#points + 1] = { day = day, price = price, count = count, weekly = weekly }
            end
        end
    end
    Add(self.db.history.weeks[itemID], true)
    Add(self.db.history.days[itemID], false)
    if #points == 0 then return nil end
    return points
end

-- The daily points of the last `days` days, up to 30 (the default): how many
-- days had a price, the lowest, average and highest, and byDay[n] = the
-- price n days into the span, 1 being its first day and `days` today. Nil
-- without any.
function addon:PriceStats(itemID, days)
    local daily = itemID and self.db.history.days[itemID]
    if not daily then return nil end
    local first = Today() - (days or DAILY_DAYS) + 1
    local stats = { days = 0, total = 0, byDay = {} }
    for point in daily:gmatch("[^;]+") do
        local day, price = Parse(point)
        if day and price and day >= first then
            stats.days = stats.days + 1
            stats.total = stats.total + price
            stats.low = math.min(stats.low or price, price)
            stats.high = math.max(stats.high or price, price)
            stats.byDay[day - first + 1] = price
        end
    end
    if stats.days == 0 then return nil end
    stats.avg = stats.total / stats.days
    return stats
end

-- The usual price: the middle of the daily lows of the last 30 days, which
-- leaves out the odd day with a cheap offer. Nil with fewer than 3 days.
function addon:UsualPrice(itemID)
    local stats = self:PriceStats(itemID)
    if not stats or stats.days < USUAL_DAYS then return nil end
    local prices = {}
    for _, price in pairs(stats.byDay) do prices[#prices + 1] = price end
    table.sort(prices)
    local n = #prices
    if n % 2 == 1 then return prices[(n + 1) / 2] end
    return math.floor((prices[n / 2] + prices[n / 2 + 1]) / 2)
end
