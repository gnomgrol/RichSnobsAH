local addonName, addon = ...

-- Constants
local GROUP_ROW_HEIGHT = 20
local ITEM_ROW_HEIGHT = 30 -- collapsed
local ITEM_REAGENT_HEIGHT = 15
local MAX_GROUPS_DISPLAY = 15
local MAX_ITEMS_DISPLAY = 15

function addon:CreateMainFrame()
    local frame = CreateFrame("Frame", "RichSnobsAHMainFrame", UIParent, "BackdropTemplate")
    frame:SetWidth(600)
    frame:SetHeight(410)
    frame:SetPoint("CENTER", UIParent, "CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    frame:SetBackdropColor(0, 0, 0, 1.0)
    frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnHide", function()
        if addon.RestoreAH then addon:RestoreAH() end
    end)

    -- Register for inventory and AH change events
    frame:RegisterEvent("BAG_UPDATE")
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    frame:RegisterEvent("TRADE_SKILL_UPDATE")
    frame:RegisterEvent("CRAFT_UPDATE")
    pcall(function() frame:RegisterEvent("TRADE_SKILL_SHOW") end)
    pcall(function() frame:RegisterEvent("CRAFT_SHOW") end)
    
    -- AH Events (Safe registration)
    frame:RegisterEvent("AUCTION_HOUSE_SHOW")
    frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    pcall(function() frame:RegisterEvent("AUCTION_DISPLAY_SHOW") end)
    pcall(function() frame:RegisterEvent("AUCTION_FRAME_SHOW") end)
    pcall(function() frame:RegisterEvent("AUCTION_FRAME_CLOSED") end)
    
    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "AUCTION_HOUSE_SHOW" or event == "AUCTION_DISPLAY_SHOW" or event == "AUCTION_FRAME_SHOW" then
            addon.isAHStateOpen = true
            if addon.CollapseAH then addon:CollapseAH() end
            if addon.ShowMainAHPanel then addon:ShowMainAHPanel() end
            if frame.fullScanBtn then frame.fullScanBtn:Enable() end
        elseif event == "AUCTION_HOUSE_CLOSED" or event == "AUCTION_FRAME_CLOSED" then
            addon.isAHStateOpen = false
            if addon.mainAHPanel then addon.mainAHPanel:Hide() end
            if frame.fullScanBtn then frame.fullScanBtn:Disable() end
            
            -- Cancel all active scans when AH closes
            if addon.EndUndercutScan then addon:EndUndercutScan() end
            if addon.StopNormalScan then addon:StopNormalScan() end
            if addon.StopPostScan then addon:StopPostScan() end
        elseif event == "PLAYER_REGEN_DISABLED" then
            if frame:IsShown() then
                addon:ToggleMainFrame()
            end
        elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE"
            or event == "CRAFT_SHOW" or event == "CRAFT_UPDATE" then
            -- Refresh recipe difficulty colors against the open profession
            C_Timer.After(0.05, function()
                if addon.UpdateRecipeDifficulties then addon:UpdateRecipeDifficulties() end
            end)
        end

        if self:IsShown() then
            -- Small delay ensures the game has finished updating internal state (item counts, etc)
            C_Timer.After(0.1, function()
                if self:IsShown() then
                    addon:RefreshMainFrame()
                end
            end)
        end
    end)
    
    -- Close Button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    closeBtn:SetScript("OnClick", function()
        addon:ToggleMainFrame()
    end)

    -- View Mode Toggle (Profit / Leveling)
    local viewModeBtn = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
    viewModeBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, -2)
    viewModeBtn:SetWidth(110)
    viewModeBtn:SetHeight(18)
    viewModeBtn:SetNormalFontObject("GameFontNormalSmall")
    viewModeBtn:SetHighlightFontObject("GameFontHighlightSmall")
    viewModeBtn:SetScript("OnClick", function()
        if addon.db.viewMode == "leveling" then
            addon.db.viewMode = "profit"
        else
            addon.db.viewMode = "leveling"
        end
        addon:UpdateViewModeButton()
        addon:RefreshMainFrame()
    end)
    viewModeBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Toggle View Mode")
        GameTooltip:AddLine("Profit: profit per craft (selling)", 1, 1, 1)
        GameTooltip:AddLine("Leveling: expected cost per skill point", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffff8040Orange|r 100%, |cffffff00Yellow|r 75%, |cff40c040Green|r 25%, |cff808080Grey|r 0%")
        GameTooltip:AddLine("Open your profession window to refresh recipe colors.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    viewModeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.viewModeBtn = viewModeBtn

    function addon:UpdateViewModeButton()
        if not self.mainFrame or not self.mainFrame.viewModeBtn then return end
        if self.db.viewMode == "leveling" then
            self.mainFrame.viewModeBtn:SetText("View: |cff40c0ffLeveling|r")
        else
            self.mainFrame.viewModeBtn:SetText("View: |cffffd700Profit|r")
        end
    end
    
    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -15)
    title:SetText("Item Lists")
    frame.title = title

    -- AH Status Icon (Small gold coin in top left)
    local ahStatus = frame:CreateTexture(nil, "OVERLAY")
    ahStatus:SetWidth(16)
    ahStatus:SetHeight(16)
    ahStatus:SetPoint("TOPLEFT", 15, -12)
    ahStatus:SetTexture("Interface\\Icons\\Inv_Misc_Coin_01")
    ahStatus:Hide()
    frame.ahStatus = ahStatus

    -- AH Status Tooltip
    local ahStatusBtn = CreateFrame("Button", nil, frame)
    ahStatusBtn:SetAllPoints(ahStatus)
    ahStatusBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Auction House Status")
        GameTooltip:AddLine("Indicator active: AH is open.", 1, 1, 1)
        GameTooltip:Show()
    end)
    ahStatusBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.ahStatusBtn = ahStatusBtn

    -- GROUPS PANE (Left Side)
    local groupFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    groupFrame:SetPoint("TOPLEFT", 15, -40)
    groupFrame:SetPoint("BOTTOMLEFT", 15, 40)
    groupFrame:SetWidth(150)
    
    groupFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    groupFrame:SetBackdropColor(0, 0, 0, 1.0)
    groupFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    
    -- Group ScrollFrame
    local groupScroll = CreateFrame("ScrollFrame", "RichSnobsAHGroupScroll", groupFrame, "FauxScrollFrameTemplate")
    groupScroll:SetPoint("TOPLEFT", 0, -5)
    groupScroll:SetPoint("BOTTOMRIGHT", -30, 5)
    
    addon.groupRows = {}
    for i = 1, MAX_GROUPS_DISPLAY do
        local btn = CreateFrame("Button", nil, groupFrame)
        btn:SetHeight(GROUP_ROW_HEIGHT)
        btn:SetPoint("LEFT", 5, 0)
        btn:SetPoint("RIGHT", -5, 0)
        if i == 1 then
            btn:SetPoint("TOP", 0, -5)
        else
            btn:SetPoint("TOP", addon.groupRows[i-1], "BOTTOM")
        end
        
        local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("LEFT", 5, 0)
        btn.text = text
        
        local selectedTex = btn:CreateTexture(nil, "BACKGROUND")
        selectedTex:SetAllPoints()
        selectedTex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        selectedTex:SetBlendMode("ADD")
        selectedTex:Hide()
        btn.selectedTex = selectedTex

        btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        btn:GetHighlightTexture():SetBlendMode("ADD")
        
        btn:SetScript("OnClick", function(self)
            addon.db.selectedGroupIndex = self.groupID
            addon:RefreshMainFrame()
        end)
        
        addon.groupRows[i] = btn
    end
    
    -- Redesign Add Group Button (Small + button)
    local addGroupBtn = CreateFrame("Button", nil, frame)
    addGroupBtn:SetPoint("BOTTOMLEFT", groupFrame, "BOTTOMLEFT", 5, -25)
    addGroupBtn:SetSize(20, 20)
    addGroupBtn:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
    addGroupBtn:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
    addGroupBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
    addGroupBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Add New Group")
        GameTooltip:Show()
    end)
    addGroupBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    addGroupBtn:SetScript("OnClick", function()
        StaticPopupDialogs["RICHSNOBSAH_ADD_GROUP"] = {
            text = "Enter new group name:",
            button1 = "Accept",
            button2 = "Cancel",
            hasEditBox = true,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            OnShow = function(self)
                local editBox = _G[self:GetName() .. "EditBox"]
                editBox:EnableKeyboard(true)
                editBox:SetFocus()
            end,
            OnAccept = function(self)
                local editBox = _G[self:GetName() .. "EditBox"]
                local text = editBox:GetText()
                addon:AddGroup(text)
            end,
            EditBoxOnEnterPressed = function(self)
                local text = self:GetText()
                addon:AddGroup(text)
                self:GetParent():Hide()
            end,
            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end
        }
        StaticPopup_Show("RICHSNOBSAH_ADD_GROUP")
    end)
    
    -- Redesign Delete Group Button (Small - button with confirmation)
    local delGroupBtn = CreateFrame("Button", nil, frame)
    delGroupBtn:SetPoint("LEFT", addGroupBtn, "RIGHT", 5, 0)
    delGroupBtn:SetSize(20, 20)
    delGroupBtn:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
    delGroupBtn:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-Down")
    delGroupBtn:SetHighlightTexture("Interface\\Buttons\\UI-MinusButton-Hilight")
    delGroupBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Delete Selected Group")
        GameTooltip:Show()
    end)
    delGroupBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    delGroupBtn:SetScript("OnClick", function()
        if addon.db.selectedGroupIndex then
            local group = addon.db.groups[addon.db.selectedGroupIndex]
            StaticPopupDialogs["RICHSNOBSAH_CONFIRM_DELETE_GROUP"] = {
                text = "Are you sure you want to delete group '" .. (group.name or "Unknown") .. "'?",
                button1 = "Yes",
                button2 = "No",
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                OnAccept = function()
                    addon:DeleteGroup(addon.db.selectedGroupIndex)
                end,
            }
            StaticPopup_Show("RICHSNOBSAH_CONFIRM_DELETE_GROUP")
        end
    end)
    frame.delGroupBtn = delGroupBtn

    -- Rename Group Button
    local renameGroupBtn = CreateFrame("Button", nil, frame)
    renameGroupBtn:SetPoint("LEFT", delGroupBtn, "RIGHT", 5, 0)
    renameGroupBtn:SetSize(20, 20)
    renameGroupBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    renameGroupBtn:SetPushedTexture("Interface\\Buttons\\UI-OptionsButton")
    renameGroupBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    renameGroupBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Rename Selected Group")
        GameTooltip:Show()
    end)
    renameGroupBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    renameGroupBtn:SetScript("OnClick", function()
        if addon.db.selectedGroupIndex then
            local group = addon.db.groups[addon.db.selectedGroupIndex]
            StaticPopupDialogs["RICHSNOBSAH_RENAME_GROUP"] = {
                text = "Enter new name for group '" .. (group.name or "Unknown") .. "':",
                button1 = "Accept",
                button2 = "Cancel",
                hasEditBox = true,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                OnShow = function(self)
                    local editBox = _G[self:GetName() .. "EditBox"]
                    editBox:SetText(group.name or "")
                    editBox:HighlightText()
                    editBox:SetFocus()
                end,
                OnAccept = function(self)
                    local editBox = _G[self:GetName() .. "EditBox"]
                    local text = editBox:GetText()
                    addon:RenameGroup(addon.db.selectedGroupIndex, text)
                end,
                EditBoxOnEnterPressed = function(self)
                    local text = self:GetText()
                    addon:RenameGroup(addon.db.selectedGroupIndex, text)
                    self:GetParent():Hide()
                end,
                EditBoxOnEscapePressed = function(self)
                    self:GetParent():Hide()
                end
            }
            StaticPopup_Show("RICHSNOBSAH_RENAME_GROUP")
        end
    end)
    frame.renameGroupBtn = renameGroupBtn

    -- Move Up Button
    local moveUpBtn = CreateFrame("Button", nil, frame)
    moveUpBtn:SetPoint("LEFT", renameGroupBtn, "RIGHT", 5, 0)
    moveUpBtn:SetSize(20, 20)
    moveUpBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
    moveUpBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
    moveUpBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    moveUpBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Move Group Up")
        GameTooltip:Show()
    end)
    moveUpBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    moveUpBtn:SetScript("OnClick", function()
        if addon.db.selectedGroupIndex then
            addon:MoveGroup(addon.db.selectedGroupIndex, -1)
        end
    end)
    frame.moveUpBtn = moveUpBtn

    -- Move Down Button
    local moveDownBtn = CreateFrame("Button", nil, frame)
    moveDownBtn:SetPoint("LEFT", moveUpBtn, "RIGHT", 5, 0)
    moveDownBtn:SetSize(20, 20)
    moveDownBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    moveDownBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    moveDownBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    moveDownBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Move Group Down")
        GameTooltip:Show()
    end)
    moveDownBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    moveDownBtn:SetScript("OnClick", function()
        if addon.db.selectedGroupIndex then
            addon:MoveGroup(addon.db.selectedGroupIndex, 1)
        end
    end)
    frame.moveDownBtn = moveDownBtn

    -- ITEMS PANE (Right Side)
    local itemFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    itemFrame:SetPoint("TOPLEFT", groupFrame, "TOPRIGHT", 10, 0)
    itemFrame:SetPoint("BOTTOMRIGHT", -10, 40) -- Space for scrollbar
    
    itemFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    itemFrame:SetBackdropColor(0, 0, 0, 1.0)
    itemFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- Import Selection Button
    local importBtn = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
    importBtn:SetPoint("BOTTOMLEFT", itemFrame, "BOTTOMLEFT", 0, -25)
    importBtn:SetWidth(100)
    importBtn:SetHeight(20)
    importBtn:SetNormalFontObject("GameFontNormalSmall")
    importBtn:SetHighlightFontObject("GameFontHighlightSmall")
    importBtn:SetText("Import Recipe")
    importBtn:SetScript("OnClick", function()
        addon:ImportSelection()
    end)
    frame.importBtn = importBtn
    addon.importBtn = importBtn -- keep reference for disabling

    -- Add Item Button (for arbitrary non-craftable items)
    local addItemBtn = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
    addItemBtn:SetPoint("LEFT", importBtn, "RIGHT", 5, 0)
    addItemBtn:SetWidth(70)
    addItemBtn:SetHeight(20)
    addItemBtn:SetNormalFontObject("GameFontNormalSmall")
    addItemBtn:SetHighlightFontObject("GameFontHighlightSmall")
    addItemBtn:SetText("Add Item")

    -- Vendor Items Toggle Button
    local vendorBtn = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
    vendorBtn:SetPoint("LEFT", addItemBtn, "RIGHT", 5, 0)
    vendorBtn:SetWidth(95)
    vendorBtn:SetHeight(20)
    vendorBtn:SetNormalFontObject("GameFontNormalSmall")
    vendorBtn:SetHighlightFontObject("GameFontHighlightSmall")
    vendorBtn:SetText("Vendor Items")
    vendorBtn:SetScript("OnClick", function()
        if addon.ToggleVendorItemsPopout then
            addon:ToggleVendorItemsPopout()
        end
    end)
    frame.vendorBtn = vendorBtn
    addon.vendorBtn = vendorBtn

    -- Helper: add an item link directly to the current group
    function addon:AddItemFromLink(link)
        if not link or not addon.db.selectedGroupIndex then return end
        local itemLink = link:match("|c.-|Hitem:.-|h%[.-%]|h|r")
        if not itemLink then return end
        local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemLink)
        addon:AddItemToGroup(addon.db.selectedGroupIndex, {
            link = itemLink,
            texture = itemTexture or "Interface\\Icons\\Inv_Misc_QuestionMark",
            count = 1,
            reagents = {},
        })
        -- Update the edit box to show what was added
        if addon.addItemActiveEditBox then
            addon.addItemActiveEditBox:SetText(itemLink)
        end
    end

    -- Hook HandleModifiedItemClick ONCE to intercept Shift-clicks on bag items
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if addon.addItemActiveEditBox and addon.addItemActiveEditBox:IsVisible() and link then
            addon:AddItemFromLink(link)
        end
    end)

    -- Hook ChatEdit_InsertLink for links clicked from chat messages
    local orig_ChatEdit_InsertLink = ChatEdit_InsertLink
    ChatEdit_InsertLink = function(link, ...)
        if addon.addItemActiveEditBox and addon.addItemActiveEditBox:IsVisible() then
            addon:AddItemFromLink(link)
            return true
        end
        return orig_ChatEdit_InsertLink(link, ...)
    end

    addItemBtn:SetScript("OnClick", function()
        if not addon.db.selectedGroupIndex then
            addon.print("No group selected.")
            return
        end
        addon:ToggleAddItemPopout()
    end)
    frame.addItemBtn = addItemBtn
    addon.addItemBtn = addItemBtn

    -- Full Scan Button
    local fullScanBtn = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
    fullScanBtn:SetPoint("BOTTOMRIGHT", itemFrame, "BOTTOMRIGHT", 0, -25)
    fullScanBtn:SetWidth(120)
    fullScanBtn:SetHeight(20)
    fullScanBtn:SetNormalFontObject("GameFontNormalSmall")
    fullScanBtn:SetHighlightFontObject("GameFontHighlightSmall")
    fullScanBtn:SetText("Scan Entire List")
    fullScanBtn:SetScript("OnClick", function()
        addon:StartFullScan()
    end)
    -- Initial state based on AH
    if addon:IsAHOpen() then
        fullScanBtn:Enable()
    else
        fullScanBtn:Disable()
    end
    frame.fullScanBtn = fullScanBtn
    addon.fullScanBtn = fullScanBtn -- keep global reference
    
    -- Container for clipping items
    local itemListContainer = CreateFrame("Frame", nil, itemFrame)
    itemListContainer:SetPoint("TOPLEFT", 5, -5)
    itemListContainer:SetPoint("BOTTOMRIGHT", -25, 5) -- Space for scrollbar on right
    itemListContainer:SetClipsChildren(true)
    
    local itemScroll = CreateFrame("ScrollFrame", "RichSnobsAHItemScroll", frame, "FauxScrollFrameTemplate")
    itemScroll:SetPoint("TOPLEFT", itemFrame, "TOPLEFT", 0, -5)
    itemScroll:SetPoint("BOTTOMRIGHT", itemFrame, "BOTTOMRIGHT", -30, 5)
    
    itemScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 1, function() addon:RefreshMainFrame() end)
    end)
    
    -- SearchAH is now defined in AuctionSearch.lua
    -- Create the AH results pane (part of this frame)
    addon:CreateMainAHPanel(frame)

    -- Helper function to calculate max craftable for an item
    function addon:GetMaxCraftable(item)
        if not item.reagents or #item.reagents == 0 then
            return 0
        end
        local maxCraft = 9999
        for _, r in ipairs(item.reagents) do
            local owned = 0
            if r.link then 
                owned = (C_Item and C_Item.GetItemCount(r.link, true)) or GetItemCount(r.link, true)
            end
            local req = r.count or 1
            local canMake = math.floor(owned / req)
            if canMake < maxCraft then maxCraft = canMake end
        end
        return maxCraft
    end

    function addon:PerformCraft(item)
        if not item.profession or not item.recipeName then
            addon.print("Missing profession/recipe data. Please re-import this item.")
            return
        end
        
        -- Calculate max craftable
        local maxCraft = self:GetMaxCraftable(item)
        
        if maxCraft == 0 then
            addon.print("Not enough reagents to craft " .. item.recipeName)
            return
        end
        
        addon.print("Attempting to craft " .. maxCraft .. "x " .. item.recipeName)
        
        -- Check if profession window is already open and for the CORRECT profession
        local windowAlreadyOpen = false
        if item.isCraft then
            -- Enchanting uses CraftFrame
            if CraftFrame and CraftFrame:IsVisible() then
                local currentProf = GetCraftDisplaySkillLine()
                if currentProf == item.profession then
                    windowAlreadyOpen = true
                else
                    -- Wrong profession open, close it
                    CloseCraft()
                end
            end
        else
            -- Other professions use TradeSkillFrame
            if TradeSkillFrame and TradeSkillFrame:IsVisible() then
                local currentProf = GetTradeSkillLine()
                if currentProf == item.profession then
                    windowAlreadyOpen = true
                else
                    -- Wrong profession open, close it
                    CloseTradeSkill()
                end
            end
        end
        
        -- Helper function to execute the actual crafting
        local function executeCrafting()
            local found = false
            
            if item.isCraft then
                 -- Enchanting/CraftFrame logic
                 addon.print("Mass crafting not fully supported for Enchanting yet.")
                 return
            else
                 -- TradeSkill logic
                 local num = GetNumTradeSkills()
                 for i = 1, num do
                     local name, type = GetTradeSkillInfo(i)
                     if name == item.recipeName and type ~= "header" then
                         -- DoTradeSkill(index, [num])
                         DoTradeSkill(i, maxCraft)
                         found = true
                         break
                     end
                 end
            end
            
            if not found then
                addon.print("Recipe " .. item.recipeName .. " not found in current list.")
            end
        end
        
        -- If window is already open, execute crafting immediately
        if windowAlreadyOpen then
            executeCrafting()
            return
        end
        
        -- Otherwise, open the profession window and wait for it
        CastSpellByName(item.profession)
        
        -- Wait for window logic
        local f = CreateFrame("Frame")
        f:RegisterEvent("TRADE_SKILL_SHOW")
        f:RegisterEvent("CRAFT_SHOW")
        
        local totalElapsed = 0
        f:SetScript("OnUpdate", function(self, elapsed)
            totalElapsed = totalElapsed + elapsed
            if totalElapsed > 2 then -- Timeout
               self:SetScript("OnUpdate", nil)
               self:UnregisterAllEvents()
            end
        end)
        
        f:SetScript("OnEvent", function(self, event)
            executeCrafting()
            self:SetScript("OnUpdate", nil)
            self:UnregisterAllEvents()
        end)
    end

    addon.itemRows = {}
    for i = 1, MAX_ITEMS_DISPLAY do
        local row = CreateFrame("Button", nil, itemListContainer)
        row:SetHeight(ITEM_ROW_HEIGHT)
        row:SetPoint("LEFT", 0, 0)
        row:SetPoint("RIGHT", 0, 0)
        
        if i == 1 then
            row:SetPoint("TOP", 0, -5)
        else
            row:SetPoint("TOP", addon.itemRows[i-1], "BOTTOM", 0, -2)
        end
        
        -- Item Icon (now a button for crafting)
        local iconBtn = CreateFrame("Button", nil, row)
        iconBtn:SetWidth(24)
        iconBtn:SetHeight(24)
        iconBtn:SetPoint("TOPLEFT", 5, -3)
        
        local icon = iconBtn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        iconBtn.texture = icon
        row.icon = icon -- keep reference for Refresh
        
        local yieldText = iconBtn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        yieldText:SetPoint("BOTTOMRIGHT", iconBtn, "BOTTOMRIGHT", -2, 2)
        yieldText:SetJustifyH("RIGHT")
        row.yieldText = yieldText
        
        iconBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        iconBtn:GetHighlightTexture():SetBlendMode("ADD")
        
        iconBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Left Click: Craft All")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("RIGHT", self, "LEFT", -5, 0)
            GameTooltip:Show()
        end)
        iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        
        iconBtn:SetScript("OnClick", function(self)
             if row.itemIndex and addon.db.selectedGroupIndex then
                local item = addon.db.groups[addon.db.selectedGroupIndex].items[row.itemIndex]
                addon:PerformCraft(item)
             end
        end)
        row.iconBtn = iconBtn
        
        local nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameStr:SetPoint("LEFT", iconBtn, "RIGHT", 5, 5)
        row.name = nameStr
        nameStr:SetFontObject("GameFontNormalSmall")
        nameStr:SetWordWrap(false)
        nameStr:SetJustifyH("LEFT")

        local countStr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.countText = countStr

        local extraCountStr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.extraCountText = extraCountStr
        
        local delBtn = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        delBtn:SetWidth(24); delBtn:SetHeight(24)
        delBtn:SetPoint("TOPRIGHT", -5, -3)
        delBtn:SetScript("OnClick", function(self)
             if row.itemIndex and addon.db.selectedGroupIndex then
                addon:DeleteItem(addon.db.selectedGroupIndex, row.itemIndex)
             end
        end)
        row.delBtn = delBtn
        
        -- Post button (to open PostPane for this item)
        local postItemBtn = CreateFrame("Button", nil, row, "GameMenuButtonTemplate")
        postItemBtn:SetWidth(40); postItemBtn:SetHeight(18)
        postItemBtn:SetPoint("RIGHT", delBtn, "LEFT", -5, 0)
        postItemBtn:SetNormalFontObject("GameFontNormalSmall")
        postItemBtn:SetHighlightFontObject("GameFontHighlightSmall")
        postItemBtn:SetText("Post")
        postItemBtn:SetScript("OnClick", function(self)
             if row.itemIndex and addon.db.selectedGroupIndex then
                local item = addon.db.groups[addon.db.selectedGroupIndex].items[row.itemIndex]
                addon:ShowPostPane(item)
             end
        end)
        row.postItemBtn = postItemBtn

        -- Move Item Up Button
        local moveItemUpBtn = CreateFrame("Button", nil, row)
        moveItemUpBtn:SetWidth(24); moveItemUpBtn:SetHeight(24)
        moveItemUpBtn:SetPoint("RIGHT", postItemBtn, "LEFT", -5, 0)
        moveItemUpBtn:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up")
        moveItemUpBtn:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down")
        moveItemUpBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
        moveItemUpBtn:SetScript("OnClick", function(self)
             if row.itemIndex and addon.db.selectedGroupIndex then
                addon:MoveItem(addon.db.selectedGroupIndex, row.itemIndex, -1)
             end
        end)
        row.moveItemUpBtn = moveItemUpBtn

        -- Move Item Down Button
        local moveItemDownBtn = CreateFrame("Button", nil, row)
        moveItemDownBtn:SetWidth(24); moveItemDownBtn:SetHeight(24)
        moveItemDownBtn:SetPoint("RIGHT", moveItemUpBtn, "LEFT", -2, 0)
        moveItemDownBtn:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
        moveItemDownBtn:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down")
        moveItemDownBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
        moveItemDownBtn:SetScript("OnClick", function(self)
             if row.itemIndex and addon.db.selectedGroupIndex then
                addon:MoveItem(addon.db.selectedGroupIndex, row.itemIndex, 1)
             end
        end)
        row.moveItemDownBtn = moveItemDownBtn

        -- Anchor count text to the left of moveItemDownBtn
        row.countText:SetPoint("RIGHT", moveItemDownBtn, "LEFT", -5, 5)
        row.extraCountText:SetPoint("RIGHT", moveItemDownBtn, "LEFT", -5, -6)
        row.name:SetPoint("RIGHT", row.countText, "LEFT", -5, 0)

        local profitStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        profitStr:SetPoint("TOPLEFT", nameStr, "BOTTOMLEFT", 0, -2)
        row.profitText = profitStr
        
        -- Reagents container (initially hidden)
        local reagentFrame = CreateFrame("Frame", nil, row)
        reagentFrame:SetPoint("TOP", row, "TOP", 0, -ITEM_ROW_HEIGHT)
        reagentFrame:SetPoint("LEFT", 30, 0)
        reagentFrame:SetPoint("RIGHT", -30, 0)
        reagentFrame:Hide() -- hide by default
        row.reagentFrame = reagentFrame
        row.reagentLines = {}
        
        row:SetScript("OnClick", function(self)
            if IsShiftKeyDown() then
                if self.itemIndex and addon.db.selectedGroupIndex then
                    local item = addon.db.groups[addon.db.selectedGroupIndex].items[self.itemIndex]
                    if addon.addItemActiveEditBox and addon.addItemActiveEditBox:IsVisible() then
                        -- Add Item dialog is open: add this item to the group
                        addon:AddItemFromLink(item.link)
                    else
                        addon:SearchAH(item.link, true)
                    end
                end
            else
                -- Toggle expand (only for craftable items with reagents)
                if self.itemIndex and addon.db.selectedGroupIndex then
                    local item = addon.db.groups[addon.db.selectedGroupIndex].items[self.itemIndex]
                    if item.reagents and #item.reagents > 0 then
                        item.expanded = not item.expanded
                        addon:RefreshMainFrame()
                    end
                end
            end
        end)
        
        row:SetScript("OnEnter", function(self)
             if self.itemIndex and addon.db.selectedGroupIndex then
                local item = addon.db.groups[addon.db.selectedGroupIndex].items[self.itemIndex]
                if item.link then
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    GameTooltip:SetHyperlink(item.link)
                    GameTooltip:ClearAllPoints()
                    GameTooltip:SetPoint("RIGHT", self, "LEFT", -5, 0)
                    GameTooltip:Show()
                end
             end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        
        addon.itemRows[i] = row
    end
    
    self.groupScroll = groupScroll
    self.itemScroll = itemScroll
    self.mainFrame = frame
end

function addon:ToggleMainFrame()
    if self.mainFrame:IsShown() then
        self.mainFrame:Hide()
        if addon.RestoreAH then addon:RestoreAH() end
    else
        self.mainFrame:Show()
        self:RefreshMainFrame()
        if addon.CollapseAH then addon:CollapseAH() end
    end
end

function addon:RefreshMainFrame()
    if not self.mainFrame or not self.mainFrame:IsShown() then return end
    
    -- Refresh Groups
    local groups = self.db.groups or {}
    local numGroups = #groups
    FauxScrollFrame_Update(self.groupScroll, numGroups, MAX_GROUPS_DISPLAY, GROUP_ROW_HEIGHT)
    
    local offset = FauxScrollFrame_GetOffset(self.groupScroll)
    for i = 1, MAX_GROUPS_DISPLAY do
        local row = self.groupRows[i]
        local index = offset + i
        if index <= numGroups then
            row.groupID = index
            row.text:SetText(groups[index].name)
            if index == self.db.selectedGroupIndex then
                row.text:SetTextColor(1, 1, 1) -- Keep white text
                row.selectedTex:Show()
            else
                row.text:SetTextColor(1, 1, 1) -- White normally
                row.selectedTex:Hide()
            end
            row:Show()
        else
            row:Hide()
        end
    end

    -- Update Group Management Buttons
    if self.db.selectedGroupIndex then
        self.mainFrame.delGroupBtn:Enable()
        self.mainFrame.renameGroupBtn:Enable()
        
        if self.db.selectedGroupIndex > 1 then
            self.mainFrame.moveUpBtn:Enable()
            self.mainFrame.moveUpBtn:GetNormalTexture():SetDesaturated(false)
        else
            self.mainFrame.moveUpBtn:Disable()
            self.mainFrame.moveUpBtn:GetNormalTexture():SetDesaturated(true)
        end
        
        if self.db.selectedGroupIndex < numGroups then
            self.mainFrame.moveDownBtn:Enable()
            self.mainFrame.moveDownBtn:GetNormalTexture():SetDesaturated(false)
        else
            self.mainFrame.moveDownBtn:Disable()
            self.mainFrame.moveDownBtn:GetNormalTexture():SetDesaturated(true)
        end
    else
        self.mainFrame.delGroupBtn:Disable()
        self.mainFrame.renameGroupBtn:Disable()
        self.mainFrame.moveUpBtn:Disable()
        self.mainFrame.moveUpBtn:GetNormalTexture():SetDesaturated(true)
        self.mainFrame.moveDownBtn:Disable()
        self.mainFrame.moveDownBtn:GetNormalTexture():SetDesaturated(true)
    end
    
    -- Update AH Status Indicator
    local ahOpen = addon:IsAHOpen()
    if ahOpen then
        self.mainFrame.ahStatus:Show()
        if self.mainFrame.fullScanBtn then self.mainFrame.fullScanBtn:Enable() end
    else
        self.mainFrame.ahStatus:Hide()
        if self.mainFrame.fullScanBtn then self.mainFrame.fullScanBtn:Disable() end
    end

    -- Keep the view-mode toggle text in sync with state
    if self.UpdateViewModeButton then self:UpdateViewModeButton() end

    -- Refresh Items
    if not self.db.selectedGroupIndex or not groups[self.db.selectedGroupIndex] then
        -- Clear items if no group selected
        for _, row in ipairs(self.itemRows) do row:Hide() end
        return
    end

    local items = groups[self.db.selectedGroupIndex].items or {}
    local levelingMode = (self.db.viewMode == "leveling")

    -- Build display order: in leveling mode, sort by expected cost-per-skill-point ascending,
    -- pushing items with no skill-up potential (grey/unknown/missing prices) to the bottom.
    local renderOrder = {}
    for i = 1, #items do renderOrder[i] = i end
    if levelingMode then
        local costCache = {}
        for i, it in ipairs(items) do
            costCache[i] = self:GetCostPerSkillUp(it)
        end
        table.sort(renderOrder, function(a, b)
            local ca, cb = costCache[a], costCache[b]
            if ca and cb then
                if ca ~= cb then return ca < cb end
                return a < b
            end
            if ca then return true end
            if cb then return false end
            return a < b
        end)
    end

    -- Calculate total height for scrolling
    local totalHeight = 0
    local itemHeights = {}
    local MAX_VIEWPORT_HEIGHT = 320
    for i, item in ipairs(items) do
        local h = ITEM_ROW_HEIGHT
        if item.expanded then
            local numReagents = #(item.reagents or {})
            h = ITEM_ROW_HEIGHT + (numReagents * ITEM_REAGENT_HEIGHT) + 5
        end
        itemHeights[i] = h
        totalHeight = totalHeight + h + 2 -- +2 for the spacing between rows
    end

    self.lastItemTotalHeight = totalHeight

    -- FauxScrollFrame_Update(frame, numItems, displayableItems, itemHeight)
    -- We'll use totalHeight as numItems and 1 as itemHeight to simulate pixel-perfect scrolling
    FauxScrollFrame_Update(self.itemScroll, totalHeight, MAX_VIEWPORT_HEIGHT, 1) 
    
    local offset = FauxScrollFrame_GetOffset(self.itemScroll)
    local currentY = 0
    local prevRow = nil
    local rowIdx = 1

    for displayPos = 1, #renderOrder do
        local i = renderOrder[displayPos]
        local item = items[i]
        local h = itemHeights[i]
        
        -- Check if this item should be visible
        if currentY + h > offset and currentY < offset + MAX_VIEWPORT_HEIGHT then
            if rowIdx <= MAX_ITEMS_DISPLAY then
                local row = self.itemRows[rowIdx]
                row.itemIndex = i
                
                local isCraftable = item.reagents and #item.reagents > 0
                local countText = ""
                
                local bagCount = 0
                local ahCount = 0
                if item.link then
                    bagCount = (C_Item and C_Item.GetItemCount(item.link, false)) or GetItemCount(item.link, false)
                    local itemName = GetItemInfo(item.link) or item.link:match("%[(.-)%]")
                    if itemName then
                        ahCount = addon:GetAHItemCount(itemName)
                    end
                end

                local bColor = bagCount > 0 and "|cff00ff00" or "|cffffffff"
                local aColor = ahCount > 0 and "|cff00ff00" or "|cffffffff"

                if isCraftable then
                    -- Craftable item: show bag count + craftable count
                    local craftCount = addon:GetMaxCraftable(item)
                    local cColor = craftCount > 0 and "|cffffff00" or "|cffffffff"

                    row.countText:SetText(string.format("|cffaaaaaa[|r%sB:%d|r %sAH:%d|r|cffaaaaaa]|r", bColor, bagCount, aColor, ahCount))
                    row.extraCountText:SetText(string.format("Craft: |cffaaaaaa[|r%s%d|r|cffaaaaaa]|r", cColor, craftCount))
                    row.extraCountText:Show()

                    local craftCost = addon:CalculateCraftCost(item)

                    if levelingMode then
                        -- Leveling mode: show difficulty + cost-per-SP for both vendor and AH disposal
                        local diff = item.difficulty
                        local diffColor = addon:GetDifficultyColor(diff)
                        local diffLabel = addon:GetDifficultyLabel(diff)
                        local chance = addon:GetSkillUpChance(diff)

                        if chance > 0 and craftCost > 0 then
                            local vCost = addon:GetCostPerSkillUp(item, "vendor")
                            local aCost = addon:GetCostPerSkillUp(item, "ah")
                            local function fmt(c)
                                if not c then return "|cff888888-|r" end
                                local color = (c < 0) and "|cff00ff80" or "|cffffffff"
                                return color .. addon:FormatMoney(c, true) .. "|r"
                            end
                            row.profitText:SetText(string.format("%s%s|r |cffccccccV/SP:|r %s  |cffccccccAH/SP:|r %s",
                                diffColor, diffLabel, fmt(vCost), fmt(aCost)))
                        elseif chance > 0 then
                            row.profitText:SetText(string.format("%s%s|r |cffaaaaaa(no price data)|r", diffColor, diffLabel))
                        elseif diff == "trivial" then
                            row.profitText:SetText(string.format("%s%s|r |cff888888no skill-up|r", diffColor, diffLabel))
                        else
                            row.profitText:SetText("|cffaaaaaaopen profession to detect color|r")
                        end
                    else
                        -- Profit mode: profit per craft after AH cut
                        local sellPrice = addon:GetCraftedAHPrice(item)
                        local yield = item.yield or 1
                        local unitCraftCost = craftCost / yield
                        local ahCutMultiplier = 0.95 -- 5% AH Cut
                        local profit = (sellPrice * ahCutMultiplier) - unitCraftCost
                        if craftCost > 0 and sellPrice > 0 then
                            local color = (profit > 0) and "|cff00ff00" or "|cffff0000"
                            row.profitText:SetText(color .. "P: " .. addon:FormatMoney(profit, true) .. "|r")
                        elseif craftCost > 0 then
                            row.profitText:SetText("|cffccccccC: " .. addon:FormatMoney(unitCraftCost, true) .. "|r")
                        else
                            row.profitText:SetText("")
                        end
                    end
                else
                    -- Non-craftable item: show bag count and AH price
                    row.countText:SetText(string.format("|cffaaaaaa[|r%sB:%d|r %sAH:%d|r|cffaaaaaa]|r", bColor, bagCount, aColor, ahCount))
                    row.extraCountText:Hide()

                    if levelingMode then
                        -- Reagents and other non-craftables don't apply to skill-up calculations
                        row.profitText:SetText("")
                    else
                        -- Show AH price
                        local ahPrice = 0
                        if item.link then
                            local itemName = GetItemInfo(item.link)
                            if itemName then
                                ahPrice = addon:GetItemPrice(itemName)
                            end
                            if ahPrice == 0 then
                                local rawName = item.link:match("%[(.-)%]")
                                if rawName then ahPrice = addon:GetItemPrice(rawName) end
                            end
                        end
                        if ahPrice > 0 then
                            row.profitText:SetText("|cffffcc00" .. addon:FormatMoney(ahPrice, true) .. "|r")
                        else
                            row.profitText:SetText("")
                        end
                    end
                end

                if item.link then
                    local itemName = GetItemInfo(item.link) or item.link:match("%[(.-)%]")
                    if itemName and addon.db.vendorItems and addon.db.vendorItems[itemName] then
                        row.name:SetText(item.link:gsub("|cff%x%x%x%x%x%x", "|cffffff00"))
                    else
                        row.name:SetText(item.link)
                    end
                else
                    row.name:SetText("Unknown Item")
                end
                row.icon:SetTexture(item.texture or "Interface\\Icons\\Inv_Misc_QuestionMark")
                
                if item.yield and item.yield > 1 then
                    row.yieldText:SetText(item.yield)
                    row.yieldText:Show()
                else
                    row.yieldText:Hide()
                end
                
                -- Enable/Disable Post button based on AH state
                if addon:IsAHOpen() then
                    row.postItemBtn:Enable()
                else
                    row.postItemBtn:Disable()
                end
                
                -- Update item move buttons (disabled in leveling mode since list is auto-sorted)
                local numItems = #items
                if not levelingMode and i > 1 then
                    row.moveItemUpBtn:Enable()
                    row.moveItemUpBtn:GetNormalTexture():SetDesaturated(false)
                else
                    row.moveItemUpBtn:Disable()
                    row.moveItemUpBtn:GetNormalTexture():SetDesaturated(true)
                end

                if not levelingMode and i < numItems then
                    row.moveItemDownBtn:Enable()
                    row.moveItemDownBtn:GetNormalTexture():SetDesaturated(false)
                else
                    row.moveItemDownBtn:Disable()
                    row.moveItemDownBtn:GetNormalTexture():SetDesaturated(true)
                end

                -- Setup Reagents
                if item.expanded then
                    -- layout reagents
                    local numReagents = #(item.reagents or {})
                    local rHeight = numReagents * ITEM_REAGENT_HEIGHT
                    row:SetHeight(ITEM_ROW_HEIGHT + rHeight + 5)
                    row.reagentFrame:Show()
                    row.reagentFrame:SetHeight(rHeight)
                    
                    -- Populate reagent lines
                    for rI = 1, numReagents do
                       if not row.reagentLines[rI] then
                           local rBtn = CreateFrame("Button", nil, row.reagentFrame)
                           rBtn:SetHeight(ITEM_REAGENT_HEIGHT)
                           rBtn:SetPoint("TOPLEFT", 0, -(rI-1)*ITEM_REAGENT_HEIGHT)
                           rBtn:SetPoint("RIGHT", 0, 0)
                           
                           local rIcon = rBtn:CreateTexture(nil, "ARTWORK")
                           rIcon:SetWidth(14); rIcon:SetHeight(14)
                           rIcon:SetPoint("LEFT", 0, 0)
                           
                           local rLine = rBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                           rLine:SetPoint("LEFT", rIcon, "RIGHT", 5, 0)
                           rLine:SetJustifyH("LEFT")
                           rLine:SetWidth(200) -- give it space
                           
                           local rCost = rBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                           rCost:SetPoint("RIGHT", -5, 0)
                           rCost:SetJustifyH("RIGHT")

                           rBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                           rBtn:GetHighlightTexture():SetBlendMode("ADD")
                          
                           rBtn:SetScript("OnEnter", function(self)
                               if self.link then
                                   GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                                   GameTooltip:SetHyperlink(self.link)
                                   GameTooltip:ClearAllPoints()
                                   GameTooltip:SetPoint("RIGHT", self, "LEFT", -5, 0)
                                   GameTooltip:Show()
                               end
                           end)
                           rBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                           rBtn:SetScript("OnClick", function(self)
                               if self.link then
                                   addon:SearchAH(self.link, true)
                               end
                           end)
                          
                           row.reagentLines[rI] = { btn = rBtn, text = rLine, icon = rIcon, cost = rCost }
                       end
                       
                       local rData = item.reagents[rI]
                       local lineObj = row.reagentLines[rI]
                       
                       local dataLink = rData.link
                       local owned = 0
                       if dataLink then
                           owned = (C_Item and C_Item.GetItemCount(dataLink, true)) or GetItemCount(dataLink, true) -- true = include bank
                       end
                       
                       local color = "|cffff0000" -- Red
                       local required = rData.count or 1
                       if owned >= required then
                           color = "|cff00ff00" -- Green
                       end
                       
                       local reagentLink = rData.link or "Reagent"
                       if reagentLink ~= "Reagent" then
                           local itemName = GetItemInfo(reagentLink) or reagentLink:match("%[(.-)%]")
                           if itemName and addon.db.vendorItems and addon.db.vendorItems[itemName] then
                               reagentLink = reagentLink:gsub("|cff%x%x%x%x%x%x", "|cffffff00")
                           end
                       end
                       
                       lineObj.text:SetText((rData.count or 1) .. "x " .. reagentLink .. " " .. color .. owned .. "|r")
                      
                       local rPrice = addon:GetItemPrice(rData.name)
                       if rPrice > 0 then
                           lineObj.cost:SetText("|cffcccccc" .. addon:FormatMoney(rPrice, true) .. "|r")
                           lineObj.cost:Show()
                       else
                           lineObj.cost:Hide()
                       end

                       lineObj.text:Show()
                       
                       lineObj.icon:SetTexture(rData.texture or "Interface\\Icons\\Inv_Misc_QuestionMark")
                       lineObj.icon:Show()
                       
                       lineObj.btn.link = rData.link
                       lineObj.btn:Show()
                    end
                    -- Hide unused lines
                    for rI = numReagents + 1, #row.reagentLines do
                       row.reagentLines[rI].btn:Hide()
                    end
                else
                    row:SetHeight(ITEM_ROW_HEIGHT)
                    row.reagentFrame:Hide()
                end
                
                row:ClearAllPoints()
                row:SetPoint("LEFT", 0, 0)
                row:SetPoint("RIGHT", 0, 0)
                if rowIdx == 1 then
                    row:SetPoint("TOP", 0, -(currentY - offset))
                else
                    row:SetPoint("TOP", prevRow, "BOTTOM", 0, -2)
                end
                
                row:Show()
                prevRow = row
                rowIdx = rowIdx + 1
            end
        end
        currentY = currentY + h + 2 -- +2 for the spacing between rows
    end

    -- Hide remaining rows
    for i = rowIdx, MAX_ITEMS_DISPLAY do
        self.itemRows[i]:Hide()
    end
end

function addon:ScrollItemListToBottom()
    if not self.itemScroll or not self.lastItemTotalHeight then return end
    local maxOffset = math.max(0, self.lastItemTotalHeight - 320) -- 320 is MAX_VIEWPORT_HEIGHT
    FauxScrollFrame_SetOffset(self.itemScroll, maxOffset)
    self:RefreshMainFrame()
end
