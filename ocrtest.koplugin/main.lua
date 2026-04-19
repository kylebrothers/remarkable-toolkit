--[[
ocrtest.koplugin/main.lua
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
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextViewer      = require("ui/widget/textviewer")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Canvas          = require("components/canvas/canvas")
local OCR             = require("components/ocr/ocr")
local WiFi            = require("components/wifi/wifi")
local SettingsScreen  = require("components/settings-screen/settings_screen")

local Screen = Device.screen
local logger = require("logger")
local _      = require("gettext")

local CANVAS_TMP     = DataStorage:getDataDir() .. "/cache/ocrtest_canvas.png"
local TOOLBAR_HEIGHT = Screen:scaleBySize(60)

-- ── Toolbar widget (InputContainer so buttons get touch events) ───────────────

local Toolbar = InputContainer:extend{}

function Toolbar:init()
    local w = Screen:getWidth()

    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = TOOLBAR_HEIGHT }

    self[1] = FrameContainer:new{
        width      = w,
        height     = TOOLBAR_HEIGHT,
        bordersize = 0,
        padding    = Size.padding.small,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            Button:new{
                text     = _("Clear"),
                width    = math.floor(w * 0.20),
                callback = function() self.on_clear() end,
            },
            HorizontalSpan:new{ width = Size.padding.default },
            Button:new{
                text     = _("Convert"),
                width    = math.floor(w * 0.30),
                callback = function() self.on_convert() end,
            },
            HorizontalSpan:new{ width = Size.padding.default },
            Button:new{
                text     = _("Settings"),
                width    = math.floor(w * 0.25),
                callback = function() self.on_settings() end,
            },
            HorizontalSpan:new{ width = Size.padding.default },
            Button:new{
                text     = _("Close"),
                width    = math.floor(w * 0.20),
                callback = function() self.on_close() end,
            },
        },
    }
end

-- ── Main plugin widget ────────────────────────────────────────────────────────

local OCRTestWidget = WidgetContainer:extend{
    _canvas     = nil,
    _converting = false,
}

function OCRTestWidget:init()
    local w = Screen:getWidth()
    local h = Screen:getHeight()

    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }

    self._canvas = Canvas:new{
        screen_x = 0,
        screen_y = TOOLBAR_HEIGHT,
        width    = w,
        height   = h - TOOLBAR_HEIGHT,
    }

    -- White canvas background — just a painted rectangle, no touch handling
    local canvas_bg = FrameContainer:new{
        width      = w,
        height     = h,
        bordersize = 0,
        padding    = 0,
        background = Blitbuffer.COLOR_WHITE,
        -- Single-pixel content widget so FrameContainer:getSize() doesn't nil
        WidgetContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        },
    }

    local toolbar = Toolbar:new{
        on_clear    = function() self:onClear() end,
        on_convert  = function() self:onConvert() end,
        on_settings = function() self:onSettings() end,
        on_close    = function() self:dismiss() end,
    }

    -- OverlapGroup stacks widgets at absolute positions.
    -- canvas_bg is painted first (bottom), toolbar on top.
    -- Touch events go to the topmost widget whose dimen contains the touch —
    -- toolbar captures taps in the top strip, canvas_bg (which has no gesture
    -- handlers) passes everything else through to KOReader's default handler,
    -- which is harmless since the canvas reads input directly from /dev/input.
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        canvas_bg,
        toolbar,
    }

    -- Full-screen refresh to paint the white background and toolbar
    UIManager:setDirty(self, function()
        return "full", self.dimen
    end)

    self._canvas:start()
end

function OCRTestWidget:onClear()
    self._canvas:clear()
    Notification:notify(_("Canvas cleared"))
end

function OCRTestWidget:onConvert()
    if self._converting then return end
    if not self._canvas.has_content then
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
    self._canvas:stop()
    Notification:notify(_("Sending to OCR backend…"))

    WiFi:whenOnline(function()
        local path, save_err = self._canvas:saveAsPNG(CANVAS_TMP)
        if save_err then
            self._converting = false
            self._canvas:start()
            UIManager:show(InfoMessage:new{ text = _("Canvas save failed:\n") .. save_err })
            return
        end

        UIManager:scheduleIn(0.1, function()
            OCR.recognize(path, function(text, ocr_err, elapsed_ms)
                self._converting = false
                self._canvas:start()
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
                    title               = _("OCR Result"),
                    text                = summary,
                    width               = Screen:getWidth(),
                    height              = Screen:getHeight(),
                    justified           = false,
                    auto_para_direction = false,
                })
            end)
        end)
    end)
end

function OCRTestWidget:onSettings()
    self._canvas:stop()
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
                type      = "input",
                label     = _("API key"),
                key       = "ocr_api_key",
                hint      = _("Required for cloud backends"),
                password  = true,
                default   = "",
                on_change = function() OCR.loadSettings("ocr") end,
            },
            {
                type      = "input",
                label     = _("Model (optional)"),
                key       = "ocr_model",
                hint      = _("Leave blank for default"),
                default   = "",
                on_change = function() OCR.loadSettings("ocr") end,
            },
            { type = "heading", label = "Self-hosted (Ollama)" },
            {
                type      = "input",
                label     = _("Ollama endpoint"),
                key       = "ocr_endpoint",
                hint      = "http://192.168.1.x:11434",
                default   = "",
                on_change = function() OCR.loadSettings("ocr") end,
            },
        },
        on_close = function()
            OCR.loadSettings("ocr")
            self._canvas:start()
        end,
    })
end

function OCRTestWidget:dismiss()
    self._canvas:stop()
    UIManager:close(self)
end

function OCRTestWidget:onClose()
    self:dismiss()
    return true
end

function OCRTestWidget:onCloseWidget()
    self._canvas:stop()
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
