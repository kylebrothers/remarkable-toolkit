--[[
components/webdav/webdav.lua
----------------------------
Self-contained WebDAV client for KOReader plugins.

WebDAV works with: Nextcloud, ownCloud, Synology NAS, Apache/Nginx with mod_dav,
and on-premise SharePoint (pre-2016 / some Office 365 on-prem configs).

NOTE on SharePoint Online (Microsoft 365 cloud):
  Microsoft has largely deprecated WebDAV access to SharePoint Online.
  If you need SharePoint Online, you require the Microsoft Graph API with
  OAuth2. See components/sharepoint/README.md for guidance on that path.

USAGE
-----
    local WebDAV = require("components/webdav/webdav")
    local WiFi   = require("components/wifi/wifi")

    WiFi:whenOnline(function()
        local dav = WebDAV:new{
            address  = "https://nextcloud.example.com/remote.php/dav/files/alice",
            username = "alice",
            password = "secret",
        }

        local items = dav:listFolder("/Documents")
        for _, item in ipairs(items or {}) do
            print(item.name, item.is_folder, item.size)
        end

        local ok = dav:downloadFile("/Documents/notes.pdf", "/tmp/notes.pdf")
        local ok = dav:uploadFile("/tmp/notes.pdf", "/Documents/notes.pdf")
    end)

ADAPTED FROM
------------
KOReader: plugins/cloudstorage.koplugin/providers/webdav.lua
--]]

local Http       = require("components/http/http")
local http       = require("socket.http")
local lfs        = require("libs/libkoreader-lfs")
local logger     = require("logger")
local ltn12      = require("ltn12")
local socket     = require("socket")
local socketutil = require("socketutil")
local util       = require("util")

local WebDAV = {}
WebDAV.__index = WebDAV

--- Create a new WebDAV client instance.
-- @tparam table opts  Must contain: address (server base URL), username, password.
--   address should include any base path, e.g.
--   "https://dav.example.com/remote.php/dav/files/alice"
function WebDAV:new(opts)
    assert(opts.address and opts.username and opts.password,
        "WebDAV:new requires address, username, password")
    local o = setmetatable({}, self)
    o.address  = opts.address:gsub("/$", "")  -- strip trailing slash
    o.username = opts.username
    o.password = opts.password
    return o
end

-- â”€â”€ Internal helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

--- Encode a path component (preserves slashes).
local function encodePath(path)
    -- util.urlEncode with "/" preserved
    return util.urlEncode(path, "/")
end

--- Build the full URL for a given remote path.
function WebDAV:_url(path)
    path = path or "/"
    if path:sub(1,1) ~= "/" then path = "/" .. path end
    return self.address .. encodePath(path)
end

--- Perform an authenticated WebDAV PROPFIND (directory listing).
-- depth: "0" = this resource, "1" = immediate children (default)
function WebDAV:_propfind(url, depth)
    depth = depth or "1"
    local body = ''<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>''
        .. ''<d:getlastmodified/><d:getcontentlength/><d:resourcetype/>''
        .. ''<d:displayname/></d:prop></d:propfind>''
    local sink = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url    = url,
        method = "PROPFIND",
        headers = {
            ["Authorization"]  = "Basic " ..
                require("ffi/sha2").bin_to_base64(self.username .. ":" .. self.password),
            ["Depth"]          = depth,
            ["Content-Type"]   = "application/xml",
            ["Content-Length"] = #body,
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" or (code ~= 207 and code ~= 200) then
        logger.warn("WebDAV PROPFIND failed, code:", code, "url:", url)
        return nil
    end
    return table.concat(sink)
end

--- Parse a PROPFIND XML response into a list of items.
-- Very simple regex-based parser; covers standard WebDAV servers.
local function parsePROPFIND(xml, base_url_path)
    local items = {}
    for response in xml:gmatch("<[Dd]:response>(.-)</[Dd]:response>") do
        local href  = response:match("<[Dd]:href>(.-)</[Dd]:href>") or ""
        local name  = href:match("([^/]+)/*$") or ""
        -- URL-decode the name
        name = name:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)

        local is_folder = response:find("<[Dd]:collection") ~= nil

        local size_str  = response:match("<[Dd]:getcontentlength>(.-)</[Dd]:getcontentlength>")
        local size      = size_str and tonumber(size_str) or nil

        local modified  = response:match("<[Dd]:getlastmodified>(.-)</[Dd]:getlastmodified>")

        -- Skip the directory itself (href matches the request path)
        local decoded_href = href:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        local is_self = decoded_href:gsub("/*$","") == (base_url_path or ""):gsub("/*$","")
        if not is_self and name ~= "" then
            table.insert(items, {
                name      = name,
                path      = href,       -- raw server-relative path (URL-encoded)
                is_folder = is_folder,
                size      = size,
                modified  = modified,
            })
        end
    end
    return items
