--[[
mywidget.lua â€” Example custom full-screen widget

Demonstrates how to build a touchable widget using:
  â€¢ InputContainer  â€” handles touch/gesture input
  â€¢ FrameContainer  â€” draws a border + background
  â€¢ CenterContainer â€” centres child content
  â€¢ TextWidget       â€” renders text
  â€¢ Button           â€” a tappable button

Usage from main.lua:
    local MyWidget = require("myplugin.koplugin/mywidget")
    UIManager:show(MyWidget:new{
        title = "My Screen",
        on_close = function() ... end,
    })
--]]

local Blitbuffer    = require("ffi/blitbuffer")
local Button        = require("ui/widget/button")
local CenterContainer  = require("ui/widget/container/centercontainer")
local Device        = require("device")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom          = require("ui/geometry")
local InputContainer   = require("ui/widget/container/inputcontainer")
local Size          = require("ui/size")
local TextWidget    = require("ui/widget/textwidget")
local UIManager     = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Font          = require("ui/font")
local Screen        = Device.screen
local _             = require("gettext")

local MyWidget = InputContainer:extend{
    title      = _("My Widget"),
    on_close   = nil,   -- optional callback when the widget is dismissed
    width      = nil,   -- defaults to screen width
    height     = nil,   -- defaults to screen height
}

function MyWidget:init()
    self.width  = self.width  or Screen:getWidth()
    self.height = self.height or Screen:getHeight()

    -- â”€â”€ Build content â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    local title_widget = TextWidget:new{
        text = self.title,
        face = Font:getFace("tfont", 28),
        bold = true,
    }

    local body_widget = TextWidget:new{
        text = _("This is a full-screen custom widget.\nReplace with your own content."),
        face = Font:getFace("cfont", 22),
    }

    local close_button = Button:new{
        text     = _("Close"),
        width    = math.floor(self.width * 0.4),
        callback = function()
            self:dismiss()
        end,
    }

    -- â”€â”€ Layout â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    local content = VerticalGroup:new{
        align = "center",
        title_widget,
        -- Spacer (use a FrameContainer with no border as a gap)
        FrameContainer:new{
            bordersize = 0,
            padding    = Size.padding.large,
            body_widget,
        },
        close_button,
    }

    -- Wrap in a frame that fills the screen
    self[1] = FrameContainer:new{
        width      = self.width,
        height     = self.height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = Size.padding.large,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            content,
        },
    }

    -- â”€â”€ Touch zones â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    -- Register a full-screen swipe-down to close gesture
    self:registerTouchZones({
        {
            id      = "mywidget_swipe_close",
            ges     = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 0.2 },
            handler = function(ges)
                if ges.direction == "south" then
                    self:dismiss()
                    return true
                end
            end,
        },
    })
end

function MyWidget:dismiss()
    UIManager:close(self)
    if self.on_close then
        self.on_close()
    end
end

-- Allow back-button / power-key to close
function MyWidget:onClose()
    self:dismiss()
    return true
end

return MyWidget
