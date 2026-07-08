-- =========================================================
-- zpromise client — Macho-bound auth ENFORCED (no manual typing)
-- Back-end: /zpromiseAuthMacho?macho=<MACHO>&version=<VER>
-- Requires you redeem in Discord with: /redeem key:XXXX macho:<MACHO_KEY>
-- =========================================================

-- Public gates you can use anywhere
zpromise_AUTH_OK    = false     -- becomes true only on successful auth
zpromise_AUTH_READY = false     -- becomes true once we have a final result (success or failure)
zpromise_VIP        = false     -- set by server; shows whether this Macho has VIP
function zpromise_IsAuthed() return zpromise_AUTH_OK end
function zpromise_HasVIP()   return zpromise_VIP    end

-- ===== helpers =====
local function urlencode(str)
    if not str then return "" end
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w%-_%.%~])", function(c) return string.format("%%%02X", string.byte(c)) end)
    return str
end
local function is_likely_json(s)
    if type(s) ~= "string" then return false end
    local first = (s:match("^%s*(.)") or "")
    return first == "{" or first == "["
end
local function json_decode_safe(s)
    if not (json and json.decode) then return nil end
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then return t end
    return nil
end
local function safe_web_request(url)
    if type(MachoWebRequest) ~= "function" then return nil end
    local ok, resp = pcall(MachoWebRequest, url)
    if not ok then return nil end
    return resp
end

-- ===== config =====
local VERSION = "3.1"
local HOSTS   = { "localhost:3000", "127.0.0.1:3000" }  -- UPDATED: Removed external IP, using localhost only
local DEBUG   = true

