--[[
components/dropbox/dropbox.lua
------------------------------
Self-contained Dropbox v2 API client for KOReader plugins.

Handles OAuth2 token refresh, folder listing, file download, and upload.
Requires a Dropbox app with "offline" access (refresh token flow).

SETUP
-----
1. Create a Dropbox app at https://www.dropbox.com/developers/apps
   â€¢ Access type: "Full Dropbox" or "App folder"
   â€¢ Note your App key and App secret
2. Generate a refresh token (one-time, outside the device â€” see README).
3. Store credentials in plugin settings:
       G_reader_settings:saveSetting("myplugin_dropbox", {
           app_key    = "your_app_key",
           app_secret = "your_app_secret",
           refresh_token = "your_refresh_token",
       })

USAGE
-----
    local Dropbox = require("components/dropbox/dropbox")
    local WiFi    = require("components/wifi/wifi")

    WiFi:whenOnline(function()
        local db = Dropbox:new{
            app_key       = "...",
            app_secret    = "...",
            refresh_token = "...",
        }

        -- List a folder (returns array of {name, path, is_folder, size} or nil)
        local items = db:listFolder("/Papers")

        -- Download a file with progress
        local ok = db:downloadFile("/Papers/notes.pdf", "/tmp/notes.pdf",
            function(bytes) logger.dbg("downloaded", bytes) end)

        -- Upload a file
        local ok = db:uploadFile("/tmp/notes.pdf", "/Papers/notes.pdf")
    end)

ADAPTED FROM
------------
KOReader: plugins/cloudstorage.koplugin/providers/dropbox.lua
--]]

local Http   = require("components/http/http")
local logger = require("logger")
local ltn12  = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local http   = require("socket.http")
local JSON   = require("json")
local sha2   = require("ffi/sha2")
local _      = require("gettext")

-- â”€â”€ API endpoint constants â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local TOKEN_URL       = "https://api.dropbox.com/oauth2/token"
local LIST_FOLDER     = "https://api.dropboxapi.com/2/files/list_folder"
local LIST_FOLDER_CONT= "https://api.dropboxapi.com/2/files/list_folder/continue"
local DOWNLOAD_URL    = "https://content.dropboxapi.com/2/files/download"
local UPLOAD_URL      = "https://content.dropboxapi.com/2/files/upload"
local DELETE_URL      = "https://api.dropboxapi.com/2/files/delete"
local CREATE_FOLDER   = "https://api.dropboxapi.com/2/files/create_folder_v2"

-- â”€â”€ Dropbox client â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
local Dropbox = {}
Dropbox.__index = Dropbox

--- Create a new Dropbox client instance.
-- @tparam table opts  Must contain: app_key, app_secret, refresh_token
function Dropbox:new(opts)
    assert(opts.app_key and opts.app_secret and opts.refresh_token,
        "Dropbox:new requires app_key, app_secret, refresh_token")
    local o = setmetatable({}, self)
    o.app_key       = opts.app_key
    o.app_secret    = opts.app_secret
    o.refresh_token = opts.refresh_token
    o._access_token = nil  -- cached; refreshed on first use or on 401
    return o
end

-- â”€â”€ Internal: token management â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

