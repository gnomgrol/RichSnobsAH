local addonName, addon = ...

function addon:CreateMinimapButton()
    local button = CreateFrame("Button", "RichSnobsAHMinimapButton", Minimap)
    button:SetFrameLevel(Minimap:GetFrameLevel() + 10)
    button:SetWidth(32)
    button:SetHeight(32)
    button:SetNormalTexture("Interface\\Icons\\Trade_BlackSmithing") -- Placeholder icon
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(self, buttonPressed)
        if buttonPressed == "LeftButton" then
            addon:ToggleMainFrame()
        end
    end)
    
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("RichSnobsAH")
        GameTooltip:AddLine("Left Click: Open Window", 1, 1, 1)
        GameTooltip:Show()
    end)
    
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    
    -- Positioning logic (simple angle based)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    
    local isDragging = false
    button:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        isDragging = true
        self:SetScript("OnUpdate", function(self)
            local x, y = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local dx, dy = cx - x, cy - y
            local angle = math.atan2(dy, dx)
            
            -- Keep the button on the radius of the minimap
            local radius = 80
            local bx = math.cos(angle) * radius
            local by = math.sin(angle) * radius
            
            self:ClearAllPoints()
            self:SetPoint("CENTER", Minimap, "CENTER", bx, by)
            
            -- Save position if we had DB
            -- addon.db.minimap.angle = angle 
        end)
    end)
    
    button:SetScript("OnDragStop", function(self)
        self:UnlockHighlight()
        isDragging = false
        self:SetScript("OnUpdate", nil)
    end)
    
    -- Initial position
    local angle = math.rad(45) -- default 45 degrees
    local radius = 80
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle)*radius, math.sin(angle)*radius)
    
    self.minimapButton = button
end
