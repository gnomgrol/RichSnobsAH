local addonName, addon = ...

function addon:InitializeData()
    if not RichSnobsAHDB then
        RichSnobsAHDB = {
            minimap = { hide = false },
            groups = {}, -- list of groups: { name = "Consumables", items = {} }
            selectedGroupIndex = nil,
            prices = {}, -- [itemId or name] = copper
            ahCounts = {}, -- [characterName] = { [itemName] = count }
            fastScan = false,
        }
    end
    self.db = RichSnobsAHDB
    if not self.db.prices then self.db.prices = {} end
    if not self.db.ahCounts then self.db.ahCounts = {} end
    if not self.db.vendorItems then self.db.vendorItems = {} end
    if self.db.fastScan == nil then self.db.fastScan = false end
    if not self.db.viewMode then self.db.viewMode = "profit" end -- "profit" or "leveling"
    if not self.db.skillRanks then self.db.skillRanks = {} end -- [profession] = current skill level
end

-- Discrete approximation used as a fallback when we don't have exact thresholds:
-- orange=100%, yellow=75%, green=25%, grey=0%.
local function approxChance(difficulty)
    if difficulty == "optimal" then return 1.0 end
    if difficulty == "medium" or difficulty == "difficult" then return 0.75 end
    if difficulty == "easy" then return 0.25 end
    return 0 -- "trivial" or unknown
end

-- Pull current skill ranks for every profession the player knows from the
-- skills pane. Lets us compute precise skill-up chances without requiring
-- the profession window to be opened first.
function addon:RefreshSkillRanks()
    if not GetNumSkillLines or not GetSkillLineInfo then return end
    self.db.skillRanks = self.db.skillRanks or {}
    local n = GetNumSkillLines() or 0
    for i = 1, n do
        local name, isHeader, _, rank = GetSkillLineInfo(i)
        if name and not isHeader and rank and rank > 0 then
            self.db.skillRanks[name] = rank
        end
    end
end

-- Precise per-recipe formula using the threshold table:
--   X < yellow         -> 1.0
--   yellow <= X < grey -> (grey - X) / (grey - yellow)
--   X >= grey          -> 0
-- Returns nil when we don't have thresholds or current skill for this recipe.
function addon:GetPreciseSkillUpChance(item)
    if not item or not item.recipeName or not item.profession then return nil end
    local profTable = addon.recipeThresholds and addon.recipeThresholds[item.profession]
    if not profTable then return nil end
    local t = profTable[item.recipeName]
    if not t then return nil end
    local skill = self.db.skillRanks and self.db.skillRanks[item.profession]
    if not skill then return nil end
    if t.grey <= t.yellow then return nil end -- bad data, fall back
    if skill < t.yellow then return 1.0 end
    if skill >= t.grey then return 0 end
    return (t.grey - skill) / (t.grey - t.yellow)
end

-- Skill-up chance per craft. Uses the precise formula when recipe thresholds
-- and current skill are known; otherwise falls back to the discrete color
-- approximation. Accepts either an item table (preferred) or a difficulty
-- string for legacy callers.
function addon:GetSkillUpChance(itemOrDifficulty)
    if type(itemOrDifficulty) == "string" then
        return approxChance(itemOrDifficulty)
    end
    local item = itemOrDifficulty
    if not item then return 0 end
    local precise = self:GetPreciseSkillUpChance(item)
    if precise ~= nil then return precise end
    return approxChance(item.difficulty)
end

function addon:GetDifficultyColor(difficulty)
    if difficulty == "optimal" then return "|cffff8040" end -- orange
    if difficulty == "medium" or difficulty == "difficult" then return "|cffffff00" end -- yellow
    if difficulty == "easy" then return "|cff40c040" end -- green
    if difficulty == "trivial" then return "|cff808080" end -- grey
    return "|cffaaaaaa" -- unknown
end

function addon:GetDifficultyLabel(difficulty)
    if difficulty == "optimal" then return "Orange" end
    if difficulty == "medium" or difficulty == "difficult" then return "Yellow" end
    if difficulty == "easy" then return "Green" end
    if difficulty == "trivial" then return "Grey" end
    return "?"
end