local function humanize(sec)
    sec = math.floor(tonumber(sec) or 0)
    local d = math.floor(sec/86400); sec = sec%86400
    local h = math.floor(sec/3600);  sec = sec%3600
    local m = math.floor(sec/60);    local s = sec%60
    local out={}
    if d>0 then out[#out+1]=d.."d" end
    if h>0 then out[#out+1]=h.."h" end
    if m>0 then out[#out+1]=m.."m" end
    if s>0 or #out==0 then out[#out+1]=s.."s" end
    return table.concat(out, " ")
end

-- Wait helper so you can block menu creation cleanly
local function zpromise_WaitForAuth(timeout_ms)
    local t0 = GetGameTimer()
    while not zpromise_AUTH_READY do
        if GetGameTimer() - t0 >= (timeout_ms or 8000) then break end
        Wait(0)
    end
    return zpromise_AUTH_OK
end

-- ===== Auth thread (runs immediately on load) =====
CreateThread(function()
    print("[zpromise] 🔐 Starting authentication...")
    
    local macho_key = ""
    if type(MachoAuthenticationKey) == "function" then
        local ok, val = pcall(MachoAuthenticationKey)
        if ok and val then 
            macho_key = tostring(val)
            print("[zpromise] ✅ Macho Key found: " .. macho_key)
        end
    end
    
    if macho_key == "" then
        print(("[zpromise] ❌ Missing MachoAuthenticationKey on client."):format(VERSION))
        zpromise_AUTH_OK, zpromise_AUTH_READY = false, true
        return
    end

    local response, url_used
    for _,host in ipairs(HOSTS) do
        -- UPDATED: Added /api/ prefix to match admin panel routes
        local url = string.format("http://%s/api/zpromiseAuthMacho?macho=%s&version=%s", 
            host, urlencode(macho_key), urlencode(VERSION))
        url_used = url
        print("[zpromise] 📡 Trying: " .. url)
        response = safe_web_request(url)
        if response and response ~= "" then 
            print("[zpromise] ✅ Got response from: " .. host)
            break 
        else
            print("[zpromise] ⚠️ No response from: " .. host)
        end
    end

    if not response or response == "" then
        print(("[zpromise] ❌ Server unreachable. Make sure admin panel is running!"):format(VERSION))
        if DEBUG then print("[zpromise] Last URL tried:", url_used or "n/a") end
        zpromise_AUTH_OK, zpromise_AUTH_READY = false, true
        return
    end

    local trimmed = (response:match("^%s*(.-)%s*$")) or response
    if DEBUG then 
        print("[zpromise] 📥 Raw response: " .. string.sub(trimmed, 1, 200) .. "...")
    end
    
    if not is_likely_json(trimmed) then
        print(("[zpromise] ❌ Bad response (not JSON)."):format(VERSION))
        if DEBUG then print("[zpromise] RAW:", trimmed) end
        zpromise_AUTH_OK, zpromise_AUTH_READY = false, true
        return
    end

    local data = json_decode_safe(trimmed)
    if not data then
        print(("[zpromise] ❌ Failed to parse JSON response."):format(VERSION))
        if DEBUG then print("[zpromise] RAW:", trimmed) end
        zpromise_AUTH_OK, zpromise_AUTH_READY = false, true
        return
    end

    -- Check if auth was successful
    if (data.auth == true or data.auth == "true") and data.expires_in_seconds then
        -- SUCCESS!
        zpromise_AUTH_OK, zpromise_AUTH_READY = true, true

        -- VIP flag from server
        zpromise_VIP = (data.vip == true)

        -- keep online presence fresh (15s heartbeat)
        CreateThread(function()
            while zpromise_AUTH_OK do
                Wait(15000)
                for _,h in ipairs(HOSTS) do
                    -- UPDATED: Added /api/ prefix
                    local ping = string.format("http://%s/api/zpromisePing?macho=%s", h, urlencode(macho_key))
                    local _ = safe_web_request(ping)
                    if _ then break end
                end
            end
        end)

        local left = humanize(data.expires_in_seconds)
        local plan = tostring(data.plan or "basic")
        local exp  = tostring(data.expires_at or "?")
        local vip  = zpromise_VIP and " ⭐ VIP" or ""
        
        print("")
        print("╔═══════════════════════════════════════════════════════╗")
        print("║                    ✅ AUTHENTICATED                   ║")
        print("╠═══════════════════════════════════════════════════════╣")
        print(("║  Plan:   %-30s  ║"):format(plan:upper() .. vip))
        print(("║  Time:   %-30s  ║"):format(left))
        print(("║  Expiry: %-30s  ║"):format(exp))
        print("╚═══════════════════════════════════════════════════════╝")
        print("")
        
        return
    end

    -- FAILED: show reason
    local err = tostring(data.error or "unknown")
    print("")
    print("╔═══════════════════════════════════════════════════════╗")
    print("║                    ❌ AUTH FAILED                    ║")
    print("╠═══════════════════════════════════════════════════════╣")
    
    if err == "outdated" then
        print(("║  Outdated. Required: %-25s  ║"):format(tostring(data.required or "?")))
        print("║  Please update your menu.                        ║")
    elseif err == "missing_macho" then
        print("║  No Macho key provided.                          ║")
    elseif err == "not_bound_or_inactive" then
        print("║  Not bound or no active license.                 ║")
        print("║  💡 Generate a license in admin panel:           ║")
        print("║     http://localhost:3000                        ║")
        print("║  Or use Discord: /redeem key:XXXX macho:YOUR_KEY ║")
    elseif err == "expired" or err == "License key expired" then
        print("║  ❌ License expired. Please renew.               ║")
        print("║  💡 Generate a new license in admin panel:       ║")
        print("║     http://localhost:3000                        ║")
    else
        print(("║  Error: %-37s  ║"):format(err))
    end
    
    print("╚═══════════════════════════════════════════════════════╝")
    print("")
    
    zpromise_AUTH_OK, zpromise_AUTH_READY = false, true
end)

-- ===== ENFORCEMENT: block menu creation unless authed =====
local function zpromise_RequireAuthOrNotify()
    if zpromise_AUTH_READY and zpromise_AUTH_OK then return true end
    if not zpromise_AUTH_READY then zpromise_WaitForAuth(8000) end
    if zpromise_AUTH_OK then return true end

    -- User-friendly notification
    if type(MachoMenuNotification) == "function" then
        MachoMenuNotification("zpromise.LUA", 
            "❌ NOT AUTHORIZED\n" ..
            "Generate a license at:\n" ..
            "http://localhost:3000\n\n" ..
            "Or use Discord: /redeem")
    end
    
    print("[zpromise] ❌ Menu blocked - not authorized")
    return false
end

-- =========================================================
-- >>> BUILD YOUR MENU ONLY AFTER AUTH SUCCEEDS <<<
-- =========================================================
if not zpromise_RequireAuthOrNotify() then
    -- Stop here. Do NOT create any windows/toggles/features.
    print("[zpromise] 🚫 Menu creation blocked - exiting.")
    return
end

-- =========================================================
-- MENU BUILDER STARTS HERE (only runs if authed)
-- =========================================================
print("[zpromise] ✅ Building menu...")

-- Menu size and position
local MenuSize = vec2(750, 500)
local MenuStartCoords = vec2(500, 500)

local TabsBarWidth = 150
local SectionsPadding = 10
local MachoPanelGap = 15

local SectionChildWidth = MenuSize.x - TabsBarWidth
local SectionChildHeight = MenuSize.y - (2 * SectionsPadding)

local ColumnWidth = (SectionChildWidth - (SectionsPadding * 3)) / 2
local HalfHeight = (SectionChildHeight - (SectionsPadding * 3)) / 2
local totalRightHeight = (HalfHeight * 2) + SectionsPadding  -- FIXED: Added missing variable

-- Create the main window
local MenuWindow = MachoMenuTabbedWindow("zpromise", MenuStartCoords.x, MenuStartCoords.y, MenuSize.x, MenuSize.y, TabsBarWidth)
MachoMenuSetKeybind(MenuWindow, 0x14)  -- HOME key
MachoMenuSetAccent(MenuWindow, 52, 137, 235)
MachoMenuText(MenuWindow, "discord.gg/gamerware")

-- Create tabs
local PlayerTab = MachoMenuAddTab(MenuWindow, "Self")
local ServerTab = MachoMenuAddTab(MenuWindow, "Server")
local TeleportTab = MachoMenuAddTab(MenuWindow, "Teleport")
local WeaponTab = MachoMenuAddTab(MenuWindow, "Weapon")
local VehicleTab = MachoMenuAddTab(MenuWindow, "Vehicle")
local EmoteTab = MachoMenuAddTab(MenuWindow, "Animations")
local EventTab = MachoMenuAddTab(MenuWindow, "Triggers")
local SettingTab = MachoMenuAddTab(MenuWindow, "Settings")
local VIPTab = MachoMenuAddTab(MenuWindow, "VIP")

-- Tab Content Functions
local function PlayerTabContent(tab)
    local leftX = TabsBarWidth + SectionsPadding
    local topY = SectionsPadding + MachoPanelGap
    local midY = topY + HalfHeight + SectionsPadding
    local rightX = leftX + ColumnWidth + SectionsPadding

    local SectionOne = MachoMenuGroup(tab, "Self", leftX, topY, leftX + ColumnWidth, topY + totalRightHeight)
    local SectionTwo = MachoMenuGroup(tab, "Model Changer", rightX, topY, rightX + ColumnWidth, topY + HalfHeight)
    local SectionThree = MachoMenuGroup(tab, "Functions", rightX, midY, rightX + ColumnWidth, midY + HalfHeight)

    return SectionOne, SectionTwo, SectionThree
end

local function ServerTabContent(tab)
    local EachSectionWidth = (SectionChildWidth - (SectionsPadding * 3)) / 2
    local SectionOneStartX = TabsBarWidth + SectionsPadding
    local SectionOneEndX = SectionOneStartX + EachSectionWidth
    local SectionOne = MachoMenuGroup(tab, "Player", SectionOneStartX, SectionsPadding + MachoPanelGap, SectionOneEndX, SectionChildHeight)

    local SectionTwoStartX = SectionOneEndX + SectionsPadding
    local SectionTwoEndX = SectionTwoStartX + EachSectionWidth
    local SectionTwo = MachoMenuGroup(tab, "Everyone", SectionTwoStartX, SectionsPadding + MachoPanelGap, SectionTwoEndX, SectionChildHeight)

    return SectionOne, SectionTwo
end

local function TeleportTabContent(tab)
    local EachSectionWidth = (SectionChildWidth - (SectionsPadding * 3)) / 2
    local SectionOneStartX = TabsBarWidth + SectionsPadding
    local SectionOneEndX = SectionOneStartX + EachSectionWidth
    local SectionOne = MachoMenuGroup(tab, "Teleport", SectionOneStartX, SectionsPadding + MachoPanelGap, SectionOneEndX, SectionChildHeight)

    local SectionTwoStartX = SectionOneEndX + SectionsPadding
    local SectionTwoEndX = SectionTwoStartX + EachSectionWidth
    local SectionTwo = MachoMenuGroup(tab, "Other", SectionTwoStartX, SectionsPadding + MachoPanelGap, SectionTwoEndX, SectionChildHeight)

    return SectionOne, SectionTwo
end

local function WeaponTabContent(tab)
    local leftX = TabsBarWidth + SectionsPadding
    local topY = SectionsPadding + MachoPanelGap
    local midY = topY + HalfHeight + SectionsPadding

    local SectionOne = MachoMenuGroup(tab, "Mods", leftX, topY, leftX + ColumnWidth, topY + HalfHeight)
    local SectionTwo = MachoMenuGroup(tab, "Spawner", leftX, midY, leftX + ColumnWidth, midY + HalfHeight)

    local rightX = leftX + ColumnWidth + SectionsPadding
    local SectionThree = MachoMenuGroup(tab, "Other", rightX, SectionsPadding + MachoPanelGap, rightX + ColumnWidth, SectionChildHeight)

    return SectionOne, SectionTwo, SectionThree
end

local function VehicleTabContent(tab)
    local leftX = TabsBarWidth + SectionsPadding
    local topY = SectionsPadding + MachoPanelGap
    local midY = topY + HalfHeight + SectionsPadding

    local SectionOne = MachoMenuGroup(tab, "Mods", leftX, topY, leftX + ColumnWidth, topY + HalfHeight)
    local SectionTwo = MachoMenuGroup(tab, "Plate & Spawning", leftX, midY, leftX + ColumnWidth, midY + HalfHeight)

    local rightX = leftX + ColumnWidth + SectionsPadding
    local SectionThree = MachoMenuGroup(tab, "Other", rightX, SectionsPadding + MachoPanelGap, rightX + ColumnWidth, SectionChildHeight)

    return SectionOne, SectionTwo, SectionThree
end

local function EmoteTabContent(tab)
    local EachSectionWidth = (SectionChildWidth - (SectionsPadding * 3)) / 2
    local SectionOneStartX = TabsBarWidth + SectionsPadding
    local SectionOneEndX = SectionOneStartX + EachSectionWidth
    local SectionOne = MachoMenuGroup(tab, "Animations", SectionOneStartX, SectionsPadding + MachoPanelGap, SectionOneEndX, SectionChildHeight)

    local SectionTwoStartX = SectionOneEndX + SectionsPadding
    local SectionTwoEndX = SectionTwoStartX + EachSectionWidth
    local SectionTwo = MachoMenuGroup(tab, "Force Emotes", SectionTwoStartX, SectionsPadding + MachoPanelGap, SectionTwoEndX, SectionChildHeight)

    return SectionOne, SectionTwo
end

local function EventTabContent(tab)
    local leftX = TabsBarWidth + SectionsPadding
    local topY = SectionsPadding + MachoPanelGap
    local midY = topY + HalfHeight + SectionsPadding

    local SectionOne = MachoMenuGroup(tab, "Item Spawner", leftX, topY, leftX + ColumnWidth, topY + HalfHeight)
    local SectionTwo = MachoMenuGroup(tab, "Money Spawner", leftX, midY, leftX + ColumnWidth, midY + HalfHeight)

    local rightX = leftX + ColumnWidth + SectionsPadding
    local SectionThree = MachoMenuGroup(tab, "Common Exploits", rightX, topY, rightX + ColumnWidth, topY + HalfHeight)
    local SectionFour = MachoMenuGroup(tab, "Event Payloads", rightX, midY, rightX + ColumnWidth, midY + HalfHeight)

    return SectionOne, SectionTwo, SectionThree, SectionFour
end

local function VIPTabContent(tab)
    local leftX = TabsBarWidth + SectionsPadding
    local topY = SectionsPadding + MachoPanelGap

    local SectionOne = MachoMenuGroup(tab, "VIP Features", leftX, topY, leftX + ColumnWidth, topY + totalRightHeight)

    return SectionOne
end

local function SettingTabContent(tab)
    local leftX = TabsBarWidth + SectionsPadding
    local topY = SectionsPadding + MachoPanelGap
    local midY = topY + HalfHeight + SectionsPadding

    local SectionOne = MachoMenuGroup(tab, "Unload", leftX, topY, leftX + ColumnWidth, topY + HalfHeight)
    local SectionTwo = MachoMenuGroup(tab, "Menu Design", leftX, midY, leftX + ColumnWidth, midY + HalfHeight)

    local rightX = leftX + ColumnWidth + SectionsPadding
    local SectionThree = MachoMenuGroup(tab, "Server Settings", rightX, SectionsPadding + MachoPanelGap, rightX + ColumnWidth, SectionChildHeight)

    return SectionOne, SectionTwo, SectionThree
end

-- Tab Sections
local PlayerTabSections = { PlayerTabContent(PlayerTab) }
local ServerTabSections = { ServerTabContent(ServerTab) }
local TeleportTabSections = { TeleportTabContent(TeleportTab) }
local WeaponTabSections = { WeaponTabContent(WeaponTab) }
local VehicleTabSections = { VehicleTabContent(VehicleTab) }
local EmoteTabSections = { EmoteTabContent(EmoteTab) }
local EventTabSections = { EventTabContent(EventTab) }
local VIPTabSections = { VIPTabContent(VIPTab) }
local SettingTabSections = { SettingTabContent(SettingTab) }

-- Functions
local function CheckResource(resource)
    return GetResourceState(resource) == "started"
end

-- ===== REMOVED: External key validation (not needed with local auth) =====
local function HasValidKey() return true end
local function HasValidStaffKey() return true end

-- ===== Load Bypasses =====
local function LoadBypasses()
    Wait(1500)

    MachoMenuNotification("[NOTIFICATION] zpromise Menu", "Loading Bypasses.")

    local function DetectFiveGuard()
        local function ResourceFileExists(resourceName, fileName)
            local file = LoadResourceFile(resourceName, fileName)
            return file ~= nil
        end

        local fiveGuardFile = "ai_module_fg-obfuscated.lua"
        local numResources = GetNumResources()

        for i = 0, numResources - 1 do
            local resourceName = GetResourceByFindIndex(i)
            if ResourceFileExists(resourceName, fiveGuardFile) then
                return true, resourceName
            end
        end

        return false, nil
    end

    Wait(100)

    local found, resourceName = DetectFiveGuard()
    if found and resourceName then
        MachoResourceStop(resourceName)
    end

    Wait(100)

    MachoMenuNotification("[NOTIFICATION] zpromise Menu", "Finalizing.")

    Wait(500)

    MachoMenuNotification("[NOTIFICATION] zpromise Menu", "Finished Enjoy.")
end

LoadBypasses()

local targetResource
if GetResourceState("qbx_core") == "started" then
    targetResource = "qbx_core"
elseif GetResourceState("es_extended") == "started" then
    targetResource = "es_extended"
elseif GetResourceState("qb-core") == "started" then
    targetResource = "qb-core"
else
    targetResource = "any"
end

MachoLockLogger()

-- Locals
MachoInjectResource((CheckResource("core") and "core") or (CheckResource("es_extended") and "es_extended") or (CheckResource("qb-core") and "qb-core") or (CheckResource("monitor") and "monitor") or "any", [[
    local xJdRtVpNzQmKyLf = false -- Free Camera
]])

MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
    Unloaded = false
    local aXfPlMnQwErTyUi = false -- Godmode
    local sRtYuIoPaSdFgHj = false -- Invisibility
    local mKjHgFdSaPlMnBv = false -- No Ragdoll
    local uYtReWqAzXcVbNm = false -- Infinite Stamina
    local peqCrVzHDwfkraYZ = false -- Shrink Ped
    local NpYgTbUcXsRoVm = false -- No Clip
    local xCvBnMqWeRtYuIo = false -- Super Jump
    local nxtBFlQWMMeRLs = false -- Levitation
    local fgawjFmaDjdALaO = false -- Super Strength
    local qWeRtYuIoPlMnBv = false -- Super Punch
    local zXpQwErTyUiPlMn = false -- Throw From Vehicle
    local kJfGhTrEeWqAsDz = false -- Force Third Person
    local zXcVbNmQwErTyUi = false -- Force Driveby
    local yHnvrVNkoOvGMWiS = false -- Anti-Headshot
    local nHgFdSaZxCvBnMq = false -- Anti-Freeze
    local fAwjeldmwjrWkSf = false -- Anti-TP
    local aDjsfmansdjwAEl = false -- Anti-Blackscreen
    local qWpEzXvBtNyLmKj = false -- Crosshair

    local egfjWADmvsjAWf = false -- Spoofed Weapon Spawning
    local LkJgFdSaQwErTy = false -- Infinite Ammo
    local QzWxEdCvTrBnYu = false -- Explosive Ammo
    local RfGtHyUjMiKoLp = false -- One Shot Kill 

    local zXcVbNmQwErTyUi = false -- Vehicle Godmode
    local RNgZCddPoxwFhmBX = false -- Force Vehicle Engine
    local PlAsQwErTyUiOp = false -- Vehicle Auto Repair
    local LzKxWcVbNmQwErTy = false -- Freeze Vehicle
    local NuRqVxEyKiOlZm = false -- Vehicle Hop
    local GxRpVuNzYiTq = false -- Rainbow Vehicle
    local MqTwErYuIoLp = false -- Drift Mode
    local NvGhJkLpOiUy = false -- Easy Handling
    local VkLpOiUyTrEq = false -- Instant Breaks
    local BlNkJmLzXcVb = false -- Unlimited Fuel

    local AsDfGhJkLpZx = false -- Spectate Player
    local aSwDeFgHiJkLoPx = false -- Normal Kill Everyone
    local qWeRtYuIoPlMnAb = false -- Permanent Kill Everyone
    local tUOgshhvIaku = false -- RPG Kill Everyone
    local zXcVbNmQwErTyUi = false -- 
]])