function Dropbox:_refreshToken()
    local credentials = self.app_key .. ":" .. self.app_secret
    local data = "grant_type=refresh_token&refresh_token=" .. self.refresh_token
    local sink = {}
    socketutil:set_timeout()
    local code = socket.skip(1, http.request{
        url    = TOKEN_URL,
        method = "POST",
        headers = {
            ["Authorization"]  = "Basic " .. sha2.bin_to_base64(credentials),
            ["Content-Type"]   = "application/x-www-form-urlencoded",
            ["Content-Length"] = #data,
        },
        source = ltn12.source.string(data),
        sink   = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local ok, result = Http.parseJSON(table.concat(sink))
    if ok and result and result.access_token then
        self._access_token = result.access_token
        return true
    end
    logger.warn("Dropbox: token refresh failed, code:", code)
    return false
end

function Dropbox:_token()
    if not self._access_token then
        self:_refreshToken()
    end
    return self._access_token
end

function Dropbox:_authHeader()
    return { ["Authorization"] = "Bearer " .. (self:_token() or "") }
end

-- â”€â”€ Public API â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

--- List the contents of a Dropbox folder.
-- @tparam  string path  Dropbox path, e.g. "/Papers" or "" for root.
-- @treturn table|nil    Array of {name, path, is_folder, size, modified} or nil on error.
function Dropbox:listFolder(path)
    if path == "/" then path = "" end
    local payload = {
        path                                = path,
        recursive                           = false,
        include_media_info                  = false,
        include_deleted                     = false,
        include_has_explicit_shared_members = false,
    }
    local headers = self:_authHeader()
    headers["Content-Type"] = "application/json"
    local body, code = Http.postJSON(LIST_FOLDER, payload, headers)
    if code ~= 200 then return nil end

    local ok, result = Http.parseJSON(body)
    if not ok then return nil end

    -- Handle pagination
    while result.has_more do
        local cont_headers = self:_authHeader()
        cont_headers["Content-Type"] = "application/json"
        local cont_body, cont_code = Http.postJSON(LIST_FOLDER_CONT,
            { cursor = result.cursor }, cont_headers)
        if cont_code ~= 200 then break end
        local cont_ok, cont_result = Http.parseJSON(cont_body)
        if not cont_ok then break end
        for _, entry in ipairs(cont_result.entries or {}) do
            table.insert(result.entries, entry)
        end
        result.has_more = cont_result.has_more
        result.cursor   = cont_result.cursor
    end

    local items = {}
    for _, entry in ipairs(result.entries or {}) do
        table.insert(items, {
            name      = entry.name,
            path      = entry.path_display,
            is_folder = (entry[".tag"] == "folder"),
            size      = entry.size,
            modified  = entry.server_modified,
        })
    end
    return items
end

--- Download a file from Dropbox.
-- @tparam  string   dropbox_path   Remote path, e.g. "/Papers/notes.pdf"
-- @tparam  string   local_path     Destination on the device, e.g. "/tmp/notes.pdf"
-- @tparam  function progress_cb    Optional. Called with (bytes_received).
-- @treturn boolean  true on success
function Dropbox:downloadFile(dropbox_path, local_path, progress_cb)
    local headers = self:_authHeader()
    headers["Dropbox-API-Arg"] = ''{"path":"'' .. dropbox_path .. ''"}''
    local code = Http.download(DOWNLOAD_URL, local_path, headers, progress_cb)
    return code == 200
end

--- Upload a local file to Dropbox.
-- @tparam  string local_path     Source on the device, e.g. "/tmp/notes.pdf"
-- @tparam  string dropbox_path   Destination path, e.g. "/Papers/notes.pdf"
-- @tparam  boolean overwrite     If true, replace existing file. Default: false (auto-rename).
-- @treturn boolean  true on success
function Dropbox:uploadFile(local_path, dropbox_path, overwrite)
    local lfs = require("libs/libkoreader-lfs")
    local ffiUtil = require("ffi/util")
    local file_size = lfs.attributes(local_path, "size")
    if not file_size then
        logger.warn("Dropbox:uploadFile: file not found:", local_path)
        return false
    end

    local api_arg = string.format(
        ''{"path":"%s","mode":"%s","autorename":%s,"mute":false}'',
        dropbox_path,
        overwrite and "overwrite" or "add",
        overwrite and "false" or "true"
    )

    local headers = self:_authHeader()
    headers["Dropbox-API-Arg"] = api_arg
    headers["Content-Type"]    = "application/octet-stream"
    headers["Content-Length"]  = file_size

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url    = UPLOAD_URL,
        method = "POST",
        headers = headers,
        source  = ltn12.source.file(io.open(local_path, "r")),
        sink    = ltn12.sink.table({}),
    })
    socketutil:reset_timeout()

    if type(code) ~= "number" or code ~= 200 then
        logger.warn("Dropbox:uploadFile: failed, code:", code)
        return false
    end
    return true
end

--- Delete a file or folder at the given Dropbox path.
-- @tparam  string dropbox_path
-- @treturn boolean  true on success
function Dropbox:delete(dropbox_path)
    local headers = self:_authHeader()
    headers["Content-Type"] = "application/json"
    local _, code = Http.postJSON(DELETE_URL, { path = dropbox_path }, headers)
    return type(code) == "number" and code >= 200 and code < 300
end

--- Create a folder at the given Dropbox path.
-- @tparam  string dropbox_path  e.g. "/Papers/NewFolder"
-- @treturn boolean  true on success
function Dropbox:createFolder(dropbox_path)
    local headers = self:_authHeader()
    headers["Content-Type"] = "application/json"
    local _, code = Http.postJSON(CREATE_FOLDER, { path = dropbox_path, autorename = false }, headers)
    return type(code) == "number" and code >= 200 and code < 300
end

-- â”€â”€ Settings helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

--- Build a Dropbox instance from plugin settings.
-- Reads the key `<prefix>_dropbox` from G_reader_settings.
-- Returns nil if credentials are not configured.
-- @tparam string settings_key  e.g. "myplugin_dropbox"
function Dropbox.fromSettings(settings_key)
    local creds = G_reader_settings:readSetting(settings_key)
    if not creds or not creds.refresh_token then return nil end
    return Dropbox:new(creds)
end

--- Save Dropbox credentials to G_reader_settings.
-- @tparam string settings_key
-- @tparam table  creds  { app_key, app_secret, refresh_token }
function Dropbox.saveSettings(settings_key, creds)
    G_reader_settings:saveSetting(settings_key, creds)
end

return Dropbox