-- Vendor sell price per single crafted item. Lazy-fetches and caches on the
-- item if it wasn't captured at import time (e.g. recipes added pre-feature).
function addon:GetVendorSellPrice(item)
    if not item then return 0 end
    if item.sellPrice and item.sellPrice > 0 then return item.sellPrice end
    if item.link then
        local sp = select(11, GetItemInfo(item.link))
        if sp and sp > 0 then
            item.sellPrice = sp -- cache on the item; SavedVariables will persist it
            return sp
        end
    end
    return 0
end

-- Best known AH price for the crafted item (per single item, gross).
function addon:GetCraftedAHPrice(item)
    if not item then return 0 end
    local p = self:GetItemPrice(item.recipeName)
    if (not p or p == 0) and item.link then
        local n = GetItemInfo(item.link)
        if n then p = self:GetItemPrice(n) end
    end
    if (not p or p == 0) and item.link then
        local raw = item.link:match("%[(.-)%]")
        if raw then p = self:GetItemPrice(raw) end
    end
    if (not p or p == 0) and item.link then
        p = self:GetItemPrice(item.link)
    end
    return p or 0
end

local AH_CUT = 0.95 -- 5% AH cut taken off the listed price when sold

-- Expected craft cost per single skill point (copper). Returns nil if not skillable
-- (no reagents, grey/unknown difficulty, or no reagent price data).
--
-- mode controls whether the recoup from disposing of the crafted items is
-- credited against the cost:
--   "gross"  -- raw craft cost / chance (no recoup)
--   "vendor" -- subtract vendor sell value of the yielded items
--   "ah"     -- subtract AH sell value (after cut) of the yielded items.
--             Returns nil when no AH price is known.
--   "best"   -- min of vendor and AH (whichever is known). Default.
function addon:GetCostPerSkillUp(item, mode)
    if not item or not item.reagents or #item.reagents == 0 then return nil end
    local chance = self:GetSkillUpChance(item)
    if not chance or chance <= 0 then return nil end
    local craftCost = self:CalculateCraftCost(item)
    if not craftCost or craftCost <= 0 then return nil end

    local yield = item.yield or 1
    mode = mode or "best"

    if mode == "gross" then
        return craftCost / chance
    end

    local vendorRecoup = self:GetVendorSellPrice(item) * yield
    local vendorPerSP = (craftCost - vendorRecoup) / chance

    if mode == "vendor" then return vendorPerSP end

    local ahRaw = self:GetCraftedAHPrice(item)
    local ahPerSP = nil
    if ahRaw and ahRaw > 0 then
        ahPerSP = (craftCost - ahRaw * AH_CUT * yield) / chance
    end

    if mode == "ah" then return ahPerSP end

    -- "best": cheapest disposal strategy
    if ahPerSP and ahPerSP < vendorPerSP then return ahPerSP end
    return vendorPerSP
end

-- Update difficulty for any tracked items matching recipes in the currently
-- open profession window. Called when TradeSkill/Craft windows show or update.
function addon:UpdateRecipeDifficulties()
    if not self.db or not self.db.groups then return end
    local updates = {} -- [profession][recipeName] = skillType

    self.db.skillRanks = self.db.skillRanks or {}

    if TradeSkillFrame and TradeSkillFrame:IsVisible() then
        local profName, rank = GetTradeSkillLine()
        if profName then
            if rank and rank > 0 then self.db.skillRanks[profName] = rank end
            updates[profName] = updates[profName] or {}
            local num = GetNumTradeSkills() or 0
            for i = 1, num do
                local name, skillType = GetTradeSkillInfo(i)
                if name and skillType and skillType ~= "header" then
                    updates[profName][name] = skillType
                end
            end
        end
    end

    if CraftFrame and CraftFrame:IsVisible() and GetNumCrafts then
        local profName, rank
        if GetCraftDisplaySkillLine then
            profName, rank = GetCraftDisplaySkillLine()
        end
        profName = profName or "Enchanting"
        if rank and rank > 0 then self.db.skillRanks[profName] = rank end
        updates[profName] = updates[profName] or {}
        local num = GetNumCrafts() or 0
        for i = 1, num do
            local name, _, skillType = GetCraftInfo(i)
            if name and skillType and skillType ~= "header" then
                updates[profName][name] = skillType
            end
        end
    end

    local changed = false
    for _, group in ipairs(self.db.groups) do
        for _, item in ipairs(group.items) do
            local prof = item.profession
            if prof and updates[prof] and item.recipeName then
                local newDiff = updates[prof][item.recipeName]
                if newDiff and newDiff ~= item.difficulty then
                    item.difficulty = newDiff
                    changed = true
                end
            end
        end
    end

    if changed and self.mainFrame and self.mainFrame:IsShown() then
        self:RefreshMainFrame()
    end
