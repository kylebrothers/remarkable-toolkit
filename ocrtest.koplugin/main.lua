--[[
ocrtest.koplugin/main.lua
--------------------------
Minimal test harness for the OCR backend.

PURPOSE
-------
Validate that the OCR component works correctly before building larger apps
that depend on it. Provides:
  â€¢ A full-screen drawing canvas (stylus input)
  â€¢ A "Convert" button that sends the canvas to the configured OCR backend
  â€¢ Output display showing recognised text, backend used, and elapsed time
  â€¢ A settings screen for configuring the backend and API key
  â€¢ A "Clear" button to start a new drawing

WHAT THIS TESTS
---------------
  1. Image capture: does the canvas export to a PNG correctly?
  2. Backend connectivity: can we reach the API endpoint?
  3. Recognition quality: is the returned text accurate?
  4. Latency: how long does a round-trip take?
  5. Error handling: what happens with bad credentials, no network, etc.?

HOW TO USE
----------
  1. Deploy this plugin and the components/ directory to your reMarkable.
  2. In KOReader: â˜° â†’ More tools â†’ OCR Test
  3. Configure your backend via the Settings button (top-right)
  4. Draw something with the stylus
  5. Tap "Convert" â€” wait for the result to appear

CANVAS IMPLEMENTATION NOTE
---------------------------
The reMarkable 2''s Wacom input arrives as absolute coordinates via the
input event system. We capture "pan" gestures (stylus movement while
touching the screen) and paint line segments onto a Blitbuffer canvas.
When the user taps "Convert", we save the canvas as a PNG and pass the
path to OCR.recognize().

This approach gives us a clean drawing surface without needing to access
the framebuffer directly.
--]]

local Blitbuffer     = require("ffi/blitbuffer")
local Button         = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage    = require("datastorage")
local Device         = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage    = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification   = require("ui/widget/notification")
local Size           = require("ui/size")
local TextViewer     = require("ui/widget/textviewer")
local TitleBar       = require("ui/widget/titlebar")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local OCR            = require("components/ocr/ocr")
local WiFi           = require("components/wifi/wifi")
local SettingsScreen = require("components/settings-screen/settings_screen")

local Screen = Device.screen
local logger = require("logger")
local _      = require("gettext")

-- â”€â”€ Canvas widget â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Handles stylus drawing and exports to PNG.

local CANVAS_TMP = DataStorage:getDataDir() .. "/cache/ocrtest_canvas.png"
local STROKE_WIDTH = 3  -- pixels, adjust for pen feel

local DrawCanvas = InputContainer:extend{
    width  = nil,
    height = nil,
    _bb    = nil,   -- our drawing Blitbuffer
    _last_x = nil,  -- last stylus position for line interpolation
    _last_y = nil,
    _has_content = false,
}

function DrawCanvas:init()
    self.width  = self.width  or Screen:getWidth()
    self.height = self.height or Screen:getHeight()

    -- Allocate a blitbuffer for our canvas (8-bit greyscale matches e-ink)
    self._bb = Blitbuffer.new(self.width, self.height, Blitbuffer.TYPE_BB8)
    self._bb:fill(Blitbuffer.COLOR_WHITE)

    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    -- Register gesture handlers for stylus drawing
    self:registerTouchZones({
        {
            id      = "canvas_pan",
            ges     = "pan",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                self:onStroke(ges)
                return true
            end,
        },
        {
            id      = "canvas_pan_release",
            ges     = "pan_release",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function()
                self._last_x = nil
                self._last_y = nil
                return true
            end,
        },
        {
            id      = "canvas_hold",
            ges     = "hold",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                -- Single tap/hold starts a new stroke at that point
                local x = math.floor(ges.pos.x)
                local y = math.floor(ges.pos.y)
                self:paintDot(x, y)
                self._last_x = x
                self._last_y = y
                return true
            end,
        },
    })

    self[1] = WidgetContainer:new{
        dimen = self.dimen,
    }
end

