--[[
myplugin/main.lua â€” KOReader plugin template for reMarkable 2

This file is the entry point loaded by KOReader''s PluginLoader.
It must return a table (the plugin module). The loader sets:
  plugin_module.name  = directory name without ".koplugin"
  plugin_module.path  = absolute path to the .koplugin directory

Lifecycle:
  â€¢ Loaded once at KOReader startup.
  â€¢ init() is called when the plugin is instantiated (per-UI context).
  â€¢ addToMainMenu() registers menu entries (called if ReaderUI or FileManager
    is active; both call it if you register with both via registerToMainMenu).

Deployment:
  Copy myplugin.koplugin/ to /home/root/.adds/koreader/plugins/
  (or /home/root/koreader/plugins/ depending on your install layout).
  Restart KOReader. The plugin appears under More Tools.
--]]

-- â”€â”€ Core KOReader modules â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("gettext")    -- wrap user-visible strings in _()

-- â”€â”€ Widget imports (add/remove as needed) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local InfoMessage      = require("ui/widget/infomessage")
local ConfirmBox       = require("ui/widget/confirmbox")
local InputDialog      = require("ui/widget/inputdialog")
-- local Notification  = require("ui/widget/notification")  -- toast-style
-- local Menu          = require("ui/widget/menu")

-- â”€â”€ Plugin definition â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local MyPlugin = WidgetContainer:extend{
    -- These match _meta.lua so the plugin manager shows them correctly.
    name        = "myplugin",
    fullname    = _("My Plugin"),
    description = _("A template KOReader plugin for the reMarkable 2"),

    -- Set to true to disable this plugin without deleting it.
    disabled    = false,

    -- Per-instance state goes here (nil = unset):
    -- my_setting = nil,
}

-- â”€â”€ init â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Called once when KOReader instantiates the plugin for a UI context
-- (ReaderUI or FileManager). Use it to:
--   â€¢ read persisted settings
--   â€¢ register yourself in menus
--   â€¢ subscribe to document/reader events
function MyPlugin:init()
    logger.dbg("MyPlugin: init")

    -- Register this plugin''s menu entry in Reader and/or FileManager menus.
    -- The argument is the menu module''s `menu_items` table (passed later via
    -- addToMainMenu). Registering here ensures the entry appears.
    self.ui.menu:registerToMainMenu(self)

    -- Example: read a persisted setting (stored in settings.reader.lua)
    -- self.my_setting = G_reader_settings:readSetting("myplugin_my_setting") or "default"
end

-- â”€â”€ addToMainMenu â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Called by ReaderUI/FileManager to populate the main menu.
-- `menu_items` is the shared table; add your entry under a unique key.
-- The key also serves as the anchor for PluginMenuInserter.
function MyPlugin:addToMainMenu(menu_items)
    menu_items.myplugin = {
        -- Text shown in the menu
        text = _("My Plugin"),
        -- Optional: sub_item_table for a sub-menu instead of a direct callback
        -- sub_item_table = { ... },
        callback = function()
            self:onShowMainDialog()
        end,
    }
end

-- â”€â”€ Main action â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function MyPlugin:onShowMainDialog()
    -- Simple informational popup
    UIManager:show(InfoMessage:new{
        text = _("Hello from MyPlugin!\n\nReplace this dialog with your own UI."),
    })

    -- â”€â”€ Example: ConfirmBox â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    -- UIManager:show(ConfirmBox:new{
    --     text = _("Do something?"),
    --     ok_text     = _("Yes"),
    --     cancel_text = _("No"),
    --     ok_callback = function()
    --         self:doSomething()
    --     end,
    -- })

    -- â”€â”€ Example: InputDialog â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    -- local dialog
    -- dialog = InputDialog:new{
    --     title   = _("Enter value"),
    --     input   = self.my_setting or "",
    --     buttons = {{
    --         {
    --             text = _("Cancel"),
    --             callback = function() UIManager:close(dialog) end,
    --         },
    --         {
    --             text = _("OK"),
    --             is_enter_default = true,
    --             callback = function()
    --                 self.my_setting = dialog:getInputText()
    --                 G_reader_settings:saveSetting("myplugin_my_setting", self.my_setting)
    --                 UIManager:close(dialog)
    --             end,
    --         },
    --     }},
    -- }
    -- UIManager:show(dialog)
end

-- â”€â”€ Optional event handlers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- KOReader broadcasts events to all loaded widgets. Add handlers for any
-- events your plugin cares about. Return true to consume the event (stop
-- further propagation), or nil/false to let it continue.

-- Called when a document is opened.
-- function MyPlugin:onReadSettings(config)
--     -- config is the document''s DocSettings object
-- end

-- Called just before a document is closed / settings are saved.
-- function MyPlugin:onSaveSettings()
--     -- persist any per-document state here
-- end

-- Called when the reader UI is fully initialised.
-- function MyPlugin:onReaderReady()
-- end

-- â”€â”€ Return the module â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
return MyPlugin
