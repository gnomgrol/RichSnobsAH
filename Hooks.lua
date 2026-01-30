local addonName, addon = ...

function addon:SetupFrameHooks()
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self, event, arg1)
        if arg1 == "Blizzard_TradeSkillUI" then
            addon:CreateTradeSkillButton()
            addon:HookTradeSkill()
        elseif arg1 == "Blizzard_AuctionUI" then
            addon:CreateAuctionFrameButton()
        end
    end)

    -- Also check if already loaded
    local isLoaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        isLoaded = C_AddOns.IsAddOnLoaded("Blizzard_TradeSkillUI")
    else
        isLoaded = IsAddOnLoaded("Blizzard_TradeSkillUI")
    end

    if isLoaded then
        addon:CreateTradeSkillButton()
        addon:HookTradeSkill()
    end

    -- For AH, it's usually loaded or loads on first open
    -- In modern versions, we should wait for Blizzard_AuctionUI
    f:RegisterEvent("ADDON_LOADED")
    -- (Event script already registered above, but we need to handle Blizzard_AuctionUI there)

    -- Also check if already loaded
    local isAHLoaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        isAHLoaded = C_AddOns.IsAddOnLoaded("Blizzard_AuctionUI")
    else
        isAHLoaded = IsAddOnLoaded("Blizzard_AuctionUI")
    end

    if isAHLoaded then
        addon:CreateAuctionFrameButton()
    end

    -- Hook inventory item clicks
    hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self, button)
        if button == "LeftButton" and IsShiftKeyDown() then
            if addon.mainAHPanel and addon.mainAHPanel:IsShown() and addon.db.selectedTab == 3 then
                local bag, slot
                if self:GetParent().GetID then
                    bag = self:GetParent():GetID()
                else
                    bag = self:GetBagID()
                end
                slot = self:GetID()
                local itemLink = C_Container and C_Container.GetContainerItemLink(bag, slot) or GetContainerItemLink(bag, slot)
                
                if itemLink then
                    local texture = select(10, GetItemInfo(itemLink))
                    addon:ShowPostPane({
                        link = itemLink,
                        texture = texture
                    })
                end
            end
        end
    end)
end

function addon:CreateTradeSkillButton()
    if not TradeSkillFrame or addon.tsButton then return end
    
    local btn = CreateFrame("Button", nil, TradeSkillFrame, "UIPanelButtonTemplate")
    btn:SetWidth(100)
    btn:SetHeight(20)
    btn:SetText("Rich Snobs")
    -- Position it at the top left
    btn:SetPoint("TOPLEFT", TradeSkillFrame, "TOPLEFT", 60, -15)
    
    btn:SetScript("OnClick", function()
        addon:ToggleMainFrame()
    end)
    
    addon.tsButton = btn
end

function addon:CreateAuctionFrameButton()
    if not AuctionFrame or addon.ahButton then return end

    local btn = CreateFrame("Button", nil, AuctionFrame, "UIPanelButtonTemplate")
    btn:SetWidth(100)
    btn:SetHeight(20)
    btn:SetText("Rich Snobs")
    -- Position it at the top of AH frame
    btn:SetPoint("TOPRIGHT", AuctionFrame, "TOPRIGHT", -30, -15)

    btn:SetScript("OnClick", function()
        addon:ToggleMainFrame()
    end)

    addon.ahButton = btn
end

-- Hook TradeSkill recipe and reagent clicks
function addon:HookTradeSkill()
    if not TradeSkillFrame then return end
    
    -- Result Item
    if TradeSkillSkillIcon then
        TradeSkillSkillIcon:HookScript("OnClick", function(self)
            if IsAltKeyDown() then
                local link = GetTradeSkillItemLink(TradeSkillFrame.selectedSkill)
                if link then
                    addon:SearchAH(link, true)
                end
            end
        end)
        -- Add hint to tooltip
        TradeSkillSkillIcon:HookScript("OnEnter", function(self)
            GameTooltip:AddLine("|cffffaa00Alt-Click to search in Rich Snobs|r")
            GameTooltip:Show()
        end)
    end
    
    -- Reagents
    for i = 1, 8 do
        local reagent = _G["TradeSkillReagent"..i]
        if reagent then
            reagent:HookScript("OnClick", function(self)
                if IsAltKeyDown() then
                    local link = GetTradeSkillReagentItemLink(TradeSkillFrame.selectedSkill, i)
                    if link then
                        addon:SearchAH(link, true)
                    end
                end
            end)
            reagent:HookScript("OnEnter", function(self)
                GameTooltip:AddLine("|cffffaa00Alt-Click to search in Rich Snobs|r")
                GameTooltip:Show()
            end)
        end
    end
end