end

-- â”€â”€ Public API â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

--- List the contents of a remote folder.
-- @tparam  string remote_path  Server-relative path, e.g. "/Documents"
-- @treturn table|nil  Array of {name, path, is_folder, size, modified}, or nil on error.
function WebDAV:listFolder(remote_path)
    remote_path = remote_path or "/"
    local url   = self:_url(remote_path)
    local xml   = self:_propfind(url, "1")
    if not xml then return nil end
    -- Extract the path component of our URL for self-filtering
    local url_path = url:match("https?://[^/]+(/.*)") or remote_path
    return parsePROPFIND(xml, url_path)
end

--- Download a remote file to a local path.
-- @tparam  string   remote_path    e.g. "/Documents/notes.pdf"
-- @tparam  string   local_path     e.g. "/tmp/notes.pdf"
-- @tparam  function progress_cb    Optional. Called with (bytes_received).
-- @treturn boolean  true on success
function WebDAV:downloadFile(remote_path, local_path, progress_cb)
    local url = self:_url(remote_path)
    local headers = {
        ["Authorization"] = "Basic " ..
            require("ffi/sha2").bin_to_base64(self.username .. ":" .. self.password),
    }
    local code = Http.download(url, local_path, headers, progress_cb)
    return code == 200
end

--- Upload a local file to a remote path.
-- @tparam  string local_path    e.g. "/tmp/notes.pdf"
-- @tparam  string remote_path   e.g. "/Documents/notes.pdf"
-- @treturn boolean  true on success
function WebDAV:uploadFile(local_path, remote_path)
    local url = self:_url(remote_path)
    local headers = {
        ["Authorization"] = "Basic " ..
            require("ffi/sha2").bin_to_base64(self.username .. ":" .. self.password),
    }
    local code = Http.upload(url, local_path, headers)
    return type(code) == "number" and code >= 200 and code < 300
end

--- Delete a remote resource (file or folder).
-- @tparam  string remote_path
-- @treturn boolean  true on success
function WebDAV:delete(remote_path)
    local url = self:_url(remote_path)
    socketutil:set_timeout()
    local code = socket.skip(1, http.request{
        url    = url,
        method = "DELETE",
        headers = {
            ["Authorization"] = "Basic " ..
                require("ffi/sha2").bin_to_base64(self.username .. ":" .. self.password),
        },
        sink = ltn12.sink.table({}),
    })
    socketutil:reset_timeout()
    return type(code) == "number" and code >= 200 and code < 300
end

--- Create a folder at a remote path (MKCOL).
-- @tparam  string remote_path  e.g. "/Documents/NewFolder"
-- @treturn boolean  true on success (201 Created)
function WebDAV:createFolder(remote_path)
    local url = self:_url(remote_path)
    socketutil:set_timeout()
    local code = socket.skip(1, http.request{
        url    = url,
        method = "MKCOL",
        headers = {
            ["Authorization"] = "Basic " ..
                require("ffi/sha2").bin_to_base64(self.username .. ":" .. self.password),
        },
        sink = ltn12.sink.table({}),
    })
    socketutil:reset_timeout()
    return code == 201
end

-- â”€â”€ Settings helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

--- Build a WebDAV instance from plugin settings.
-- Reads `<settings_key>` from G_reader_settings.
-- Returns nil if not configured.
function WebDAV.fromSettings(settings_key)
    local cfg = G_reader_settings:readSetting(settings_key)
    if not cfg or not cfg.address then return nil end
    return WebDAV:new(cfg)
end

function WebDAV.saveSettings(settings_key, cfg)
    G_reader_settings:saveSetting(settings_key, cfg)
end

return WebDAV
