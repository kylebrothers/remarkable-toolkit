--[[
ocrtest.koplugin/main.lua
--------------------------
Minimal test harness for the OCR backend.

PURPOSE
-------
Validate that the OCR component works correctly before building larger apps
that depend on it. Provides:
  • A full-screen drawing canvas (stylus input)
  • A "Convert" button that sends the canvas to the configured OCR backend
  • Output display showing recognised text, backend used, and elapsed time
  • A settings screen for configuring the backend and API key
  • A "Clear" button to start a new drawing

CONFIG FILE (SSH-editable)
--------------------------
Instead of typing the API key on-device, you can create a file at:
  ocrtest.koplugin/ocr_config.json

with content like:
  {
    "backend": "gemini",
    "api_key": "your-key-here",
    "model": "",
    "endpoint": ""
  }

This file is read on plugin init and takes precedence over any previously
saved G_reader_settings values. Edit it over SSH with any text editor.
Empty strings fall back to defaults. The file is optional — if absent the
plugin falls back to settings saved via the in-app Settings screen.

CANVAS IMPLEMENTATION NOTE
---------------------------
The reMarkable 2's Wacom input arrives as absolute coordinates via the Linux
input event system. Rather than relying on KOReader's gesture recogniser
(which is designed for UI gestures, not continuous drawing), we use a
polling loop:

  • A "touch" gesture event starts the loop.
  • Each tick reads raw coordinates via Device.input:getCurrentMtSlotData().
  • The loop reschedules itself every POLL_INTERVAL seconds while the stylus
    is down (id ~= -1), then stops automatically on pen-up.

This gives smooth continuous strokes and reliable pen-up detection, with no
ghost lines between separate strokes.
--]]

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local DataStorage     = require("datastorage")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InfoMessage     = require("ui/widget/infomessage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Notification    = require("ui/widget/notification")
local Size            = require("ui/size")
local TextViewer      = require("ui/widget/textviewer")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local OCR             = require("components/ocr/ocr")
local WiFi            = require("components/wifi/wifi")
local SettingsScreen  = require("components/settings-screen/settings_screen")

local Screen = Device.screen
local logger = require("logger")
local _      = require("gettext")

-- ── Canvas constants ──────────────────────────────────────────────────────────

local CANVAS_TMP    = DataStorage:getDataDir() .. "/cache/ocrtest_canvas.png"
local STROKE_WIDTH  = 3       -- px; adjust for pen feel
local POLL_INTERVAL = 0.05    -- seconds between coordinate polls (~20 fps)

-- ── DrawCanvas widget ─────────────────────────────────────────────────────────
--
-- Handles stylus drawing via a polling loop and exports to PNG.
-- Replaces the pan-gesture approach with raw input polling, which gives:
--   • Continuous real-time feedback on every tick
--   • Reliable pen-up detection (id == -1) so strokes never bleed together

local DrawCanvas = InputContainer:extend{
    width  = nil,
    height = nil,
    _bb    = nil,
    _has_content   = false,
    _poll_callback = nil,   -- pre-bound function, stable reference for unschedule
    _last_x = nil,
    _last_y = nil,
}

function DrawCanvas:init()
    self.width  = self.width  or Screen:getWidth()
    self.height = self.height or Screen:getHeight()

    self._bb = Blitbuffer.new(self.width, self.height, Blitbuffer.TYPE_BB8)
    self._bb:fill(Blitbuffer.COLOR_WHITE)

    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    -- Pre-bind so we can pass the same function reference to both
    -- scheduleIn and unschedule without creating a new closure each tick.
    self._poll_callback = function() self:_poll() end

    -- Only a single "touch" event is needed to start the loop.
    -- The loop itself reads raw Device.input data, not gesture events.
    self.ges_events = {
        TouchCanvas = {
            GestureRange:new{
                ges   = "touch",
                range = function() return self.dimen end,
            },
        },
    }

    self[1] = WidgetContainer:new{ dimen = self.dimen }
end

-- Called once when the stylus first touches the canvas.
function DrawCanvas:onTouchCanvas()
    self._last_x = nil
    self._last_y = nil
    self:_poll()
    return true
end

-- Poll loop: read raw coordinates, paint a segment, then reschedule.
-- Exits automatically when the stylus is lifted (id == -1).
function DrawCanvas:_poll()
    local id = Device.input:getCurrentMtSlotData("id")
    if id == nil or id == -1 then
        -- Pen up — clear interpolation state and stop the loop.
        self._last_x = nil
        self._last_y = nil
        return
    end

    local x = Device.input:getCurrentMtSlotData("x")
    local y = Device.input:getCurrentMtSlotData("y")

    if x and y then
        x = math.max(0, math.min(math.floor(x), self.width  - 1))
        y = math.max(0, math.min(math.floor(y), self.height - 1))

        if self._last_x and self._last_y then
            self:_paintLine(self._last_x, self._last_y, x, y)
        else
            self:_paintDot(x, y)
        end
        self._last_x    = x
        self._last_y    = y
        self._has_content = true

        -- Fast partial e-ink refresh over the stroke area only
        local margin = STROKE_WIDTH + 2
        UIManager:setDirty(self, function()
            return "fast", Geom:new{
                x = math.max(0, x - margin),
                y = math.max(0, y - margin),
                w = margin * 2,
                h = margin * 2,
            }
        end)
    end

    UIManager:scheduleIn(POLL_INTERVAL, self._poll_callback)
end

function DrawCanvas:_paintDot(x, y)
    local r = math.floor(STROKE_WIDTH / 2)
    self._bb:paintRect(
        math.max(0, x - r),
        math.max(0, y - r),
        STROKE_WIDTH,
        STROKE_WIDTH,
        Blitbuffer.COLOR_BLACK
    )
end

function DrawCanvas:_paintLine(x0, y0, x1, y1)
    local dx  = math.abs(x1 - x0)
    local dy  = math.abs(y1 - y0)
    local sx  = x0 < x1 and 1 or -1
    local sy  = y0 < y1 and 1 or -1
    local err = dx - dy
    while true do
        self:_paintDot(x0, y0)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x0 = x0 + sx end
        if e2 <  dx then err = err + dx; y0 = y0 + sy end
    end
end

function DrawCanvas:clear()
    UIManager:unschedule(self._poll_callback)
    self._last_x = nil
    self._last_y = nil
    self._bb:fill(Blitbuffer.COLOR_WHITE)
    self._has_content = false
    UIManager:setDirty(self, "ui")
end

function DrawCanvas:saveAsPNG()
    local lfs = require("libs/libkoreader-lfs")
    local cache_dir = DataStorage:getDataDir() .. "/cache"
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        lfs.mkdir(cache_dir)
    end
    local ok, err = pcall(self._bb.writePNG, self._bb, CANVAS_TMP)
    if not ok then
        return nil, "Failed to save canvas: " .. tostring(err)
    end
    return CANVAS_TMP, nil
end

function DrawCanvas:paintTo(bb, x, y)
    bb:blitFrom(self._bb, x, y, 0, 0, self.width, self.height)
end

function DrawCanvas:getSize()
    return { w = self.width, h = self.height }
end

function DrawCanvas:onCloseWidget()
    UIManager:unschedule(self._poll_callback)
    if self._bb then
        self._bb:free()
        self._bb = nil
    end
end

-- ── Main plugin widget ────────────────────────────────────────────────────────

local TOOLBAR_HEIGHT = Screen:scaleBySize(60)

local OCRTestWidget = InputContainer:extend{
    _canvas     = nil,
    _converting = false,
}

function OCRTestWidget:init()
    local w = Screen:getWidth()
    local h = Screen:getHeight()

    local canvas_height = h - TOOLBAR_HEIGHT
    self._canvas = DrawCanvas:new{
        width  = w,
        height = canvas_height,
    }

    local btn_clear = Button:new{
        text     = _("Clear"),
        width    = math.floor(w * 0.2),
        callback = function() self:onClear() end,
    }
    local btn_convert = Button:new{
        text     = _("Convert"),
        width    = math.floor(w * 0.3),
        callback = function() self:onConvert() end,
    }
    local btn_settings = Button:new{
        text     = _("Settings"),
        width    = math.floor(w * 0.25),
        callback = function() self:onSettings() end,
    }
    local btn_close = Button:new{
        text     = _("Close"),
        width    = math.floor(w * 0.2),
        callback = function() self:dismiss() end,
    }

    local toolbar = FrameContainer:new{
        width      = w,
        height     = TOOLBAR_HEIGHT,
        bordersize = 0,
        padding    = Size.padding.small,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            btn_clear,
            HorizontalSpan:new{ width = Size.padding.default },
            btn_convert,
            HorizontalSpan:new{ width = Size.padding.default },
            btn_settings,
            HorizontalSpan:new{ width = Size.padding.default },
            btn_close,
        },
    }

    self[1] = FrameContainer:new{
        width      = w,
        height     = h,
        bordersize = 0,
        padding    = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            toolbar,
            self._canvas,
        },
    }

    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

