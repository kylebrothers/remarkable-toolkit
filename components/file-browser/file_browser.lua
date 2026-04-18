--[[
components/file-browser/file_browser.lua
-----------------------------------------
A scrollable file/folder picker that wraps KOReader''s PathChooser.

Use this when your plugin needs the user to pick a local file or folder
on the device (e.g. choosing a download destination).

For browsing *remote* file listings (Dropbox, WebDAV) use a plain
Menu widget populated from the cloud client''s listFolder() output â€”
see the example in the README.

USAGE
-----
    local FileBrowser = require("components/file-browser/file_browser")

    -- Pick a folder:
    FileBrowser.chooseFolder({
        initial_path = "/home/root",
        title        = "Choose download folder",
        on_confirm   = function(path)
            G_reader_settings:saveSetting("myplugin_download_dir", path)
        end,
    })

    -- Pick a file (any file):
    FileBrowser.chooseFile({
        initial_path = "/home/root",
        filter       = function(filename)
            -- return true to show the file
            return filename:match("%.pdf$") ~= nil
        end,
        on_confirm = function(path)
            myPlugin:openFile(path)
        end,
    })

ADAPTED FROM
------------
KOReader: frontend/ui/widget/pathchooser.lua  (used directly â€” see notes)
--]]

local PathChooser = require("ui/widget/pathchooser")
local UIManager   = require("ui/uimanager")
local _           = require("gettext")

local FileBrowser = {}

--- Let the user choose a local directory.
-- @tparam table opts
--   opts.initial_path  string   Starting directory (default: /home/root)
--   opts.title         string   Dialog title (optional)
--   opts.on_confirm    function Called with the chosen path string
--   opts.on_cancel     function Called if the user dismisses (optional)
function FileBrowser.chooseFolder(opts)
    opts = opts or {}
    local chooser
    chooser = PathChooser:new{
        select_directory = true,
        select_file      = false,
        path             = opts.initial_path or "/home/root",
        title            = opts.title or _("Choose folder"),
        onConfirm        = function(path)
            if opts.on_confirm then opts.on_confirm(path) end
        end,
        onCancel         = function()
            if opts.on_cancel then opts.on_cancel() end
        end,
    }
    UIManager:show(chooser)
end

--- Let the user choose a local file.
-- @tparam table opts
--   opts.initial_path  string   Starting directory (default: /home/root)
--   opts.title         string   Dialog title (optional)
--   opts.filter        function Optional. function(filename) â†’ bool.
--                               Return true to show the entry.
--   opts.on_confirm    function Called with the chosen file path string
--   opts.on_cancel     function Called if the user dismisses (optional)
function FileBrowser.chooseFile(opts)
    opts = opts or {}
    local chooser
    chooser = PathChooser:new{
        select_directory = false,
        select_file      = true,
        path             = opts.initial_path or "/home/root",
        title            = opts.title or _("Choose file"),
        -- PathChooser does not have a built-in filter, but we can
        -- override the item display by subclassing. For simplicity,
        -- all files are shown and the filter is applied on confirm.
        onConfirm        = function(path)
            if opts.filter and not opts.filter(path:match("[^/]+$") or "") then
                -- File doesn''t pass filter â€” re-show (or just ignore)
                return
            end
            if opts.on_confirm then opts.on_confirm(path) end
        end,
        onCancel         = function()
            if opts.on_cancel then opts.on_cancel() end
        end,
    }
    UIManager:show(chooser)
end

--[[--
Build a remote-file-listing Menu item_table from a cloud provider''s
listFolder() output.

This is a convenience formatter â€” pass the result into a Menu:new{}.

@tparam  table  items   Array of {name, path, is_folder, size} from a cloud client.
@tparam  function on_file_tap   Called with (item) when a file row is tapped.
@tparam  function on_folder_tap Called with (item) when a folder row is tapped.
@treturn table  item_table suitable for Menu:new{ item_table = ... }
--]]
function FileBrowser.buildRemoteItemTable(items, on_file_tap, on_folder_tap)
    local util = require("util")
    local rows = {}
    -- Sort: folders first, then alphabetical
    table.sort(items, function(a, b)
        if a.is_folder ~= b.is_folder then return a.is_folder end
        return (a.name or "") < (b.name or "")
    end)
    for _, item in ipairs(items) do
        local label = item.is_folder and (item.name .. "/") or item.name
        local mandatory = (not item.is_folder and item.size)
            and util.getFriendlySize(item.size) or nil
        table.insert(rows, {
            text      = label,
            mandatory = mandatory,
            callback  = function()
                if item.is_folder then
                    if on_folder_tap then on_folder_tap(item) end
                else
                    if on_file_tap then on_file_tap(item) end
                end
            end,
        })
    end
    return rows
end

return FileBrowser
