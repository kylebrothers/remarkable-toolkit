--[[
components/ocr/ocr.lua
-----------------------
Handwriting recognition backend abstraction.

Accepts a path to a PNG/JPEG image of handwritten content, sends it to a
configured AI vision backend, and returns the recognised text via callback.

SUPPORTED BACKENDS
------------------
  "gemini"    Google Gemini (gemini-1.5-flash recommended — cheapest capable model)
  "openai"    OpenAI GPT-4o Vision
  "anthropic" Anthropic Claude (claude-3-5-haiku recommended for cost)
  "ollama"    Self-hosted via Ollama (e.g. qwen2-vl:7b on local server)

CONFIGURATION
-------------
Option A — call OCR.configure() from Lua:

    OCR.configure({
        backend  = "gemini",
        api_key  = "AIza...",
        model    = "gemini-1.5-flash",   -- optional, uses backend default if nil
        endpoint = nil,                  -- only needed for ollama
        prompt   = nil,                  -- optional custom prompt override
    })

Option B — drop a JSON file next to the plugin (editable via SSH):

    -- File: ocrtest.koplugin/ocr_config.json
    -- {
    --   "backend":  "gemini",
    --   "api_key":  "AIza...",
    --   "model":    "",
    --   "endpoint": ""
    -- }

    OCR.loadFromFile("/path/to/ocrtest.koplugin/ocr_config.json")

    Both options can be combined; loadFromFile() and loadSettings() both call
    configure() internally, so the last one called wins.

USAGE
-----
    OCR.recognize("/tmp/handwriting.png", function(text, err, elapsed_ms)
        if err then
            logger.warn("OCR failed:", err)
            return
        end
        myPlugin:onTextReady(text, elapsed_ms)
    end)

IMAGE REQUIREMENTS
------------------
  • PNG or JPEG, any reasonable resolution
  • The reMarkable 2 screen is 1404×1872 at 226 DPI — a full-page capture
    at native resolution works well
  • The image is base64-encoded before transmission; keep file size reasonable
    (~200-400 KB for a full page) to avoid excessive API latency

ADAPTED FROM
------------
KOReader: components/http/http.lua  (socket/socketutil patterns)
          plugins/cloudstorage.koplugin/providers/dropbox.lua (base64 via sha2)
--]]

local Http    = require("components/http/http")
local JSON    = require("json")
local logger  = require("logger")
local sha2    = require("ffi/sha2")
local time    = require("ui/time")

-- ── Default prompts ──────────────────────────────────────────────────────────

local DEFAULT_PROMPT = [[Please transcribe all handwritten text in this image exactly as written.
Output only the transcribed text with no commentary, labels, or formatting additions.
Preserve paragraph breaks and list structure where visible.
If the image contains no handwriting, output an empty string.]]

-- ── Backend endpoint constants ───────────────────────────────────────────────

local ENDPOINTS = {
    gemini    = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s",
    openai    = "https://api.openai.com/v1/chat/completions",
    anthropic = "https://api.anthropic.com/v1/messages",
}

local DEFAULT_MODELS = {
    gemini    = "gemini-2.0-flash",
    openai    = "gpt-4o",
    anthropic = "claude-3-5-haiku-20241022",
    ollama    = "qwen2-vl:7b",
}

-- ── Module state ─────────────────────────────────────────────────────────────

local OCR = {
    _backend  = nil,
    _api_key  = nil,
    _model    = nil,
    _endpoint = nil,
    _prompt   = DEFAULT_PROMPT,
}

-- ── Configuration ─────────────────────────────────────────────────────────────

--- Configure the OCR backend.
-- Must be called before recognize(). Safe to call multiple times (e.g. after
-- settings change).
-- @tparam table opts  See module header for fields.
function OCR.configure(opts)
    opts = opts or {}
    OCR._backend  = opts.backend  or OCR._backend  or "gemini"
    OCR._api_key  = opts.api_key  or OCR._api_key
    OCR._model    = opts.model    or DEFAULT_MODELS[OCR._backend]
    OCR._endpoint = opts.endpoint or OCR._endpoint
    OCR._prompt   = opts.prompt   or DEFAULT_PROMPT
    logger.dbg("OCR configured: backend=", OCR._backend, "model=", OCR._model)
end