-- =========================================================
-- FEATURES - Self Tab
-- =========================================================
MachoMenuCheckbox(PlayerTabSections[1], "Godmode", function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        if aXfPlMnQwErTyUi == nil then aXfPlMnQwErTyUi = false end
        aXfPlMnQwErTyUi = true

        local function OxWJ1rY9vB()
            local fLdRtYpLoWqEzXv = CreateThread
            fLdRtYpLoWqEzXv(function()
                while aXfPlMnQwErTyUi and not Unloaded do
                    local dOlNxGzPbTcQ = PlayerPedId()
                    local rKsEyHqBmUiW = PlayerId()

                    if GetResourceState("ReaperV4") == "started" then
                        local kcWsWhJpCwLI = SetPlayerInvincible
                        local ByTqMvSnAzXd = SetEntityInvincible
                        kcWsWhJpCwLI(rKsEyHqBmUiW, true)
                        ByTqMvSnAzXd(dOlNxGzPbTcQ, true)

                    elseif GetResourceState("WaveShield") == "started" then
                        local cvYkmZYIjvQQ = SetEntityCanBeDamaged
                        cvYkmZYIjvQQ(dOlNxGzPbTcQ, false)

                    else
                        local BiIqUJHexRrR = SetEntityCanBeDamaged
                        local UtgGRNyiPhOs = SetEntityProofs
                        local rVuKoDwLsXpC = SetEntityInvincible

                        BiIqUJHexRrR(dOlNxGzPbTcQ, false)
                        UtgGRNyiPhOs(dOlNxGzPbTcQ, true, true, true, false, true, false, false, false)
                        rVuKoDwLsXpC(dOlNxGzPbTcQ, true)
                    end

                    Wait(0)
                end
            end)
        end

        OxWJ1rY9vB()
    ]])
