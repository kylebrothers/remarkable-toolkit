--[[
components/settings-screen/settings_screen.lua
-----------------------------------------------
A generic settings screen built on KOReader''s Menu widget.

Each row can be:
  â€¢ "heading"  â€” section label (non-interactive)
  â€¢ "toggle"   â€” boolean, shows a checkmark (âœ“ / â–¡)
  â€¢ "input"    â€” string/password text field (opens InputDialog)
  â€¢ "number"   â€” integer input with +/- spinner (opens SpinWidget)
  â€¢ "select"   â€” pick one from a list (opens RadioButtonWidget)
  â€¢ "action"   â€” plain button that calls a callback

For credential screens (multiple fields at once) use MultiInputDialog directly
rather than multiple "input" rows â€” see the Dropbox component for an example.

ITEM FIELDS
-----------
  All items:
    type      string   One of the types above
    label     string   Display text

  "heading": no other fields needed.

  "toggle":
    key       string   G_reader_settings key
    default   bool     Default value if key is unset

  "input":
    key       string   G_reader_settings key
    hint      string   Placeholder text in the InputDialog
    default   string   Default value if key is unset
    password  bool     Mask the value with bullets
    on_change function Called with new value after save (optional)

  "number":
    key       string   G_reader_settings key
    default   number   Default value
    min       number   Minimum allowed value
    max       number   Maximum allowed value
    step      number   Increment (default 1)
    unit      string   Unit suffix shown in spinner (e.g. "s", "px")
    on_change function Called with new value after save (optional)

  "select":
    key       string   G_reader_settings key
    options   table    Array of strings to pick from
    default   string   Default value
    on_change function Called with new value after save (optional)

  "action":
    callback  function Called when the row is tapped

USAGE
-----
    local SettingsScreen = require("components/settings-screen/settings_screen")

    UIManager:show(SettingsScreen:new{
        title = "My Plugin Settings",
        items = {
            { type = "heading", label = "Account" },
            { type = "input",   label = "Server URL", key = "myplugin_url",
              hint = "https://example.com", default = "" },
            { type = "input",   label = "Password",   key = "myplugin_pw",
              password = true, default = "" },
            { type = "toggle",  label = "Auto-sync",  key = "myplugin_autosync",
              default = false },
            { type = "number",  label = "Timeout (s)", key = "myplugin_timeout",
              default = 30, min = 5, max = 300, step = 5, unit = "s" },
            { type = "select",  label = "Folder",     key = "myplugin_folder",
              options = {"/Documents", "/Papers", "/Books"}, default = "/Documents" },
            { type = "action",  label = "Test connection",
              callback = function() end },
        },
        on_close = function() end,
    })
--]]

local Device          = require("device")
local InputDialog     = require("ui/widget/inputdialog")
local Menu            = require("ui/widget/menu")
local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
local SpinWidget      = require("ui/widget/spinwidget")
local UIManager       = require("ui/uimanager")
local Screen          = Device.screen
local _               = require("gettext")

local SettingsScreen = Menu:extend{
    title         = _("Settings"),
    items         = nil,
    on_close      = nil,
    is_popout     = false,
    is_borderless = true,
    width         = Screen:getWidth(),
    height        = Screen:getHeight(),
}

function SettingsScreen:init()
    self.item_table = self:_buildItemTable()
    Menu.init(self)
end

function SettingsScreen:_buildItemTable()
    local rows = {}
    for _, item in ipairs(self.items or {}) do
        local t = item.type

        if t == "heading" then
            table.insert(rows, {
                text     = "â”€â”€ " .. (item.label or item.text or "") .. " â”€â”€",
                bold     = true,
                callback = function() end,
            })

        elseif t == "toggle" then
            table.insert(rows, {
                text         = item.label,
                checked_func = function()
                    local v = G_reader_settings:readSetting(item.key)
                    return (v == nil) and (item.default == true) or (v == true)
                end,
                callback = function()
                    local v = G_reader_settings:readSetting(item.key)
                    if v == nil then v = item.default end
                    G_reader_settings:saveSetting(item.key, not v)
                    self:updateItems()
                    if item.on_change then item.on_change(not v) end
                end,
            })

        elseif t == "input" then
            table.insert(rows, {
                text_func = function()
                    local v = G_reader_settings:readSetting(item.key) or item.default or ""
                    if item.password and v ~= "" then
                        return item.label .. ": " .. string.rep("â€¢", math.min(#v, 8))
                    end
                    return item.label .. (v ~= "" and (": " .. v) or "")
                end,
                callback = function() self:_showInputDialog(item) end,
            })

        elseif t == "number" then
            table.insert(rows, {
                text_func = function()
                    local v = G_reader_settings:readSetting(item.key) or item.default or 0
                    return item.label .. ": " .. tostring(v) .. (item.unit and (" " .. item.unit) or "")
                end,
                callback = function() self:_showSpinWidget(item) end,
            })

        elseif t == "select" then
            table.insert(rows, {
                text_func = function()
                    local v = G_reader_settings:readSetting(item.key) or item.default or ""
                    return item.label .. (v ~= "" and (": " .. v) or "")
                end,
                callback = function() self:_showRadioSelect(item) end,
            })

        elseif t == "action" then
            table.insert(rows, {
                text     = item.label,
                callback = item.callback,
            })
        end
    end
    return rows
end

-- â”€â”€ Dialog helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

function SettingsScreen:_showInputDialog(item)
    local current = G_reader_settings:readSetting(item.key) or item.default or ""
    local dlg
    dlg = InputDialog:new{
        title      = item.label,
        input      = current,
        input_hint = item.hint or "",
        text_type  = item.password and "password" or nil,
        buttons    = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local val = dlg:getInputText()
                    G_reader_settings:saveSetting(item.key, val)
                    UIManager:close(dlg)
                    self:updateItems()
                    if item.on_change then item.on_change(val) end
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

function SettingsScreen:_showSpinWidget(item)
    local current = G_reader_settings:readSetting(item.key) or item.default or 0
    local spin
    spin = SpinWidget:new{
        title_text    = item.label,
        value         = current,
        value_min     = item.min or 0,
        value_max     = item.max or 100,
        value_step    = item.step or 1,
        unit          = item.unit,
        default_value = item.default or 0,
        callback      = function(s)
            G_reader_settings:saveSetting(item.key, s.value)
            self:updateItems()
            if item.on_change then item.on_change(s.value) end
        end,
    }
    UIManager:show(spin)
end

function SettingsScreen:_showRadioSelect(item)
    local current = G_reader_settings:readSetting(item.key) or item.default
    -- Build radio_buttons array expected by RadioButtonWidget
    local radio_buttons = {}
    for _, option in ipairs(item.options or {}) do
        table.insert(radio_buttons, {{
            text     = option,
            checked  = (option == current),
            provider = option,
        }})
    end
    local dlg
    dlg = RadioButtonWidget:new{
        title_text   = item.label,
        radio_buttons = radio_buttons,
        callback     = function(radio)
            local val = radio.provider
            G_reader_settings:saveSetting(item.key, val)
            self:updateItems()
            if item.on_change then item.on_change(val) end
        end,
    }
    UIManager:show(dlg)
end

-- â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

function SettingsScreen:onClose()
    if self.on_close then self.on_close() end
    UIManager:close(self)
    return true
end

function SettingsScreen:onReturn()
    return self:onClose()
end

return SettingsScreen