--- Load OCR configuration from a JSON file on disk.
-- Intended for SSH-based editing: drop ocr_config.json next to the plugin,
-- edit it with any text editor over SSH, and it will be picked up on next
-- plugin init (or whenever you call this function).
--
-- The file must be valid JSON with any subset of these keys:
--   { "backend": "gemini", "api_key": "...", "model": "", "endpoint": "" }
-- Empty strings are treated as absent (falls back to defaults).
--
-- Returns true on success, false + error string on failure.
-- Failures are non-fatal: the plugin continues with whatever was configured
-- previously (or defaults).
--
-- @tparam  string file_path  Absolute path to the JSON config file.
-- @treturn boolean, string|nil
function OCR.loadFromFile(file_path)
    local f = io.open(file_path, "r")
    if not f then
        -- File absent is normal (user hasn't created it yet); not an error.
        logger.dbg("OCR.loadFromFile: no config file at", file_path)
        return false, "file not found"
    end
    local raw = f:read("*all")
    f:close()

    if not raw or raw == "" then
        logger.warn("OCR.loadFromFile: empty file at", file_path)
        return false, "empty file"
    end

    local ok, parsed = pcall(JSON.decode, raw)
    if not ok or type(parsed) ~= "table" then
        logger.warn("OCR.loadFromFile: JSON parse error:", parsed)
        return false, "JSON parse error: " .. tostring(parsed)
    end

    -- Treat empty strings as nil so configure() uses its defaults
    local function nonempty(v)
        return (type(v) == "string" and v ~= "") and v or nil
    end

    OCR.configure({
        backend  = nonempty(parsed.backend),
        api_key  = nonempty(parsed.api_key),
        model    = nonempty(parsed.model),
        endpoint = nonempty(parsed.endpoint),
        prompt   = nonempty(parsed.prompt),
    })

    logger.info("OCR.loadFromFile: loaded config from", file_path)
    return true
end

--- Returns true if OCR has been configured with the minimum required fields.
function OCR.isConfigured()
    if OCR._backend == "ollama" then
        return OCR._endpoint ~= nil
    end
    return OCR._api_key ~= nil
end

--- Return current configuration summary (safe to display to user, no secrets).
function OCR.getConfigSummary()
    return string.format("backend=%s model=%s", OCR._backend or "?", OCR._model or "?")
end

-- ── Internal: image loading ───────────────────────────────────────────────────

local function loadImageAsBase64(image_path)
    local f = io.open(image_path, "rb")
    if not f then
        return nil, "Cannot open image file: " .. tostring(image_path)
    end
    local data = f:read("*all")
    f:close()
    if not data or #data == 0 then
        return nil, "Image file is empty: " .. tostring(image_path)
    end
    local b64 = sha2.bin_to_base64(data)
    local media_type = "image/png"
    if data:sub(1,2) == "\xFF\xD8" then
        media_type = "image/jpeg"
    end
    return b64, nil, media_type
end

-- ── Backend implementations ───────────────────────────────────────────────────

local function recognize_gemini(b64, media_type, callback, t_start)
    local url = string.format(ENDPOINTS.gemini, OCR._model, OCR._api_key)
    local payload = {
        contents = {{
            parts = {
                { text = OCR._prompt },
                { inline_data = { mime_type = media_type, data = b64 } },
            }
        }}
    }
    local headers = { ["Content-Type"] = "application/json" }
    local body, code = Http.postJSON(url, payload, headers)
    local elapsed = time.to_ms(time.now() - t_start)

    if code ~= 200 then
        callback(nil, string.format("Gemini API error: HTTP %d", code), elapsed)
        return
    end
    local ok, result = Http.parseJSON(body)
    if not ok then
        callback(nil, "Gemini: JSON parse error: " .. tostring(result), elapsed)
        return
    end
    local text = result.candidates
        and result.candidates[1]
        and result.candidates[1].content
        and result.candidates[1].content.parts
        and result.candidates[1].content.parts[1]
        and result.candidates[1].content.parts[1].text
    if not text then
        callback(nil, "Gemini: unexpected response structure", elapsed)
        return
    end
    callback(text, nil, elapsed)
end

local function recognize_openai(b64, media_type, callback, t_start)
    local data_url = string.format("data:%s;base64,%s", media_type, b64)
    local payload = {
        model = OCR._model,
        messages = {{
            role = "user",
            content = {
                { type = "text",      text = OCR._prompt },
                { type = "image_url", image_url = { url = data_url, detail = "high" } },
            }
        }},
        max_tokens = 2048,
    }
    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. OCR._api_key,
    }
    local body, code = Http.postJSON(ENDPOINTS.openai, payload, headers)
    local elapsed = time.to_ms(time.now() - t_start)

    if code ~= 200 then
        callback(nil, string.format("OpenAI API error: HTTP %d", code), elapsed)
        return
    end
    local ok, result = Http.parseJSON(body)
    if not ok then
        callback(nil, "OpenAI: JSON parse error: " .. tostring(result), elapsed)
        return
    end
    local text = result.choices
        and result.choices[1]
        and result.choices[1].message
        and result.choices[1].message.content
    if not text then
        callback(nil, "OpenAI: unexpected response structure", elapsed)
        return
    end
    callback(text, nil, elapsed)