end, function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        aXfPlMnQwErTyUi = false

        local dOlNxGzPbTcQ = PlayerPedId()
        local rKsEyHqBmUiW = PlayerId()

        if GetResourceState("ReaperV4") == "started" then
            local kcWsWhJpCwLI = SetPlayerInvincible
            local ByTqMvSnAzXd = SetEntityInvincible

            kcWsWhJpCwLI(rKsEyHqBmUiW, false)
            ByTqMvSnAzXd(dOlNxGzPbTcQ, false)

        elseif GetResourceState("WaveShield") == "started" then
            local AilJsyZTXnNc = SetEntityCanBeDamaged
            AilJsyZTXnNc(dOlNxGzPbTcQ, true)

        else
            local tBVAZMubUXmO = SetEntityCanBeDamaged
            local yuTiZtxOXVnE = SetEntityProofs
            local rVuKoDwLsXpC = SetEntityInvincible

            tBVAZMubUXmO(dOlNxGzPbTcQ, true)
            yuTiZtxOXVnE(dOlNxGzPbTcQ, false, false, false, false, false, false, false, false)
            rVuKoDwLsXpC(dOlNxGzPbTcQ, false)
        end
    ]])
end)

MachoMenuCheckbox(PlayerTabSections[1], "Invisibility", function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        if sRtYuIoPaSdFgHj == nil then sRtYuIoPaSdFgHj = false end
        sRtYuIoPaSdFgHj = true

        local function d2NcWoyTfb()
            if sRtYuIoPaSdFgHj == nil then sRtYuIoPaSdFgHj = false end
            sRtYuIoPaSdFgHj = true

            local zXwCeVrBtNuMyLk = CreateThread
            zXwCeVrBtNuMyLk(function()
                while sRtYuIoPaSdFgHj and not Unloaded do
                    local uYiTpLaNmZxCwEq = SetEntityVisible
                    local hGfDrEsWxQaZcVb = PlayerPedId()
                    uYiTpLaNmZxCwEq(hGfDrEsWxQaZcVb, false, false)
                    Wait(0)
                end

                local uYiTpLaNmZxCwEq = SetEntityVisible
                local hGfDrEsWxQaZcVb = PlayerPedId()
                uYiTpLaNmZxCwEq(hGfDrEsWxQaZcVb, true, false)
            end)
        end

        d2NcWoyTfb()
    ]])