function DrawCanvas:paintDot(x, y)
    -- Paint a small filled square for pen feel
    local r = math.floor(STROKE_WIDTH / 2)
    self._bb:paintRect(
        math.max(0, x - r),
        math.max(0, y - r),
        STROKE_WIDTH,
        STROKE_WIDTH,
        Blitbuffer.COLOR_BLACK
    )
    self._has_content = true
end

function DrawCanvas:onStroke(ges)
    local x = math.floor(ges.pos.x)
    local y = math.floor(ges.pos.y)

    if self._last_x and self._last_y then
        -- Draw line from last position to current using Bresenham
        self:paintLine(self._last_x, self._last_y, x, y)
    else
        self:paintDot(x, y)
    end
    self._last_x = x
    self._last_y = y

    -- Trigger a fast partial refresh over the stroke area (e-ink optimised)
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

function DrawCanvas:paintLine(x0, y0, x1, y1)
    -- Bresenham line algorithm
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx - dy
    while true do
        self:paintDot(x0, y0)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x0 = x0 + sx end
        if e2 <  dx then err = err + dx; y0 = y0 + sy end
    end
end

function DrawCanvas:clear()
    self._bb:fill(Blitbuffer.COLOR_WHITE)
    self._has_content = false
    self._last_x = nil
    self._last_y = nil
    UIManager:setDirty(self, "ui")
end

function DrawCanvas:saveAsPNG()
    -- Ensure cache directory exists
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
    if self._bb then
        self._bb:free()
        self._bb = nil
    end
end

-- â”€â”€ Main plugin widget â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local TOOLBAR_HEIGHT = Screen:scaleBySize(60)

local OCRTestWidget = InputContainer:extend{
    _canvas    = nil,
    _converting = false,
}

function OCRTestWidget:init()
    local w = Screen:getWidth()
    local h = Screen:getHeight()

    -- Canvas fills everything below the toolbar
    local canvas_height = h - TOOLBAR_HEIGHT
    self._canvas = DrawCanvas:new{
        width  = w,
        height = canvas_height,
    }

    -- Toolbar buttons
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
            text    = _("Nothing to convert â€” draw something first."),
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
    Notification:notify(_("Sending to OCR backendâ€¦"))

    WiFi:whenOnline(function()
        -- Save canvas to PNG
        local path, err = self._canvas:saveAsPNG()
        if err then
            self._converting = false
            UIManager:show(InfoMessage:new{ text = _("Canvas save failed:\n") .. err })
            return
        end

        -- Run OCR on next tick so notification renders first
        UIManager:scheduleIn(0.1, function()
            OCR.recognize(path, function(text, ocr_err, elapsed_ms)
                self._converting = false
                if ocr_err then
                    UIManager:show(InfoMessage:new{
                        text = _("OCR failed:\n") .. tostring(ocr_err),
                    })
                    return
                end
                -- Show result
                local summary = string.format(
                    "[%s | %d ms]\n\n%s",
                    OCR.getConfigSummary(),
                    elapsed_ms or 0,
                    text ~= "" and text or _("(no text recognised)")
                )
                UIManager:show(TextViewer:new{
                    title  = _("OCR Result"),
                    text   = summary,
                    width  = Screen:getWidth(),
                    height = Screen:getHeight(),
                    justified = false,
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
                on_change = function(val)
                    OCR.loadSettings("ocr")
                    -- Reset model to backend default when backend changes
                    G_reader_settings:delSetting("ocr_model")
                    OCR.loadSettings("ocr")
                end,
            },
            {
                type    = "input",
                label   = _("API key"),
                key     = "ocr_api_key",
                hint    = _("Required for cloud backends"),
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
    -- Clean up temp file
    os.remove(CANVAS_TMP)
end

-- â”€â”€ Plugin entry point â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local WidgetContainerBase = require("ui/widget/container/widgetcontainer")
local OCRTest = WidgetContainerBase:extend{
    name        = "ocrtest",
    fullname    = _("OCR Test"),
    description = _("Handwriting recognition test harness"),
    disabled    = false,
}

function OCRTest:init()
    self.ui.menu:registerToMainMenu(self)
    OCR.loadSettings("ocr")
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