end

local function recognize_anthropic(b64, media_type, callback, t_start)
    local payload = {
        model      = OCR._model,
        max_tokens = 2048,
        messages   = {{
            role    = "user",
            content = {
                {
                    type   = "image",
                    source = {
                        type       = "base64",
                        media_type = media_type,
                        data       = b64,
                    },
                },
                { type = "text", text = OCR._prompt },
            },
        }},
    }
    local headers = {
        ["Content-Type"]      = "application/json",
        ["x-api-key"]         = OCR._api_key,
        ["anthropic-version"] = "2023-06-01",
    }
    local body, code = Http.postJSON(ENDPOINTS.anthropic, payload, headers)
    local elapsed = time.to_ms(time.now() - t_start)

    if code ~= 200 then
        callback(nil, string.format("Anthropic API error: HTTP %d", code), elapsed)
        return
    end
    local ok, result = Http.parseJSON(body)
    if not ok then
        callback(nil, "Anthropic: JSON parse error: " .. tostring(result), elapsed)
        return
    end
    local text = result.content
        and result.content[1]
        and result.content[1].text
    if not text then
        callback(nil, "Anthropic: unexpected response structure", elapsed)
        return
    end
    callback(text, nil, elapsed)
end

local function recognize_ollama(b64, media_type, callback, t_start) -- luacheck: ignore media_type
    local url = OCR._endpoint:gsub("/$", "") .. "/api/generate"
    local payload = {
        model  = OCR._model,
        prompt = OCR._prompt,
        images = { b64 },
        stream = false,
    }
    local headers = { ["Content-Type"] = "application/json" }
    local body, code = Http.postJSON(url, payload, headers)
    local elapsed = time.to_ms(time.now() - t_start)

    if code ~= 200 then
        callback(nil, string.format("Ollama error: HTTP %d", code), elapsed)
        return
    end
    local ok, result = Http.parseJSON(body)
    if not ok then
        callback(nil, "Ollama: JSON parse error: " .. tostring(result), elapsed)
        return
    end
    local text = result.response
    if not text then
        callback(nil, "Ollama: unexpected response structure", elapsed)
        return
    end
    callback(text, nil, elapsed)
end

local BACKENDS = {
    gemini    = recognize_gemini,
    openai    = recognize_openai,
    anthropic = recognize_anthropic,
    ollama    = recognize_ollama,
}

-- ── Public API ────────────────────────────────────────────────────────────────

--- Recognise handwriting in an image file.
--
-- This function is synchronous from Lua's perspective — it blocks until the
-- HTTP request completes. Call it from within UIManager:scheduleIn() or a
-- Progress.run() callback to keep the UI responsive.
--
-- @tparam  string   image_path   Path to PNG or JPEG file on device storage.
-- @tparam  function callback     Called as callback(text, err, elapsed_ms).
function OCR.recognize(image_path, callback)
    if not OCR.isConfigured() then
        callback(nil, "OCR not configured — call OCR.configure() first", 0)
        return
    end

    local backend_fn = BACKENDS[OCR._backend]
    if not backend_fn then
        callback(nil, "Unknown OCR backend: " .. tostring(OCR._backend), 0)
        return
    end

    local b64, err, media_type = loadImageAsBase64(image_path)
    if err then
        callback(nil, err, 0)
        return
    end

    local t_start = time.now()
    local ok, call_err = pcall(backend_fn, b64, media_type, callback, t_start)
    if not ok then
        local elapsed = time.to_ms(time.now() - t_start)
        callback(nil, "OCR backend exception: " .. tostring(call_err), elapsed)
    end
end

-- ── Settings helpers ──────────────────────────────────────────────────────────

--- Save OCR configuration to G_reader_settings under a given prefix.
function OCR.saveSettings(prefix)
    prefix = prefix or "ocr"
    G_reader_settings:saveSetting(prefix .. "_backend",  OCR._backend)
    G_reader_settings:saveSetting(prefix .. "_api_key",  OCR._api_key)
    G_reader_settings:saveSetting(prefix .. "_model",    OCR._model)
    G_reader_settings:saveSetting(prefix .. "_endpoint", OCR._endpoint)
end

--- Load OCR configuration from G_reader_settings and apply it.
function OCR.loadSettings(prefix)
    prefix = prefix or "ocr"
    OCR.configure({
        backend  = G_reader_settings:readSetting(prefix .. "_backend"),
        api_key  = G_reader_settings:readSetting(prefix .. "_api_key"),
        model    = G_reader_settings:readSetting(prefix .. "_model"),
        endpoint = G_reader_settings:readSetting(prefix .. "_endpoint"),
    })
end

return OCR