function OCRTestWidget:onClear()
    self._canvas:clear()
    Notification:notify(_("Canvas cleared"))
end

function OCRTestWidget:onConvert()
    if self._converting then return end
    if not self._canvas._has_content then
        UIManager:show(InfoMessage:new{
            text    = _("Nothing to convert — draw something first."),
            timeout = 2,
        })
        return
    end
    if not OCR.isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("OCR not configured.\nTap Settings to enter your API key."),
        })
        return
    end

    self._converting = true
    Notification:notify(_("Sending to OCR backend…"))

    WiFi:whenOnline(function()
        local path, err = self._canvas:saveAsPNG()
        if err then
            self._converting = false
            UIManager:show(InfoMessage:new{ text = _("Canvas save failed:\n") .. err })
            return
        end

        UIManager:scheduleIn(0.1, function()
            OCR.recognize(path, function(text, ocr_err, elapsed_ms)
                self._converting = false
                if ocr_err then
                    UIManager:show(InfoMessage:new{
                        text = _("OCR failed:\n") .. tostring(ocr_err),
                    })
                    return
                end
                local summary = string.format(
                    "[%s | %d ms]\n\n%s",
                    OCR.getConfigSummary(),
                    elapsed_ms or 0,
                    text ~= "" and text or _("(no text recognised)")
                )
                UIManager:show(TextViewer:new{
                    title    = _("OCR Result"),
                    text     = summary,
                    width    = Screen:getWidth(),
                    height   = Screen:getHeight(),
                    justified           = false,
                    auto_para_direction = false,
                })
            end)
        end)
    end)