end

function addon:AddGroup(groupName)
    if not groupName or groupName == "" then return end
    table.insert(self.db.groups, { name = groupName, items = {} })
    -- Auto select the new group
    self.db.selectedGroupIndex = #self.db.groups
    addon:RefreshMainFrame()
end

function addon:DeleteGroup(index)
    if self.db.groups[index] then
        table.remove(self.db.groups, index)
        if self.db.selectedGroupIndex == index then
            self.db.selectedGroupIndex = nil
        elseif self.db.selectedGroupIndex > index then
            self.db.selectedGroupIndex = self.db.selectedGroupIndex - 1
        end
        addon:RefreshMainFrame()
    end
end

function addon:RenameGroup(index, newName)
    if not newName or newName == "" then return end
    if self.db.groups[index] then
        self.db.groups[index].name = newName
        addon:RefreshMainFrame()
    end
end

function addon:MoveGroup(index, direction)
    local groups = self.db.groups
    local newIndex = index + direction
    if newIndex < 1 or newIndex > #groups then return end
    
    local group = table.remove(groups, index)
    table.insert(groups, newIndex, group)
    
    -- Update selection if necessary
    if self.db.selectedGroupIndex == index then
        self.db.selectedGroupIndex = newIndex
    elseif self.db.selectedGroupIndex == newIndex then
        self.db.selectedGroupIndex = index
    end
    
    addon:RefreshMainFrame()
end

function addon:MoveItem(groupIndex, itemIndex, direction)
    local group = self.db.groups[groupIndex]
    if not group then return end
    
    local items = group.items
    local newIndex = itemIndex + direction
    if newIndex < 1 or newIndex > #items then return end
    
    local item = table.remove(items, itemIndex)
    table.insert(items, newIndex, item)
    
    addon:RefreshMainFrame()
end

function addon:AddItemToGroup(groupIndex, itemData)
    -- itemData expected to be { link = "...", texture = "...", count = 1, reagents = { {link=..., count=...}, ... } }
    local group = self.db.groups[groupIndex]
    if not group then return end
    
    table.insert(group.items, itemData)
    addon.print("Added " .. (itemData.link or "item") .. " to group " .. group.name)
    addon:RefreshMainFrame()
    addon:ScrollItemListToBottom()
end

function addon:DeleteItem(groupIndex, itemIndex)
    local group = self.db.groups[groupIndex]
    if not group or not group.items[itemIndex] then return end
    
    table.remove(group.items, itemIndex)
    addon.print("Item removed.")
    addon:RefreshMainFrame()
end

function addon:GetItemPrice(itemName)
    if self.db.vendorItems and self.db.vendorItems[itemName] then
        return self.db.vendorItems[itemName]
    end
    return self.db.prices[itemName] or 0
end

function addon:UpdateAHCounts()
    local player = UnitName("player")
    if not player then return end
    
    self.db.ahCounts[player] = {}
    local numOwnerAuctions = GetNumAuctionItems("owner")
    
    for i = 1, numOwnerAuctions do
        local name, _, count, _, _, _, _, _, _, _, _, _, _, _, _, saleStatus = GetAuctionItemInfo("owner", i)
        if name and saleStatus == 0 then -- 0 = active
            self.db.ahCounts[player][name] = (self.db.ahCounts[player][name] or 0) + count
        end
    end
    
    if self.mainFrame and self.mainFrame:IsShown() then
        self:RefreshMainFrame()
    end
end

function addon:GetAHItemCount(itemName)
    if not itemName then return 0 end
    local total = 0
    for charName, counts in pairs(self.db.ahCounts) do
        total = total + (counts[itemName] or 0)
    end
    return total
end

