--[[
components/text-viewer/text_viewer.lua
--------------------------------------
Thin wrapper around KOReader''s built-in TextViewer widget.

KOReader''s native TextViewer (ui/widget/textviewer.lua) already provides
everything needed: TitleBar, ScrollTextWidget, swipe/tap navigation, built-in
text search (Find), font size controls, and monospace toggle. There is no value
in reimplementing it.

This file documents the correct API and adds a convenience constructor that
maps our component''s field names onto TextViewer''s parameters, so callers
don''t need to learn two APIs.

USAGE
-----
    local TextViewer = require("components/text-viewer/text_viewer")

    UIManager:show(TextViewer:new{
        title      = "README",
        text       = long_string,
        -- optional:
        monospace  = true,        -- monospace font (good for logs, code)
        font_size  = 20,          -- initial font size (default: user''s last used)
        on_close   = function() end,
        -- Any field accepted by ui/widget/textviewer.lua also works directly,
        -- e.g.: justified = false, auto_para_direction = false
    })

NATIVE TEXTVIEWER FEATURES (available automatically)
-----------------------------------------------------
  â€¢ Scrolls with swipe east/west (page) and standard gestures
  â€¢ TitleBar with configurable left/right icon buttons
  â€¢ Built-in "Find" button in the bottom bar
  â€¢ Font size / monospace toggle via the â˜° menu icon (show_menu = true)
  â€¢ close_callback fired on close (mapped from on_close below)
  â€¢ Accepts buttons_table for custom bottom-bar buttons
  â€¢ Can display file content directly via the `file` field

KEY NATIVE FIELDS
-----------------
    title            string   Header text
    text             string   Body text (mutually exclusive with file)
    file             string   Filepath to display directly
    width            number   Default: screen width * 0.9
    height           number   Default: screen height * 0.9 (not fullscreen by default)
    justified        bool     Justify text. Default: true
    auto_para_direction bool  Auto-detect RTL. Default: true
    monospace_font   bool     Use monospace font. Default: false
    text_font_size   number   Font size. Default: last used or 22
    show_menu        bool     Show â˜° icon for font/display options. Default: true
    close_callback   function Called when widget is closed
    buttons_table    table    Array of button rows for the bottom bar

NOTES
-----
  â€¢ For fullscreen display pass width=Screen:getWidth(), height=Screen:getHeight().
    The default is a centred overlay (not fullscreen), which suits most uses.
  â€¢ For technical text (logs, code) set justified=false, auto_para_direction=false.
  â€¢ The native widget handles its own scroll; no external scroll calls are needed.

ADAPTED FROM
------------
KOReader: frontend/ui/widget/textviewer.lua
--]]

local NativeTextViewer = require("ui/widget/textviewer")
local Device = require("device")
local Screen = Device.screen

-- Proxy table: behaves like TextViewer:new{} but accepts our field names
local TextViewer = {}
TextViewer.__index = TextViewer

function TextViewer:new(opts)
    opts = opts or {}
    -- Map our convenience field names to native names
    local params = {
        title          = opts.title,
        text           = opts.text,
        file           = opts.file,
        width          = opts.width  or Screen:getWidth(),
        height         = opts.height or Screen:getHeight(),
        -- monospace: our field name; native uses monospace_font
        monospace_font = opts.monospace or opts.monospace_font,
        text_font_size = opts.font_size or opts.text_font_size,
        -- on_close â†’ close_callback
        close_callback = opts.on_close or opts.close_callback,
        -- pass through any other native fields
        justified           = opts.justified,
        auto_para_direction = opts.auto_para_direction,
        alignment           = opts.alignment,
        show_menu           = opts.show_menu,
        buttons_table       = opts.buttons_table,
        fgcolor             = opts.fgcolor,
        title_multilines    = opts.title_multilines,
    }
    -- Remove nil keys so TextViewer uses its own defaults
    for k, v in pairs(params) do
        if v == nil then params[k] = nil end
    end
    return NativeTextViewer:new(params)
end

return TextViewer