end

function OCRTestWidget:onSettings()
    UIManager:show(SettingsScreen:new{
        title = _("OCR Settings"),
        items = {
            { type = "heading", label = "Backend" },
            {
                type    = "select",
                label   = _("Backend"),
                key     = "ocr_backend",
                options = { "gemini", "openai", "anthropic", "ollama" },
                default = "gemini",
                on_change = function()
                    G_reader_settings:delSetting("ocr_model")
                    OCR.loadSettings("ocr")
                end,
            },
            {
                type     = "input",
                label    = _("API key"),
                key      = "ocr_api_key",
                hint     = _("Required for cloud backends"),
                password = true,
                default  = "",
                on_change = function() OCR.loadSettings("ocr") end,
            },
            {
                type    = "input",
                label   = _("Model (optional)"),
                key     = "ocr_model",
                hint    = _("Leave blank for default"),
                default = "",
                on_change = function() OCR.loadSettings("ocr") end,
            },
            { type = "heading", label = "Self-hosted (Ollama)" },
            {
                type    = "input",
                label   = _("Ollama endpoint"),
                key     = "ocr_endpoint",
                hint    = "http://192.168.1.x:11434",
                default = "",
                on_change = function() OCR.loadSettings("ocr") end,
            },
        },
        on_close = function()
            OCR.loadSettings("ocr")
        end,
    })
end

function OCRTestWidget:dismiss()
    UIManager:close(self)
end

function OCRTestWidget:onClose()
    self:dismiss()
    return true
end

function OCRTestWidget:onCloseWidget()
    os.remove(CANVAS_TMP)
end

-- ── Plugin entry point ────────────────────────────────────────────────────────

local WidgetContainerBase = require("ui/widget/container/widgetcontainer")

local OCRTest = WidgetContainerBase:extend{
    name        = "ocrtest",
    fullname    = _("OCR Test"),
    description = _("Handwriting recognition test harness"),
    disabled    = false,
}

function OCRTest:init()
    self.ui.menu:registerToMainMenu(self)

    -- Config priority:
    --   1. G_reader_settings (baseline from in-app Settings screen)
    --   2. ocr_config.json next to the plugin (SSH-editable, wins if present)
    OCR.loadSettings("ocr")
    OCR.loadFromFile(self.path .. "/ocr_config.json")
end

function OCRTest:addToMainMenu(menu_items)
    menu_items.ocrtest = {
        text     = _("OCR Test"),
        callback = function()
            UIManager:show(OCRTestWidget:new{})
        end,
    }
end

return OCRTest