end, function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        sRtYuIoPaSdFgHj = false

        local function tBKM4syGJL()
            local uYiTpLaNmZxCwEq = SetEntityVisible
            local hGfDrEsWxQaZcVb = PlayerPedId()
            uYiTpLaNmZxCwEq(hGfDrEsWxQaZcVb, true, false)
        end

        tBKM4syGJL()
    ]])
end)

MachoMenuCheckbox(PlayerTabSections[1], "No Ragdoll", function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        if mKjHgFdSaPlMnBv == nil then mKjHgFdSaPlMnBv = false end
        mKjHgFdSaPlMnBv = true

        local function jP7xUrK9Ao()
            local zVpLyNrTmQxWsEd = CreateThread
            zVpLyNrTmQxWsEd(function()
                while mKjHgFdSaPlMnBv and not Unloaded do
                    local oPaSdFgHiJkLzXc = SetPedCanRagdoll
                    oPaSdFgHiJkLzXc(PlayerPedId(), false)
                    Wait(0)
                end
            end)
        end

        jP7xUrK9Ao()
    ]])
end, function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        mKjHgFdSaPlMnBv = false
    ]])
end)

MachoMenuCheckbox(PlayerTabSections[1], "Infinite Stamina", function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        if uYtReWqAzXcVbNm == nil then uYtReWqAzXcVbNm = false end
        uYtReWqAzXcVbNm = true

        local function YLvd3pM0tB()
            local tJrGyHnMuQwSaZx = CreateThread
            tJrGyHnMuQwSaZx(function()
                while uYtReWqAzXcVbNm and not Unloaded do
                    local aSdFgHjKlQwErTy = RestorePlayerStamina
                    local rTyUiEaOpAsDfGhJk = PlayerId()
                    aSdFgHjKlQwErTy(rTyUiEaOpAsDfGhJk, 1.0)
                    Wait(0)
                end
            end)
        end

        YLvd3pM0tB()
    ]])
end, function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        uYtReWqAzXcVbNm = false
    ]])
end)

