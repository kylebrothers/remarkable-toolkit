--[[
components/wifi/wifi.lua
------------------------
Convenience wrapper around KOReader''s NetworkMgr.

Provides three things a plugin typically needs:
  1. A guard: run a function only when connected, prompting the user if not.
  2. Status queries: isOn(), isConnected().
  3. A ready-made menu item table for a Wi-Fi toggle entry.

USAGE
-----
    local WiFi = require("components/wifi/wifi")

    -- Run code only when online (prompts user to enable Wi-Fi if needed):
    WiFi:whenOnline(function()
        -- safe to make HTTP requests here
        myApi:fetchData()
    end)

    -- Check status programmatically:
    if WiFi:isConnected() then ... end

    -- Add a toggle to your menu:
    function MyPlugin:addToMainMenu(menu_items)
        menu_items.myplugin_wifi = WiFi:getMenuEntry()
        menu_items.myplugin    = { text = "My Plugin", ... }
    end

ADAPTED FROM
------------
KOReader: frontend/ui/network/manager.lua  (NetworkMgr)
          frontend/ui/network/networklistener.lua
--]]

local NetworkMgr = require("ui/network/manager")
local Device     = require("device")
local _          = require("gettext")

local WiFi = {}

--- Returns true if the Wi-Fi radio is on (does not guarantee internet).
function WiFi:isOn()
    return NetworkMgr:isWifiOn()
end

--- Returns true if we have an IP address and a local gateway.
function WiFi:isConnected()
    return NetworkMgr:isConnected()
end

--- Returns true if we appear to have WAN (internet) access.
function WiFi:isOnline()
    return NetworkMgr:isOnline()
end

--[[--
Run `callback` when a network connection is available.

If Wi-Fi is already connected, callback is called immediately.
If not, the user is prompted according to their KOReader Wi-Fi action setting
(prompt / auto-on / ignore).  The callback is called after a successful
connection; it is dropped if the user declines or connection fails.

@tparam function callback  Zero-argument function to call when online.
--]]
function WiFi:whenOnline(callback)
    NetworkMgr:runWhenOnline(callback)
end

--[[--
Lower-level variant: ensure Wi-Fi is on, then call callback.
Does NOT guarantee internet (WAN) â€” only a local connection.
Prefer whenOnline() for anything that makes outbound HTTP requests.
--]]
function WiFi:whenConnected(callback)
    NetworkMgr:runWhenConnected(callback)
end

--- Returns a menu item table suitable for inclusion in addToMainMenu.
-- Shows a checkmark when Wi-Fi is on; tapping toggles it.
-- Hold to force the network-selection dialog (on supported firmware).
function WiFi:getMenuEntry()
    if not Device:hasWifiToggle() then return nil end
    return NetworkMgr:getWifiToggleMenuTable()
end

return WiFi
