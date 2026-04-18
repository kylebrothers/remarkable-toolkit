--[[
components/credentials/credentials.lua
---------------------------------------
Convenience wrapper around KOReader''s MultiInputDialog for collecting
multi-field credentials (e.g. Dropbox app_key + app_secret + refresh_token,
or WebDAV address + username + password).

MultiInputDialog is KOReader''s purpose-built widget for this exact pattern:
multiple labelled text fields with a virtual keyboard, shown in one dialog.

USAGE
-----
    local Credentials = require("components/credentials/credentials")

    -- Dropbox credentials:
    Credentials.showDropbox({
        -- current values (nil shows empty field)
        app_key       = G_reader_settings:readSetting("myplugin_db_key"),
        app_secret    = G_reader_settings:readSetting("myplugin_db_secret"),
        refresh_token = G_reader_settings:readSetting("myplugin_db_token"),
        on_save = function(values)
            G_reader_settings:saveSetting("myplugin_db_key",    values.app_key)
            G_reader_settings:saveSetting("myplugin_db_secret", values.app_secret)
            G_reader_settings:saveSetting("myplugin_db_token",  values.refresh_token)
        end,
    })

    -- WebDAV credentials:
    Credentials.showWebDAV({
        address  = G_reader_settings:readSetting("myplugin_dav_address"),
        username = G_reader_settings:readSetting("myplugin_dav_user"),
        password = G_reader_settings:readSetting("myplugin_dav_pass"),
        on_save  = function(values)
            G_reader_settings:saveSetting("myplugin_dav_address",  values.address)
            G_reader_settings:saveSetting("myplugin_dav_user",     values.username)
            G_reader_settings:saveSetting("myplugin_dav_pass",     values.password)
        end,
    })

    -- Generic multi-field dialog (build your own field list):
    Credentials.show({
        title  = "My Service",
        fields = {
            { label = "Email",    key = "email",    hint = "user@example.com" },
            { label = "Password", key = "password", hint = "",  password = true },
            { label = "Server",   key = "server",   hint = "https://â€¦" },
        },
        values   = { email = "...", password = "...", server = "..." },
        on_save  = function(values) ... end,
        on_cancel = function() end,  -- optional
    })

ADAPTED FROM
------------
KOReader: frontend/ui/widget/multiinputdialog.lua
--]]

local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager        = require("ui/uimanager")
local _                = require("gettext")

local Credentials = {}

-- â”€â”€ Generic multi-field dialog â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

--- Show a multi-field credential dialog.
-- @tparam table opts
--   opts.title    string   Dialog title
--   opts.fields   table    Array of {label, key, hint, password (bool), input_type}
--   opts.values   table    Current values, keyed by field.key
--   opts.on_save  function Called with a table {key = value, ...} on OK
--   opts.on_cancel function Called on Cancel (optional)
function Credentials.show(opts)
    opts = opts or {}
    local fields_spec = opts.fields or {}
    local current     = opts.values or {}

    -- Build MultiInputDialog fields array
    local mfields = {}
    for _, f in ipairs(fields_spec) do
        table.insert(mfields, {
            description = f.label,
            text        = current[f.key] or "",
            hint        = f.hint or "",
            input_type  = f.input_type or (f.password and "password" or nil),
            text_type   = f.password and "password" or nil,
        })
    end

    local dlg
    dlg = MultiInputDialog:new{
        title  = opts.title or _("Credentials"),
        fields = mfields,
        buttons = {{
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function()
                    UIManager:close(dlg)
                    if opts.on_cancel then opts.on_cancel() end
                end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local entered = dlg:getFields()
                    local result  = {}
                    for i, f in ipairs(fields_spec) do
                        result[f.key] = entered[i] or ""
                    end
                    UIManager:close(dlg)
                    if opts.on_save then opts.on_save(result) end
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- â”€â”€ Presets for common services â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

--- Show a Dropbox credential dialog.
-- Collects: app_key, app_secret, refresh_token.
-- @tparam table opts  Keys: app_key, app_secret, refresh_token, on_save, on_cancel
function Credentials.showDropbox(opts)
    opts = opts or {}
    Credentials.show({
        title  = _("Dropbox credentials"),
        fields = {
            {
                label = _("App key"),
                key   = "app_key",
                hint  = _("From Dropbox developer console"),
            },
            {
                label    = _("App secret"),
                key      = "app_secret",
                hint     = _("From Dropbox developer console"),
                password = true,
            },
            {
                label    = _("Refresh token"),
                key      = "refresh_token",
                hint     = _("Generated offline â€” see README"),
                password = true,
            },
        },
        values   = {
            app_key       = opts.app_key,
            app_secret    = opts.app_secret,
            refresh_token = opts.refresh_token,
        },
        on_save   = opts.on_save,
        on_cancel = opts.on_cancel,
    })
end

--- Show a WebDAV credential dialog.
-- Collects: address, username, password.
-- @tparam table opts  Keys: address, username, password, on_save, on_cancel
function Credentials.showWebDAV(opts)
    opts = opts or {}
    Credentials.show({
        title  = _("WebDAV server"),
        fields = {
            {
                label = _("Server address"),
                key   = "address",
                hint  = "https://nextcloud.example.com/remote.php/dav/files/alice",
            },
            {
                label = _("Username"),
                key   = "username",
                hint  = _("Your login name"),
            },
            {
                label    = _("Password"),
                key      = "password",
                hint     = "",
                password = true,
            },
        },
        values   = {
            address  = opts.address,
            username = opts.username,
            password = opts.password,
        },
        on_save   = opts.on_save,
        on_cancel = opts.on_cancel,
    })
end

return Credentials
