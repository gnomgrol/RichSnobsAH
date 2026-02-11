local addonName, addon = ...

-- Helper: Format money (copper to gold/silver/copper)
function addon:FormatMoney(copper, hideCopperIfGold)
    if not copper or copper == 0 then return "0c" end
    local isNegative = copper < 0
    copper = math.abs(copper)
    
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local copperRem = math.floor(copper % 100)
    
    local str = isNegative and "- " or ""
    if gold > 0 then
        str = str .. "|cffffd700" .. gold .. "g|r "
    end
    
    if gold > 0 or silver > 0 or (not hideCopperIfGold) then
        str = str .. "|cffc7c7cf" .. string.format("%02d", silver) .. "s|r "
    end
    
    -- New logic: Skip copper if hideCopperIfGold is true and we have gold
    if not (hideCopperIfGold and gold > 0) then
        if gold > 0 or silver > 0 or copperRem > 0 or (not hideCopperIfGold) then
            str = str .. "|cffeda55f" .. string.format("%02d", copperRem) .. "c|r"
        end
    end
    
    -- Trim trailing space if any
    str = str:gsub("%s+$", "")
    
    return str
end

function addon:UpdateStatusText(text)
    if self.ahResultsPane and self.ahResultsPane.statusText then
        self.ahResultsPane.statusText:SetText(text or "")
        if text and text ~= "" then
            -- Only print to chat if it's an error or important milestone or instruction
            if text:find("Failed") or text:find("timed out") or text:find("confirmed") or text:find("Click Buy again") then
                addon.print(text)
            end
        end
    end
end