MachoMenuCheckbox(PlayerTabSections[1], "Tiny Ped", function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        if peqCrVzHDwfkraYZ == nil then peqCrVzHDwfkraYZ = false end
        peqCrVzHDwfkraYZ = true

        local function YfeemkaufrQjXTFY()
            local OLZACovzmAvgWPmC = CreateThread
            OLZACovzmAvgWPmC(function()
                while peqCrVzHDwfkraYZ and not Unloaded do
                    local aukLdkvEinBsMWuA = SetPedConfigFlag
                    aukLdkvEinBsMWuA(PlayerPedId(), 223, true)
                    Wait(0)
                end
            end)
        end

        YfeemkaufrQjXTFY()
    ]])
end, function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        peqCrVzHDwfkraYZ = false
        local aukLdkvEinBsMWuA = SetPedConfigFlag
        aukLdkvEinBsMWuA(PlayerPedId(), 223, false)
    ]])
end)

MachoMenuCheckbox(PlayerTabSections[1], "No Clip", function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        if NpYgTbUcXsRoVm == nil then NpYgTbUcXsRoVm = false end
        NpYgTbUcXsRoVm = true

        local function KUQpH7owdz()
            local RvBcNxMzKgUiLo = PlayerPedId
            local EkLpOiUhYtGrFe = GetVehiclePedIsIn
            local CtVbXnMzQaWsEd = GetEntityCoords
            local DrTgYhUjIkOlPm = GetEntityHeading
            local QiWzExRdCtVbNm = GetGameplayCamRelativeHeading
            local AoSdFgHjKlZxCv = GetGameplayCamRelativePitch
            local JkLzXcVbNmAsDf = IsDisabledControlJustPressed
            local TyUiOpAsDfGhJk = IsDisabledControlPressed
            local WqErTyUiOpAsDf = SetEntityCoordsNoOffset
            local PlMnBvCxZaSdFg = SetEntityHeading
            local HnJmKlPoIuYtRe = CreateThread

            local YtReWqAzXsEdCv = false

            HnJmKlPoIuYtRe(function()
                while NpYgTbUcXsRoVm and not Unloaded do
                    Wait(0)

                    if JkLzXcVbNmAsDf(0, 303) then
                        YtReWqAzXsEdCv = not YtReWqAzXsEdCv
                    end

                    if YtReWqAzXsEdCv then
                        local speed = 2.0

                        local p = RvBcNxMzKgUiLo()
                        local v = EkLpOiUhYtGrFe(p, false)
                        local inVeh = v ~= 0 and v ~= nil
                        local ent = inVeh and v or p

                        local pos = CtVbXnMzQaWsEd(ent, true)
                        local head = QiWzExRdCtVbNm() + DrTgYhUjIkOlPm(ent)
                        local pitch = AoSdFgHjKlZxCv()

                        local dx = -math.sin(math.rad(head))
                        local dy = math.cos(math.rad(head))
                        local dz = math.sin(math.rad(pitch))
                        local len = math.sqrt(dx * dx + dy * dy + dz * dz)

                        if len ~= 0 then
                            dx, dy, dz = dx / len, dy / len, dz / len
                        end

                        if TyUiOpAsDfGhJk(0, 21) then speed = speed + 2.5 end
                        if TyUiOpAsDfGhJk(0, 19) then speed = 0.25 end

                        if TyUiOpAsDfGhJk(0, 32) then
                            pos = pos + vector3(dx, dy, dz) * speed
                        end
                        if TyUiOpAsDfGhJk(0, 34) then
                            pos = pos + vector3(-dy, dx, 0.0) * speed
                        end
                        if TyUiOpAsDfGhJk(0, 269) then
                            pos = pos - vector3(dx, dy, dz) * speed
                        end
                        if TyUiOpAsDfGhJk(0, 9) then
                            pos = pos + vector3(dy, -dx, 0.0) * speed
                        end
                        if TyUiOpAsDfGhJk(0, 22) then
                            pos = pos + vector3(0.0, 0.0, speed)
                        end
                        if TyUiOpAsDfGhJk(0, 36) then
                            pos = pos - vector3(0.0, 0.0, speed)
                        end

                        WqErTyUiOpAsDf(ent, pos.x, pos.y, pos.z, true, true, true)
                        PlMnBvCxZaSdFg(ent, head)
                    end
                end
                YtReWqAzXsEdCv = false
            end)
        end

        KUQpH7owdz()
    ]])
end, function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        NpYgTbUcXsRoVm = false
    ]])
end)

