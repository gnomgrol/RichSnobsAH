local addonName, addon = ...

-- Helper to add item by ID from TradeSkill API
local function AddTradeSkillItem(id) 
    local name, type, _, _, _ = GetTradeSkillInfo(id)
    if type ~= "header" then
        local link = GetTradeSkillItemLink(id)
        local icon = GetTradeSkillIcon(id)
        local numReagents = GetTradeSkillNumReagents(id)
        
        -- Capture Profession Name
        local professionName, _, _, _ = GetTradeSkillLine()
        
        local reagents = {}
        for i = 1, numReagents do
            local rName, rTexture, rCount, _ = GetTradeSkillReagentInfo(id, i)
            local rLink = GetTradeSkillReagentItemLink(id, i)
            table.insert(reagents, {
                name = rName,
                texture = rTexture,
                count = rCount,
                link = rLink
            })
        end
        
        addon:AddItemToGroup(addon.db.selectedGroupIndex, {
            link = link,
            texture = icon,
            count = 1,
            reagents = reagents,
            recipeName = name,
            profession = professionName,
            isCraft = false -- distinguish between TradeSkill vs Craft (Enchanting)
        })
    end
end

-- Helper to add item by ID from Craft API (Enchanting)
local function AddCraftItem(id)
    local name, _, type = GetCraftInfo(id)
    if type ~= "header" then
        local link = GetCraftItemLink(id)
        if not link then link = name end
        local icon = GetCraftIcon(id)
        local numReagents = GetCraftNumReagents(id)
        
        local professionName = "Enchanting" -- Usually CraftFrame is Enchanting in Classic/TBC
        -- GetCraftDisplaySkillLine() might return it?
        
        local reagents = {}
        for i = 1, numReagents do
            local rName, rTexture, rCount, _ = GetCraftReagentInfo(id, i)
            local rLink = GetCraftReagentItemLink(id, i)
            table.insert(reagents, {
                name = rName,
                texture = rTexture,
                count = rCount,
                link = rLink
            })
        end
            
        addon:AddItemToGroup(addon.db.selectedGroupIndex, {
            link = link,
            texture = icon,
            count = 1,
            reagents = reagents,
            recipeName = name,
            profession = professionName,
            isCraft = true
        })
    end
end

function addon:SetupCraftingHook()
   -- No hooks needed for the button approach
end

function addon:ImportSelection()
    if not addon.db.selectedGroupIndex then
        addon.print("No group selected.")
        return
    end

    -- Check TradeSkillFrame (Alchemy, BS, etc)
    -- In most versions, TradeSkillFrame:IsVisible() works. 
    -- Or check selection index.
    local tsSelection = GetTradeSkillSelectionIndex()
    if tsSelection and tsSelection > 0 and TradeSkillFrame and TradeSkillFrame:IsVisible() then
        AddTradeSkillItem(tsSelection)
        return
    end

    -- Check CraftFrame (Enchanting)
    local cSelection = GetCraftSelectionIndex()
    if cSelection and cSelection > 0 and CraftFrame and CraftFrame:IsVisible() then
        AddCraftItem(cSelection)
        return
    end
    
    addon.print("No profession selection found. Open a profession and select a recipe.")
end
