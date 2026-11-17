-- RichSnobsAH for WoW Forever: hand-kept lists of crafts and reagents that
-- drive buying, crafting, posting and undercut checks at the auction house.

local addonName, addon = ...

addon.UI = {}

--------------------------------------------------------------------------------
-- Game events and the addon's own messages
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local handlers = {}

-- Calls fn(...) whenever the game fires event. An event this client doesn't
-- know is skipped instead of stopping the addon from loading.
function addon:On(event, fn)
    local list = handlers[event]
    if not list then
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then return false end
        list = {}
        handlers[event] = list
    end
    list[#list + 1] = fn
    return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    for i = 1, #list do list[i](...) end
end)

local listeners = {}

function addon:Listen(message, fn)
    listeners[message] = listeners[message] or {}
    table.insert(listeners[message], fn)
end

function addon:Fire(message, ...)
    local list = listeners[message]
    if not list then return end
    for i = 1, #list do list[i](...) end
end

-- Prices, bags and lists often change many times in one frame, so redraws
-- are gathered into one on the next frame.
local refreshQueued = false
function addon:Refresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        addon:Fire("REFRESH")
    end)
end

--------------------------------------------------------------------------------
-- Output and formatting
--------------------------------------------------------------------------------

-- Chat is for errors and the mailbox's summary of sales collected (Sales.lua);
-- progress goes to the window's status line.
function addon:Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffd4af37RichSnobsAH:|r " .. message)
end

-- The window's status line. done and total fill its progress bar.
function addon:SetStatus(text, done, total)
    self.status = { text = text or "", done = done, total = total }
    self:Fire("STATUS")
end

local GOLD, SILVER, COPPER = "|cffffd100g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"

-- "12g 04s" by default; exact adds the copper a gold price usually hides.
-- A unit after a larger one has two digits, so the numbers line up.
function addon.Money(copper, exact)
    if not copper then return "" end
    copper = math.floor(copper + 0.5)
    local sign = copper < 0 and "-" or ""
    copper = math.abs(copper)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local text
    if g > 0 then
        text = BreakUpLargeNumbers(g) .. GOLD
        if s > 0 or (exact and c > 0) then text = text .. (" %02d"):format(s) .. SILVER end
        if exact and c > 0 then text = text .. (" %02d"):format(c) .. COPPER end
    elseif s > 0 then
        text = s .. SILVER
        if c > 0 then text = text .. (" %02d"):format(c) .. COPPER end
    else
        text = c .. COPPER
    end
    return sign .. text
end

-- "25 min", "3 h", "2 d"
function addon.Age(seconds)
    seconds = math.max(0, seconds or 0)
    if seconds < 3600 then return math.max(1, math.floor(seconds / 60)) .. " min" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. " h" end
    return math.floor(seconds / 86400) .. " d"
end

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------

local QUESTION_MARK = 134400

-- Nil until the client has the item cached; GET_ITEM_INFO_RECEIVED then
-- redraws whatever asked.
function addon:ItemName(itemID)
    if not itemID then return nil end
    local name = C_Item.GetItemNameByID(itemID)
    if not name then C_Item.RequestLoadItemDataByID(itemID) end
    return name
end

function addon:ItemIcon(itemID)
    return itemID and C_Item.GetItemIconByID(itemID) or QUESTION_MARK
end

function addon:QualityColor(itemID)
    local quality = itemID and C_Item.GetItemQualityByID(itemID)
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then return color.r, color.g, color.b end
    return 1, 1, 1
end

-- A list entry is an item, or a recipe that may make no item (enchants).
function addon:EntryName(entry)
    return (entry.itemID and self:ItemName(entry.itemID)) or entry.name or "..."
end

function addon:EntryIcon(entry)
    return (entry.itemID and C_Item.GetItemIconByID(entry.itemID)) or entry.icon or QUESTION_MARK
end

function addon:CharKey()
    local name, realm = UnitFullName("player")
    if not realm or realm == "" then realm = GetRealmName() end
    return (name or "?") .. "-" .. (realm or "?")
end

--------------------------------------------------------------------------------
-- Startup, slash commands, addon compartment
--------------------------------------------------------------------------------

addon:On("ADDON_LOADED", function(name)
    if name ~= addonName then return end
    addon:InitDB()
    addon:Fire("DB_READY")
end)

addon:On("PLAYER_LOGIN", function() addon:Fire("LOGIN") end)
-- Names asked for with RequestLoadItemDataByID come back with the second.
addon:On("GET_ITEM_INFO_RECEIVED", function() addon:Refresh() end)
addon:On("ITEM_DATA_LOAD_RESULT", function() addon:Refresh() end)
addon:On("BAG_UPDATE_DELAYED", function() addon:Refresh() end)
-- A stack picked up and put back unlocks without a bag update.
addon:On("ITEM_LOCK_CHANGED", function() addon:Refresh() end)

SLASH_RICHSNOBSAH1 = "/rsah"
SLASH_RICHSNOBSAH2 = "/richsnobs"
SlashCmdList.RICHSNOBSAH = function(message)
    message = strtrim(message or ""):lower()
    if message == "minimap" then
        addon:ToggleMinimapButton()
    else
        addon:Toggle()
    end
end

function RichSnobsAH_OnAddonCompartmentClick()
    addon:Toggle()
end

function RichSnobsAH_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText("RichSnobsAH")
    GameTooltip:AddLine("Click to open your lists.", 1, 1, 1)
    GameTooltip:Show()
end

function RichSnobsAH_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
