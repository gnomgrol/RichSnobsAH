RichSnobsAH = LibStub and LibStub("AceAddon-3.0"):NewAddon("RichSnobsAH", "AceConsole-3.0", "AceEvent-3.0") or {}
-- Fallback if Ace is not present, though we will try to write vanilla-friendly code mostly, 
-- but structure it nicely. For now, let's assume no libs are embedded and write pure Lua/WoW API 
-- unless the user wants us to embed libs. To keep it simple and standalone:

local addonName, addon = ...
_G["RichSnobsAH"] = addon

addon.print = function(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00RichSnobsAH:|r " .. tostring(msg))
end

function addon:OnLoad()
    self.isAHStateOpen = false
    self:InitializeData()
    self:CreateMinimapButton()
    self:CreateMainFrame()
    self:SetupCraftingHook()
    self:SetupFrameHooks()
    
    self.mainFrame:Hide()
    self.print("Loaded! Type /rsah to toggle.")
end

function addon:IsAHOpen()
    -- Check if we've received an AH show event recently without a close event
    if self.isAHStateOpen then 
        return true 
    end

    local open = false
    -- Check frames directly as fallback
    if AuctionFrame and AuctionFrame:IsShown() then open = true end
    -- TSM Support
    if not open and TSM_MainFrame and TSM_MainFrame:IsShown() then open = true end
    
    -- Let's stick to visibility of known frames for now but add more if we find them.
    -- Common AH frames:
    if not open and AuctionFrameTab1 and AuctionFrameTab1:IsVisible() then open = true end
    
    -- Heuristic: if we can send a query, AH is likely open or just closed
    -- but CanSendAuctionQuery() doesn't mean it's open.
    
    -- Check for BrowseName editbox which is often visible if AH is open
    if not open and BrowseName and BrowseName:IsVisible() then open = true end

    return open
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        addon:OnLoad()
        frame:UnregisterEvent("ADDON_LOADED")
    end
end)

SLASH_RICHSNOBSAH1 = "/rsah"
SLASH_RICHSNOBSAH2 = "/richsnobs"
SlashCmdList["RICHSNOBSAH"] = function(msg)
    addon:ToggleMainFrame()
end
