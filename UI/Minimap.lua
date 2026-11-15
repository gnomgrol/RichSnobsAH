-- The minimap button, made by LibDBIcon so minimap button managers such as
-- Leatrix Plus can gather it. Click to open the window, drag to move it.
-- /rsah minimap hides or shows it; the minimap's addon menu has an entry too.

local addonName, addon = ...

local DBIcon = LibStub("LibDBIcon-1.0")

local launcher = LibStub("LibDataBroker-1.1"):NewDataObject(addonName, {
    type = "launcher",
    text = "RichSnobsAH",
    icon = "Interface\\Icons\\INV_Misc_Coin_02",
    OnClick = function() addon:Toggle() end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("RichSnobsAH")
        tooltip:AddLine("Click to open your lists. Drag to move.", 1, 1, 1)
    end,
})

-- The button keeps its place and visibility in the saved minimap table.
addon:Listen("DB_READY", function()
    DBIcon:Register(addonName, launcher, addon.db.minimap)
end)

function addon:ToggleMinimapButton()
    local settings = self.db.minimap
    settings.hide = not settings.hide
    if settings.hide then
        DBIcon:Hide(addonName)
    else
        DBIcon:Show(addonName)
    end
end
