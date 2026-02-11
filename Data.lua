local addonName, addon = ...

function addon:InitializeData()
    if not RichSnobsAHDB then
        RichSnobsAHDB = {
            minimap = { hide = false },
            groups = {}, -- list of groups: { name = "Consumables", items = {} }
            selectedGroupIndex = nil,
            prices = {}, -- [itemId or name] = copper
            fastScan = false,
        }
    end
    self.db = RichSnobsAHDB
    if not self.db.prices then self.db.prices = {} end
    if self.db.fastScan == nil then self.db.fastScan = false end
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
    return self.db.prices[itemName] or 0
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
                if rCost == 0 or craftCost < rCost then
                    rCost = craftCost
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

    for _, group in ipairs(groupsToScan) do
        for _, item in ipairs(group.items) do
            -- Add recipe name (if present)
            if item.recipeName then
                names[item.recipeName] = true
            end
            -- Add item name from link (may differ from recipeName)
            if item.link then
                local itemName = GetItemInfo(item.link)
                if not itemName then
                    itemName = item.link:match("%[(.-)%]")
                end
                if itemName then names[itemName] = true end
            end
            
            -- Add all reagents
            if item.reagents then
                for _, reagent in ipairs(item.reagents) do
                    if reagent.name then
                        names[reagent.name] = true
                    elseif reagent.link then
                        local rName = GetItemInfo(reagent.link) or reagent.link:match("%[(.-)%]")
                        if rName then names[rName] = true end
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
