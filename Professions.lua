-- Recipes from Blizzard's Professions frame: the "Add to list" button,
-- crafting from the list and the queue, and plans counting down.
--
-- Crafting works only while the recipe's profession window is open, because
-- addon code can't open a profession on Forever (OpenTradeSkill is blocked)
-- and CraftRecipe does nothing for a recipe that isn't in the open window.

local _, addon = ...

local Prof = {}
addon.Prof = Prof

local windowOpen = false
local openRecipes -- set of recipe IDs in the open profession window

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end

local function Rebuild()
    openRecipes = nil
    if windowOpen then
        -- Someone else's profession, a guild's, or an NPC's can't craft for you.
        local foreign = Call(C_TradeSkillUI.IsTradeSkillLinked) or Call(C_TradeSkillUI.IsTradeSkillGuild)
            or Call(C_TradeSkillUI.IsNPCCrafting)
        local ids = not foreign and Call(C_TradeSkillUI.GetAllRecipeIDs)
        if type(ids) == "table" and #ids > 0 then
            openRecipes = {}
            for _, id in ipairs(ids) do openRecipes[id] = true end
        end
    end
    addon:Refresh()
end

-- The list updates after every craft, so rebuilds are gathered.
local rebuildQueued = false
local function QueueRebuild()
    if rebuildQueued then return end
    rebuildQueued = true
    C_Timer.After(0.2, function()
        rebuildQueued = false
        Rebuild()
    end)
end

addon:On("TRADE_SKILL_SHOW", function()
    windowOpen = true
    QueueRebuild()
end)
addon:On("TRADE_SKILL_LIST_UPDATE", QueueRebuild)
addon:On("TRADE_SKILL_DATA_SOURCE_CHANGED", QueueRebuild)
addon:On("TRADE_SKILL_CLOSE", function()
    windowOpen = false
    Rebuild()
end)

--------------------------------------------------------------------------------
-- Reading a recipe
--------------------------------------------------------------------------------