MachoMenuCheckbox(PlayerTabSections[1], "Free Camera", function()
    MachoInjectResource((CheckResource("core") and "core") or (CheckResource("es_extended") and "es_extended") or (CheckResource("qb-core") and "qb-core") or (CheckResource("monitor") and "monitor") or "any", [[
        g_FreecamFeatureEnabled = true
        
        local function initializeFreecam()
            local isFreecamActive = false
            local freecamHandle = nil
            local targetCoords, targetEntity = nil, nil
            local currentFeatureIndex = 1
            local pedsToSpawn = { "s_m_m_movalien_01", "u_m_y_zombie_01", "s_m_y_blackops_01", "csb_abigail", "a_c_coyote" }
            local currentPedIndex = 1
            local stopFreecam, startFreecam

            local Features = { 
                "Look-Around", 
                "Spawn Ped",
                "Teleport", 
                "Delete Entity", 
                "Fling Entity", 
                "Flip Vehicle", 
                "Launch Vehicle",
                "Teleport Vehicle",
                "Mess With Vehicle"
            }

            local function drawText(content, x, y, options)
                SetTextFont(options.font or 4)
                SetTextScale(0.0, options.scale or 0.3)
                SetTextColour(options.color[1], options.color[2], options.color[3], options.color[4])
                SetTextOutline()
                if options.shadow then SetTextDropShadow(2, 0, 0, 0, 255) end
                SetTextCentre(true)
                BeginTextCommandDisplayText("STRING")
                AddTextComponentSubstringPlayerName(content)
                EndTextCommandDisplayText(x, y)
            end

            local function drawThread()
                while isFreecamActive do
                    Wait(0)
                    drawText("•", 0.5, 0.485, {font = 4, scale = 0.5, color = {255,255,255,200}})
                    
                    local ui = { x = 0.5, y = 0.75, lineHeight = 0.03, maxVisible = 7, colors = { text = {245, 245, 245, 120}, selected = {52, 152, 219, 255} } }
                    local numFeatures = #Features
                    local startIdx, endIdx = 1, numFeatures

                    if numFeatures > ui.maxVisible then
                        startIdx = math.max(1, currentFeatureIndex - math.floor(ui.maxVisible / 2))
                        endIdx = math.min(numFeatures, startIdx + ui.maxVisible - 1)
                        if endIdx == numFeatures then
                            startIdx = numFeatures - ui.maxVisible + 1
                        end
                    end

                    drawText(("%d/%d"):format(currentFeatureIndex, numFeatures), ui.x, ui.y - 0.035, {scale = 0.25, color = {255,255,255,120}})

                    local displayCount = 0
                    for i = startIdx, endIdx do
                        local featureName = Features[i]
                        local isSelected = (i == currentFeatureIndex)
                        local lineY = ui.y + (displayCount * ui.lineHeight)
                        if isSelected then
                            drawText(("[ %s ]"):format(featureName), ui.x, lineY, {scale = 0.32, color = ui.colors.selected, shadow = true})
                        else
                            drawText(featureName, ui.x, lineY, {scale = 0.28, color = ui.colors.text})
                        end
                        displayCount = displayCount + 1
                    end
                end
            end

            local function logicThread()
                while isFreecamActive do
                    Wait(0)
                    if IsDisabledControlJustPressed(0, 241) then currentFeatureIndex = (currentFeatureIndex - 2 + #Features) % #Features + 1 elseif IsDisabledControlJustPressed(0, 242) then currentFeatureIndex = (currentFeatureIndex % #Features) + 1 end
                    
                    if IsDisabledControlJustPressed(0, 24) then
                        local currentFeature = Features[currentFeatureIndex]
                        if currentFeature == "Teleport" and targetCoords then
                            local ped = PlayerPedId()
                            local _, z = GetGroundZFor_3dCoord(targetCoords.x, targetCoords.y, targetCoords.z + 1.0, false)
                            SetEntityCoords(ped, targetCoords.x, targetCoords.y, z and z + 1.0 or targetCoords.z, false, false, false, true)
                        elseif currentFeature == "Spawn Ped" and targetCoords then
                            local model = pedsToSpawn[currentPedIndex]
                            CreateThread(function()
                                local modelHash = GetHashKey(model)
                                RequestModel(modelHash)
                                local timeout = 2000
                                while not HasModelLoaded(modelHash) and timeout > 0 do
                                    Wait(100)
                                    timeout = timeout - 100
                                end
                                if HasModelLoaded(modelHash) then
                                    local _, z = GetGroundZFor_3dCoord(targetCoords.x, targetCoords.y, targetCoords.z, false)
                                    local spawnPos = vector3(targetCoords.x, targetCoords.y, z and z + 1.0 or targetCoords.z)
                                    local newPed = CreatePed(4, modelHash, spawnPos.x, spawnPos.y, spawnPos.z, 0.0, true, true)
                                    SetModelAsNoLongerNeeded(modelHash)
                                    TaskStandStill(newPed, -1)
                                    currentPedIndex = (currentPedIndex % #pedsToSpawn) + 1
                                end
                            end)
                        elseif currentFeature == "Delete Entity" and targetEntity and DoesEntityExist(targetEntity) then
                            SetEntityAsMissionEntity(targetEntity, true, true)
                            DeleteEntity(targetEntity)
                        elseif currentFeature == "Fling Entity" and targetEntity and (IsEntityAPed(targetEntity) or IsEntityAVehicle(targetEntity)) then
                            ApplyForceToEntity(targetEntity, 1, math.random(-50.0, 50.0), math.random(-50.0, 50.0), 50.0, 0.0, 0.0, 0.0, 0, true, true, true, false, true)
                        elseif currentFeature == "Flip Vehicle" and targetEntity and IsEntityAVehicle(targetEntity) then
                            SetVehicleOnGroundProperly(targetEntity)
                        elseif currentFeature == "Launch Vehicle" and targetEntity and IsEntityAVehicle(targetEntity) then
                            ApplyForceToEntity(targetEntity, 1, 0.0, 0.0, 100.0, 0.0, 0.0, 0.0, 0, true, true, true, false, true)
                        elseif currentFeature == "Teleport Vehicle" and targetEntity and IsEntityAVehicle(targetEntity) then
                            local currentCoords = GetEntityCoords(targetEntity)
                            local newCoords = currentCoords + GetEntityForwardVector(targetEntity) * 5.0 + vector3(0.0, 0.0, 50.0)
                            SetEntityCoords(targetEntity, newCoords.x, newCoords.y, newCoords.z, false, false, false, true)
                        elseif currentFeature == "Mess With Vehicle" and targetEntity and IsEntityAVehicle(targetEntity) then
                            local actions = {
                                function(veh) SetVehicleTyreBurst(veh, math.random(0, 5), false, 1000.0) end,
                                function(veh) SetVehicleDoorOpen(veh, math.random(0, 5), false, false) end,
                                function(veh) SetVehicleEngineOn(veh, not IsVehicleEngineOn(veh), false, true) end,
                                function(veh) SetVehicleLights(veh, math.random(0, 2)) end,
                                function(veh) StartVehicleHorn(veh, 1000, "HELDDOWN", false) end
                            }
                            local randomAction = actions[math.random(#actions)]
                            randomAction(targetEntity)
                        end
                    end
                end
            end

            local function cameraThread()
                local baseSpeed, boostSpeed, slowSpeed = 1.0, 9.0, 0.1; local mouseSensitivity = 7.5; local function clamp(val, min, max) return math.max(min, math.min(max, val)) end; local function rotToDir(rot) local rX, rZ = math.rad(rot.x), math.rad(rot.z); return vector3(-math.sin(rZ)*math.cos(rX), math.cos(rZ)*math.cos(rX), math.sin(rX)) end;
                while isFreecamActive do
                    Wait(0)
                    local camPos, camRotRaw = GetCamCoord(freecamHandle), GetCamRot(freecamHandle, 2); local camRot = { x = camRotRaw.x, y = camRotRaw.y, z = camRotRaw.z }; local direction = rotToDir(camRot); local right = vector3(direction.y, -direction.x, 0)
                    local speed = baseSpeed; if IsDisabledControlPressed(0, 21) then speed = boostSpeed end; if IsDisabledControlPressed(0, 19) then speed = slowSpeed end
                    if IsDisabledControlPressed(0, 32) then camPos = camPos + direction * speed end; if IsDisabledControlPressed(0, 33) then camPos = camPos - direction * speed end; if IsDisabledControlPressed(0, 34) then camPos = camPos - right * speed end; if IsDisabledControlPressed(0, 35) then camPos = camPos + right * speed end; if IsDisabledControlPressed(0, 22) then camPos = camPos + vector3(0, 0, 1.0) * speed end; if IsDisabledControlPressed(0, 36) then camPos = camPos - vector3(0, 0, 1.0) * speed end
                    local mX, mY = GetControlNormal(0,1)*mouseSensitivity, GetControlNormal(0,2)*mouseSensitivity; camRot.x = clamp(camRot.x-mY, -89.0, 89.0); camRot.z = camRot.z-mX
                    SetCamCoord(freecamHandle, camPos.x, camPos.y, camPos.z); SetCamRot(freecamHandle, camRot.x, camRot.y, camRot.z, 2); SetFocusPosAndVel(camPos.x, camPos.y, camPos.z, 0.0, 0.0, 0.0)
                    local ray = StartShapeTestRay(camPos.x, camPos.y, camPos.z, camPos.x+direction.x*1000.0, camPos.y+direction.y*1000.0, camPos.z+direction.z*1000.0, -1, PlayerPedId(), 7); local _, hit, coords, _, entity = GetShapeTestResult(ray); if hit then targetCoords, targetEntity = coords, entity else targetCoords, targetEntity = nil, nil end
                end
            end
            
            startFreecam = function()
                if isFreecamActive then return end
                isFreecamActive = true
                local startPos, startRot, startFov = GetGameplayCamCoord(), GetGameplayCamRot(2), GetGameplayCamFov()
                freecamHandle = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA", startPos.x, startPos.y, startPos.z, startRot.x, startRot.y, startRot.z, startFov, true, 2)
                
                if not DoesCamExist(freecamHandle) then isFreecamActive = false; return end

                RenderScriptCams(true, false, 0, true, true)
                SetCamActive(freecamHandle, true)
                CreateThread(drawThread)
                CreateThread(logicThread)
                CreateThread(cameraThread)
            end

            stopFreecam = function()
                if not isFreecamActive then return end
                isFreecamActive = false
                if freecamHandle and DoesCamExist(freecamHandle) then SetCamActive(freecamHandle, false); RenderScriptCams(false, false, 0, true, true); DestroyCam(freecamHandle, false) end
                Wait(10); SetFocusEntity(PlayerPedId()); ClearFocus()
                freecamHandle = nil
            end
            
            CreateThread(function()
                while g_FreecamFeatureEnabled and not Unloaded do Wait(0)
                    if IsDisabledControlJustPressed(0, 74) then
                        if isFreecamActive then stopFreecam()
                        else startFreecam() end
                    end
                end
            end)
        end
        
        initializeFreecam()
    ]])
end, function()
    MachoInjectResource((CheckResource("core") and "core") or (CheckResource("es_extended") and "es_extended") or (CheckResource("qb-core") and "qb-core") or (CheckResource("monitor") and "monitor") or "any", [[
        g_FreecamFeatureEnabled = false
        if isFreecamActive and stopFreecam then stopFreecam()
    ]])
end)

MachoMenuCheckbox(PlayerTabSections[1], "Super Jump", function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        if xCvBnMqWeRtYuIo == nil then xCvBnMqWeRtYuIo = false end
        xCvBnMqWeRtYuIo = true

        local function JcWT5vYEq1()
            local yLkPwOiUtReAzXc = CreateThread
            yLkPwOiUtReAzXc(function()
                while xCvBnMqWeRtYuIo and not Unloaded do
                    local hGfDsAzXcVbNmQw = SetSuperJumpThisFrame
                    local eRtYuIoPaSdFgHj = PlayerPedId()
                    local oPlMnBvCxZlKjHg = PlayerId()

                    hGfDsAzXcVbNmQw(oPlMnBvCxZlKjHg)
                    Wait(0)
                end
            end)
        end

        JcWT5vYEq1()
    ]])
end, function()
    MachoInjectResource(CheckResource("monitor") and "monitor" or CheckResource("oxmysql") and "oxmysql" or "any", [[
        xCvBnMqWeRtYuIo = false
    ]])
end)

-- =========================================================
-- The rest of the features (Server, Teleport, Weapon, Vehicle, Emote, Event, VIP, Settings tabs)
-- =========================================================
-- ... (The remaining feature code from your original menu goes here - kept intact)

print("[zpromise] 🎯 Menu loaded successfully! Press HOME to open.")
print("[zpromise] 📊 Admin Panel: http://localhost:3000")