function addon:UpdateItemPrice(itemName, unitPrice, pageNum)
    if not itemName or not unitPrice or unitPrice <= 0 then return end
    
    local oldPrice = self.db.prices[itemName]
    local updated = false

    -- On page 0, we can safely overwrite because it's the start of a new scan/search.
    -- On subsequent pages, we only update if the new unitPrice is LOWER than what we found on previous pages.
    if pageNum == 0 then
        if oldPrice ~= unitPrice then
            self.db.prices[itemName] = unitPrice
            updated = true
        end
    else
        if oldPrice and unitPrice < oldPrice then
            self.db.prices[itemName] = unitPrice
            updated = true
        end
    end

    if updated and self.mainFrame and self.mainFrame:IsShown() then
        addon:RefreshMainFrame()
    end
    
    return updated
end

function addon:CalculateCraftCost(itemData, visited)
    visited = visited or {}
    if not itemData or not itemData.reagents then return 0 end
    
    local itemName = itemData.recipeName or (itemData.link and GetItemInfo(itemData.link)) or itemData.link
    if itemName and visited[itemName] then return 0 end -- avoid infinite recursion
    if itemName then visited[itemName] = true end

    local totalCost = 0
    for _, reagent in ipairs(itemData.reagents) do
        local rName = reagent.name
        if not rName and reagent.link then
            rName = GetItemInfo(reagent.link) or reagent.link:match("%[(.-)%]")
        end
        
        local rCost = self:GetItemPrice(rName)
        
        -- Check if this reagent is something we can also craft
        local craftableItem = self:FindCraftableItem(rName)
        if craftableItem then
            local craftCost = self:CalculateCraftCost(craftableItem, visited)
            -- Prefer craft cost if available and cheaper than AH, OR if AH price is unknown
            if craftCost > 0 then
                local unitCraftCost = craftCost / (craftableItem.yield or 1)
                if rCost == 0 or unitCraftCost < rCost then
                    rCost = unitCraftCost
                end
            end
        end
        
        totalCost = totalCost + (rCost * (reagent.count or 1))
    end
    
    -- Cleanup visited for this path so other branches can visit it if needed
    -- Actually, visited should probably be per-branch to avoid infinite loops, 
    -- but allow same item in different branches. 
    -- However, the current recursive structure uses it globally for the whole tree.
    -- If an item appears twice in the tree, we don't want to re-calculate it? 
    -- Actually, we SHOULD re-calculate it or cache it.
    -- Given it's a small tree, re-calculating is fine, but we MUST prevent infinite loops.
    if itemName then visited[itemName] = nil end
    
    return totalCost
end

function addon:FindCraftableItem(itemName)
    if not itemName then return nil end
    for _, group in ipairs(self.db.groups) do
        for _, item in ipairs(group.items) do
            local name = item.recipeName or (item.link and GetItemInfo(item.link))
            if not name and item.link then
                name = item.link:match("%[(.-)%]")
            end
            
            if name == itemName then
                return item
            end
        end
    end
    return nil
end

function addon:GetAllTrackedItemNames(groupIndex)
    local names = {}
    if not self.db or not self.db.groups then return names end
    
    local groupsToScan = {}
    if groupIndex and self.db.groups[groupIndex] then
        table.insert(groupsToScan, self.db.groups[groupIndex])
    else
        groupsToScan = self.db.groups
    end

    local function addTrackedName(name)
        if name and (not self.db.vendorItems or not self.db.vendorItems[name]) then
            names[name] = true
        end
    end

    for _, group in ipairs(groupsToScan) do
        for _, item in ipairs(group.items) do
            -- Add recipe name (if present)
            if item.recipeName then
                addTrackedName(item.recipeName)
            end
            -- Add item name from link (may differ from recipeName)
            if item.link then
                local itemName = GetItemInfo(item.link)
                if not itemName then
                    itemName = item.link:match("%[(.-)%]")
                end
                addTrackedName(itemName)
            end
            
            -- Add all reagents
            if item.reagents then
                for _, reagent in ipairs(item.reagents) do
                    if reagent.name then
                        addTrackedName(reagent.name)
                    elseif reagent.link then
                        local rName = GetItemInfo(reagent.link) or reagent.link:match("%[(.-)%]")
                        addTrackedName(rName)
                    end
                end
            end
        end
    end
    return names
end

function addon:GetBagItemCount(link)
    if not link then return 0 end
    local itemID = link:match("item:(%d+)")
    if not itemID then return 0 end
    
    -- In TBC Anniversary/Classic, C_Item.GetItemCount is the preferred modern API
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID, false)
    end
    -- Fallback to global GetItemCount
    return GetItemCount(itemID)
end
