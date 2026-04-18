--[[
components/http/http.lua
------------------------
Thin wrapper around KOReader''s socket.http with:
  â€¢ Consistent timeout handling via socketutil
  â€¢ GET and POST helpers returning (body_string, status_code, headers) or (nil, code, err_msg)
  â€¢ JSON convenience methods
  â€¢ Automatic Bearer-token injection

USAGE
-----
    local Http = require("components/http/http")

    -- Simple GET:
    local body, code = Http.get("https://example.com/api/data")

    -- GET with headers:
    local body, code = Http.get("https://api.example.com/v1/items", {
        ["Authorization"] = "Bearer " .. token,
    })

    -- POST JSON:
    local body, code = Http.postJSON("https://api.example.com/v1/items",
        { name = "test", value = 42 },
        { ["Authorization"] = "Bearer " .. token }
    )

    -- Parse JSON response:
    local ok, data = Http.parseJSON(body)
    if ok then ... end

    -- Download a file with progress:
    local code = Http.download("https://example.com/file.pdf", "/tmp/file.pdf",
        function(bytes_received) ... end)

ADAPTED FROM
------------
KOReader: plugins/cloudstorage.koplugin/providers/dropbox.lua
          plugins/cloudstorage.koplugin/providers/webdav.lua  (socketutil usage)
--]]

local JSON       = require("json")
local http       = require("socket.http")
local lfs        = require("libs/libkoreader-lfs")
local logger     = require("logger")
local ltn12      = require("ltn12")
local socket     = require("socket")
local socketutil = require("socketutil")

local Http = {}

-- Timeout constants (seconds). Adjust if downloading large files.
local BLOCK_TIMEOUT = socketutil.FILE_BLOCK_TIMEOUT  -- typically 10 s
local TOTAL_TIMEOUT = socketutil.FILE_TOTAL_TIMEOUT  -- typically 30 s

--- Perform an HTTP GET.
-- @tparam string url
-- @tparam[opt] table headers  Key/value pairs added to the request.
-- @treturn string|nil body
-- @treturn number   HTTP status code (or 0 on socket error)
-- @treturn string|nil error message if code == 0
function Http.get(url, headers)
    headers = headers or {}
    local sink = {}
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url     = url,
        method  = "GET",
        headers = headers,
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local body = table.concat(sink)
    if type(code) ~= "number" then
        logger.warn("Http.get: socket error:", code)
        return nil, 0, tostring(code)
    end
    if code ~= 200 then
        logger.warn("Http.get: non-200 response:", status or code, "url:", url)
    end
    return body, code, resp_headers
end

--- Perform an HTTP POST with an arbitrary body.
-- @tparam string url
-- @tparam string body_string   Raw request body.
-- @tparam table headers        Must include Content-Type and Content-Length.
-- @treturn string|nil response body
-- @treturn number   HTTP status code
function Http.post(url, body_string, headers)
    headers = headers or {}
    headers["Content-Length"] = headers["Content-Length"] or #body_string
    local sink = {}
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "POST",
        headers = headers,
        source  = ltn12.source.string(body_string),
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local body = table.concat(sink)
    if type(code) ~= "number" then
        logger.warn("Http.post: socket error:", code)
        return nil, 0, tostring(code)
    end
    if code < 200 or code >= 300 then
        logger.warn("Http.post: non-2xx response:", status or code, "url:", url)
    end
    return body, code
end

--- POST a Lua table serialised as JSON.
-- @tparam string url
-- @tparam table  payload   Will be JSON-encoded.
-- @tparam[opt] table extra_headers  Merged with Content-Type / Content-Length.
-- @treturn string|nil response body
-- @treturn number   HTTP status code
function Http.postJSON(url, payload, extra_headers)
    local ok, body_str = pcall(JSON.encode, payload)
    if not ok then
        logger.err("Http.postJSON: JSON encode failed:", body_str)
        return nil, 0, "JSON encode error"
    end
    local headers = {
        ["Content-Type"]   = "application/json",
        ["Content-Length"] = #body_str,
    }
    if extra_headers then
        for k, v in pairs(extra_headers) do headers[k] = v end
    end
    return Http.post(url, body_str, headers)
end

--- Parse a JSON string safely.
-- @tparam  string json_str
-- @treturn boolean ok
-- @treturn table|string  parsed table, or error message on failure
function Http.parseJSON(json_str)
    if not json_str or json_str == "" then
        return false, "empty response"
    end
    local ok, result = pcall(JSON.decode, json_str)
    if not ok then
        logger.warn("Http.parseJSON: decode failed:", result)
        return false, result
    end
    return true, result
end

--- Download a file to a local path, optionally reporting progress.
-- @tparam  string   url
-- @tparam  string   local_path
-- @tparam  table    headers        e.g. Authorization header
-- @tparam  function progress_cb    Called with (bytes_received) as chunks arrive.
--                                  May be nil.
-- @treturn number   HTTP status code (200 = success)
function Http.download(url, local_path, headers, progress_cb)
    headers = headers or {}
    local handle = ltn12.sink.file(io.open(local_path, "w"))
    if progress_cb then
        handle = socketutil.chainSinkWithProgressCallback(handle, progress_cb)
    end
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "GET",
        headers = headers,
        sink    = handle,
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" then
        logger.warn("Http.download: socket error:", code, "url:", url)
        os.remove(local_path)
        return 0
    end
    if code ~= 200 then
        logger.warn("Http.download: non-200:", status or code, "url:", url)
        os.remove(local_path)
    end
    return code
end

--- Upload a local file via HTTP PUT.
-- @tparam string url
-- @tparam string local_path
-- @tparam table  headers       e.g. Authorization, Content-Type
-- @treturn number HTTP status code (200â€“299 = success)
function Http.upload(url, local_path, headers)
    headers = headers or {}
    local file_size = lfs.attributes(local_path, "size")
    if not file_size then
        logger.warn("Http.upload: file not found:", local_path)
        return 0
    end
    headers["Content-Length"] = file_size
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url    = url,
        method = "PUT",
        headers = headers,
        source  = ltn12.source.file(io.open(local_path, "r")),
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" then
        logger.warn("Http.upload: socket error:", code)
        return 0
    end
    if code < 200 or code >= 300 then
        logger.warn("Http.upload: non-2xx:", status or code, "url:", url)
    end
    return code
end

return Http