local function ProfessionName(recipeID)
    local info = Call(C_TradeSkillUI.GetBaseProfessionInfo)
    if info and info.professionName and info.professionName ~= "" then return info.professionName end
    local _, skillName, _, parentName = Call(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
    return parentName or skillName
end

function Prof:ReadRecipe(recipeID)
    local schematic = Call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if type(schematic) ~= "table" then return nil end
    local info = Call(C_TradeSkillUI.GetRecipeInfo, recipeID) or {}

    local reagents = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        -- Type 1 is a required basic reagent; optional and finishing slots
        -- aren't part of the cost.
        local first = slot.reagents and slot.reagents[1]
        if (slot.reagentType == nil or slot.reagentType == 1) and first and first.itemID
            and (slot.quantityRequired or 0) > 0 then
            reagents[#reagents + 1] = { itemID = first.itemID, count = slot.quantityRequired }
        end
    end

    local itemID = schematic.outputItemID
    if not itemID then
        local output = Call(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        itemID = output and output.itemID
    end
    local low = schematic.quantityMin or 1
    local high = schematic.quantityMax or low

    return {
        recipeID = recipeID,
        itemID = itemID,
        name = info.name or schematic.name,
        icon = info.icon or schematic.icon,
        yield = math.max(1, (low + high) / 2),
        reagents = reagents,
        prof = ProfessionName(recipeID),
    }
end

--------------------------------------------------------------------------------
-- Crafting
--------------------------------------------------------------------------------

-- Whether an entry can be crafted now, and if not, why ("open Alchemy first").
function Prof:CraftState(entry)
    if not entry.recipeID then return false, "not a recipe" end
    if not openRecipes or not openRecipes[entry.recipeID] then
        return false, ("open %s first"):format(entry.prof or "its profession")
    end
    local info = Call(C_TradeSkillUI.GetRecipeInfo, entry.recipeID)
    if info and info.learned == false then return false, "recipe not learned" end
    return true
end

local lastCrafted -- the entry the last Craft press was for

-- Runs from a click: CraftRecipe needs a hardware event.
function Prof:Craft(entry, count)
    local ok, why = self:CraftState(entry)
    if not ok then
        addon:SetStatus("Craft: " .. why)
    elseif not count or count < 1 then
        addon:SetStatus("Not enough reagents in your bags")
    else
        lastCrafted = entry
        C_TradeSkillUI.CraftRecipe(entry.recipeID, count)
        addon:SetStatus(("Crafting %d x %s"):format(count, addon:EntryName(entry)))
    end
end

-- The first craft in the queue you can make now, and how many one press makes.
function Prof:NextQueued()
    for _, queued in ipairs(addon:Queue()) do
        local entry = queued.entry
        if self:CraftState(entry) then
            local count = addon:CraftBatch(entry)
            if count > 0 then return entry, count end
        end
    end
end

-- The planned entry a finished craft counts against: the one last crafted
-- from the addon, else the first in the queue with that recipe.
local function PlannedEntryFor(recipeID)
    local first
    for _, queued in ipairs(addon:Queue()) do
        local entry = queued.entry
        if entry.recipeID == recipeID then
            if entry == lastCrafted then return entry end
            first = first or entry
        end
    end
    return first
end

-- Every finished craft takes one off its plan, crafted from here or from
-- Blizzard's window; a used-up plan leaves the queue. A craft's spell ID is
-- its recipe ID.
local castFrame = CreateFrame("Frame")
castFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
castFrame:SetScript("OnEvent", function(_, _, _, _, spellID)
    local entry = addon.db and spellID and PlannedEntryFor(spellID)
    if entry then addon:SetPlanned(entry, addon:Planned(entry) - 1) end
end)

--------------------------------------------------------------------------------
-- Icons on Blizzard's Professions frame, left of the skill bar under the
-- portrait: open your lists, and add the selected recipe to one. Forever's
-- title bar art covers anything placed in it.
--------------------------------------------------------------------------------

local ICON = "Interface\\Icons\\INV_Misc_Coin_02"

local function SelectedRecipeID()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local form = page and page.SchematicForm
    local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
    return info and info.recipeID
end

-- The yellow line at the top of the screen, as for the game's own notices.
local function Notice(text)
    UIErrorsFrame:AddMessage(text, 1, 0.82, 0)
end

local function AddSelected(button)
    local recipeID = SelectedRecipeID()
    local recipe = recipeID and Prof:ReadRecipe(recipeID)
    if not recipe then
        Notice("Pick a recipe first")
        return
    end
    addon:ShowListPicker(button, "Add to list", function(list)
        local entry, added = addon:AddRecipe(list, recipe)
        Notice(("%s %s %s"):format(addon:EntryName(entry), added and "added to" or "updated in", list.name))
    end)
end

local function CreateButtons()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    if not page or Prof.openButton then return end
    local UI = addon.UI

    -- Parented to the recipes page, so they leave with it on the other tabs.
    Prof.addButton = UI.IconButton(page, 20, {
        normal = "Interface\\Buttons\\UI-PlusButton-Up",
        pushed = "Interface\\Buttons\\UI-PlusButton-Down",
        highlight = "Interface\\Buttons\\UI-PlusButton-Hilight",
    }, "Add to list", "This recipe and its reagents, to one of your lists", AddSelected)
    Prof.openButton = UI.IconButton(page, 20, { icon = ICON },
        "RichSnobsAH", "Open your lists", function() addon:Toggle() end)

    if page.RankBar then
        Prof.addButton:SetPoint("RIGHT", page.RankBar, "LEFT", -10, 0)
    elseif page.RecipeList then
        Prof.addButton:SetPoint("BOTTOMLEFT", page.RecipeList, "TOPLEFT", 28, 10)
    else
        Prof.addButton:SetPoint("TOPLEFT", page, "TOPLEFT", 90, -40)
    end
    Prof.openButton:SetPoint("RIGHT", Prof.addButton, "LEFT", -4, 0)
end

-- Without an error display a failure here would just leave the icons
-- missing, so it is said in chat.
local function TryCreateButtons()
    local ok, err = pcall(CreateButtons)
    if not ok then addon:Print("Couldn't add the icons to the profession window: " .. tostring(err)) end
end

-- The Professions frame loads on demand, usually long after this addon.
addon:On("ADDON_LOADED", function(name)
    if name == "Blizzard_Professions" then TryCreateButtons() end
end)
addon:Listen("LOGIN", function()
    if C_AddOns.IsAddOnLoaded("Blizzard_Professions") then TryCreateButtons() end
end)
