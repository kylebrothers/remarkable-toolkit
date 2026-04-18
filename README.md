# remarkable2-koplugin-template

A starting-point repository for writing KOReader plugins that run on the **reMarkable 2**.  
It includes annotated source files and this README, which together give a Claude chat (or a human developer) everything needed to write a new, working plugin without prior KOReader knowledge.

---

## Table of contents

1. [What this is](#1-what-this-is)
2. [Device context â€” reMarkable 2](#2-device-context--remarkable-2)
3. [How KOReader plugins work](#3-how-koreader-plugins-work)
4. [Repository layout](#4-repository-layout)
5. [Renaming the plugin](#5-renaming-the-plugin)
6. [Deploying to the device](#6-deploying-to-the-device)
7. [Core API reference](#7-core-api-reference)
8. [UI widget catalogue](#8-ui-widget-catalogue)
9. [Touch & gesture input](#9-touch--gesture-input)
10. [Settings persistence](#10-settings-persistence)
11. [Event system](#11-event-system)
12. [Logging & debugging](#12-logging--debugging)
13. [Common patterns (copy-paste snippets)](#13-common-patterns-copy-paste-snippets)
14. [reMarkable 2 constraints & gotchas](#14-remarkable-2-constraints--gotchas)
15. [Checklist for a new plugin](#15-checklist-for-a-new-plugin)

---

## 1. What this is

KOReader is an open-source document reader written primarily in Lua. It ships on the reMarkable 2 as a community-installed third-party reader. Its plugin system lets you add new features â€” menu entries, full-screen UIs, background tasks, etc. â€” without modifying KOReader itself.

This template gives you:

- A minimal but complete plugin skeleton (`_meta.lua` + `main.lua`)
- An example custom widget (`mywidget.lua`)
- This README as a dense reference document

---

## 2. Device context â€” reMarkable 2

| Property | Value |
|---|---|
| CPU | ARM Cortex-A7 (i.MX7D, 1 GHz) â€” **32-bit ARM** |
| RAM | 1 GB |
| Screen | 1404 Ã— 1872 px, 226 DPI, **e-ink (greyscale only)** |
| Touch | Wacom EMR stylus + capacitive multitouch |
| OS | Linux (custom Yocto) |
| KOReader runtime | LuaJIT 2.1 |
| KOReader base path | `/home/root/koreader/` (typical) |
| User plugin path | `/home/root/.adds/koreader/plugins/` or `/home/root/koreader/plugins/` |
| SSH root password | Shown in **Settings â†’ Help â†’ Copyrights and licenses** (scroll to bottom) |
| USB IP | `10.11.99.1` (USB-C to computer) |

**Critical hardware facts for UI design:**

- The screen is **greyscale**. `Blitbuffer.COLOR_WHITE` / `COLOR_BLACK` and greyscale values only. No colour.
- E-ink refresh is slow (~250 ms full refresh, ~50 ms partial). **Minimize repaints.** Use `"partial"` or `"ui"` refresh type wherever possible; `"full"` only when the whole screen changes substantially.
- The reMarkable 2 requires the **RM2FB shim** (`RM2FB_SHIM` env var). KOReader''s launch script handles this automatically; your plugin does not need to worry about it.
- Physical buttons: **power button** only (on the side). There are no page-turn buttons. All navigation is touch-based or gesture-based.
- Screen is in **portrait** orientation by default (1404 wide Ã— 1872 tall). Rotation is possible but uncommon.

---

## 3. How KOReader plugins work

### Discovery

At startup, `PluginLoader` scans:
- `<koreader>/plugins/` (built-in)
- Paths in `G_reader_settings:readSetting("extra_plugin_paths")` (user plugins)

A directory whose name ends in `.koplugin` is treated as a plugin. Inside it:

| File | Required | Purpose |
|---|---|---|
| `_meta.lua` | Yes | Loaded even when disabled. Returns `{ fullname, description }`. |
| `main.lua` | Yes | Full plugin module. Loaded when enabled. Must return the plugin table. |

### Instantiation

`PluginLoader` does `dofile("main.lua")` and merges the returned table with `_meta.lua`. The plugin is then instantiated (`:new{}`) by either `ReaderUI` or `FileManager` (or both), which calls `plugin:init()`.

### Module inheritance chain

```
WidgetContainer  â†  InputContainer  â†  your plugin / custom widget
```

- `WidgetContainer` handles layout (`paintTo`, `getSize`, child indexing via `self[1]`).
- `InputContainer` adds touch zones and key events.
- Your plugin extends one of these via `:extend{}`.

---

## 4. Repository layout

```
remarkable2-koplugin-template/
â””â”€â”€ myplugin.koplugin/
    â”œâ”€â”€ _meta.lua       Minimal metadata (always loaded)
    â”œâ”€â”€ main.lua        Plugin entry point, menu registration, actions
    â””â”€â”€ mywidget.lua    Example custom full-screen widget
```

---

## 5. Renaming the plugin

1. Rename the directory: `myplugin.koplugin` â†’ `yourplugin.koplugin`
2. In `main.lua`: change `name`, `fullname`, `description`, the `menu_items` key (`menu_items.myplugin`), and any references to `MyPlugin`.
3. In `_meta.lua`: update `fullname` and `description`.
4. In `mywidget.lua`: rename `MyWidget` and update the `require` path in `main.lua`.

---

## 6. Deploying to the device

### Via SSH / SCP (recommended)

```bash
# Connect via USB-C (device IP: 10.11.99.1) or Wi-Fi (find IP in Settings â†’ Help)
scp -r myplugin.koplugin root@10.11.99.1:/home/root/koreader/plugins/

# Then restart KOReader on the device (swipe down â†’ top-right icon â†’ Exit,
# then re-launch from xochitl or your launcher)
```

Password is shown in **Settings â†’ Help â†’ Copyrights and licenses** on the device.

### Enable the plugin

In KOReader: **â˜° â†’ More tools â†’ Plugin manager** â†’ find your plugin â†’ toggle on â†’ restart when prompted.

### Iterating quickly

```bash
# Edit locally, then push and soft-restart:
scp myplugin.koplugin/main.lua root@10.11.99.1:/home/root/koreader/plugins/myplugin.koplugin/
# In KOReader: â˜° â†’ More tools â†’ Restart KOReader  (or use the restart menu entry)
```

---

## 7. Core API reference

### UIManager

```lua
local UIManager = require("ui/uimanager")

UIManager:show(widget)                     -- push widget onto the stack
UIManager:show(widget, "partial")          -- push + schedule a partial refresh
UIManager:close(widget)                    -- pop widget
UIManager:setDirty(widget, "ui")           -- schedule repaint (no show/close)
UIManager:scheduleIn(seconds, callback)    -- run callback after delay
UIManager:unschedule(callback)             -- cancel a scheduled callback
UIManager:askForRestart(message)           -- prompt user to restart KOReader
```

**Refresh types** (second arg to `show` / `setDirty`):

| Type | Use when |
|---|---|
| `"full"` | Major screen change (e.g., opening a new screen) |
| `"partial"` | Small area changed, speed matters |
| `"ui"` | Standard UI element appeared/changed |
| `"fast"` | Fastest, lowest quality (progress indicators) |
| `"flashui"` | Flash then clear (menus) |
| `"a2"` | Two-level (black/white only, fastest for text) |

### Device / Screen

```lua
local Device = require("device")
local Screen = Device.screen

Screen:getWidth()    -- 1404 (portrait)
Screen:getHeight()   -- 1872 (portrait)
Screen:getSize()     -- Geom{w=1404, h=1872}
Screen:getDPI()      -- 226

Device:isTouchDevice()   -- true
Device:hasKeys()         -- true (power button)
Device:isRemarkable()    -- true
```

### Geometry

```lua
local Geom = require("ui/geometry")
local g = Geom:new{ x=0, y=0, w=100, h=50 }
g:intersect(other_geom)   -- returns intersection Geom or nil
```

### Font

```lua
local Font = require("ui/font")
Font:getFace("cfont", 22)   -- standard body font, size 22
Font:getFace("tfont", 28)   -- title font
Font:getFace("mfont", 20)   -- monospace
-- Size is in scaled pixels; the framework scales for DPI automatically.
```

### Size constants

```lua
local Size = require("ui/size")
Size.padding.default    -- ~8 px
Size.padding.large      -- ~16 px
Size.border.window      -- standard window border
Size.radius.window      -- standard corner radius
```

### Settings

```lua
-- Global (persisted across sessions in settings.reader.lua)
G_reader_settings:saveSetting("myplugin_key", value)
G_reader_settings:readSetting("myplugin_key")        -- returns nil if unset
G_reader_settings:delSetting("myplugin_key")
G_reader_settings:isTrue("myplugin_flag")            -- boolean helper
G_reader_settings:has("myplugin_key")                -- existence check

-- Per-document (in DocSettings, available via event arg `config`)
-- See Â§10 for details.
```

---

## 8. UI widget catalogue

All widgets live under `frontend/ui/widget/`. Require them as shown.

### Display widgets

```lua
-- Single line of text
local TextWidget = require("ui/widget/textwidget")
TextWidget:new{ text = "Hello", face = Font:getFace("cfont", 22), bold = true }

-- Multi-line text, wraps to width
local TextBoxWidget = require("ui/widget/textboxwidget")
TextBoxWidget:new{ text = "Long textâ€¦", face = Font:getFace("cfont", 20), width = 800 }

-- Image from file
local ImageWidget = require("ui/widget/imagewidget")
ImageWidget:new{ file = self.path .. "/icon.png", width = 64, height = 64 }
```

### Container widgets

```lua
-- Frame with border, background, padding
local FrameContainer = require("ui/widget/container/framecontainer")
FrameContainer:new{
    bordersize = Size.border.window,
    background = Blitbuffer.COLOR_WHITE,
    padding    = Size.padding.default,
    radius     = Size.radius.window,
    child_widget,   -- self[1]
}

-- Centre a child within a given size
local CenterContainer = require("ui/widget/container/centercontainer")
CenterContainer:new{ dimen = Screen:getSize(), child_widget }

-- Stack children vertically
local VerticalGroup = require("ui/widget/verticalgroup")
VerticalGroup:new{ align = "center", widget_a, widget_b, widget_c }

-- Stack children horizontally
local HorizontalGroup = require("ui/widget/horizontalgroup")
HorizontalGroup:new{ align = "center", left_widget, right_widget }

-- Overlap children (z-stack)
local OverlapGroup = require("ui/widget/overlapgroup")
OverlapGroup:new{ dimen = Screen:getSize(), background, foreground }

-- Fixed empty space
local HorizontalSpan = require("ui/widget/horizontalspan")
HorizontalSpan:new{ width = 20 }
local VerticalSpan = require("ui/widget/verticalspan")
VerticalSpan:new{ width = 12 }   -- height is "width" field here
```

### Interactive widgets

```lua
-- Simple tappable button
local Button = require("ui/widget/button")
Button:new{
    text     = _("OK"),
    width    = 300,
    callback = function() ... end,
}

-- Row of buttons
local ButtonTable = require("ui/widget/buttontable")
ButtonTable:new{
    width   = Screen:getWidth(),
    buttons = {
        {{ text = _("Cancel"), callback = ... }, { text = _("OK"), callback = ... }},
    },
}

-- Scrollable list / menu
local Menu = require("ui/widget/menu")
Menu:new{
    title      = _("Choose"),
    item_table = {
        { text = "Item 1", callback = function() ... end },
        { text = "Item 2", callback = function() ... end },
    },
    width  = Screen:getWidth(),
    height = Screen:getHeight(),
    close_callback = function() ... end,
}
```

### Dialog widgets

```lua
-- Info popup (auto-dismisses on tap)
local InfoMessage = require("ui/widget/infomessage")
UIManager:show(InfoMessage:new{ text = _("Done!") })

-- Yes/No confirmation
local ConfirmBox = require("ui/widget/confirmbox")
UIManager:show(ConfirmBox:new{
    text        = _("Are you sure?"),
    ok_text     = _("Yes"),
    cancel_text = _("No"),
    ok_callback     = function() ... end,
    cancel_callback = function() ... end,
})

-- Text input
local InputDialog = require("ui/widget/inputdialog")
local dlg
dlg = InputDialog:new{
    title   = _("Enter text"),
    input   = "default value",
    buttons = {{
        { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
        { text = _("OK"),     is_enter_default = true,
          callback = function()
              local val = dlg:getInputText()
              UIManager:close(dlg)
          end },
    }},
}
UIManager:show(dlg)

-- Toast notification (non-blocking, fades out)
local Notification = require("ui/widget/notification")
Notification:notify(_("Saved!"))
```

---

## 9. Touch & gesture input

Widgets that need touch input must extend `InputContainer`.

### Touch zones

Zones are registered in `init()` using ratio-based coordinates (0.0â€“1.0 relative to screen):

```lua
self:registerTouchZones({
    {
        id      = "myplugin_tap_body",
        ges     = "tap",
        screen_zone = {
            ratio_x = 0,   ratio_y = 0.1,
            ratio_w = 1,   ratio_h = 0.8,
        },
        handler = function(ges)
            -- ges.pos.x, ges.pos.y â€” absolute screen coordinates
            self:onBodyTap(ges)
            return true   -- consume event; return false/nil to propagate
        end,
    },
    {
        id      = "myplugin_swipe_close",
        ges     = "swipe",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        handler = function(ges)
            if ges.direction == "south" then   -- swipe down
                self:dismiss()
                return true
            end
        end,
    },
})
```

Supported `ges` values: `"tap"`, `"hold"`, `"swipe"`, `"pan"`, `"pinch"`, `"spread"`, `"two_finger_tap"`, `"double_tap"`.

Swipe directions: `"north"`, `"south"`, `"east"`, `"west"`, `"northeast"`, etc.

### Gesture event fields

| Field | Type | Description |
|---|---|---|
| `ges.ges` | string | Gesture name (e.g. `"tap"`) |
| `ges.pos` | Geom | Position `{x, y}` of touch |
| `ges.direction` | string | Swipe/pan direction |
| `ges.distance` | number | Swipe/pan distance in px |
| `ges.time` | time | Timestamp |

### ges_events (legacy style, simpler for single gestures)

```lua
MyWidget = InputContainer:extend{
    ges_events = {
        TapClose = {
            GestureRange:new{
                ges   = "tap",
                range = Geom:new{ x=0, y=0, w=Screen:getWidth(), h=60 },
            }
        },
    },
}
function MyWidget:onTapClose(ges)
    self:dismiss()
    return true
end
```

---

## 10. Settings persistence

### Global settings (survive app restarts, shared across documents)

```lua
-- Save
G_reader_settings:saveSetting("myplugin_count", 42)
G_reader_settings:saveSetting("myplugin_options", { foo = true, bar = "hello" })

-- Read (returns nil if missing)
local count   = G_reader_settings:readSetting("myplugin_count") or 0
local options = G_reader_settings:readSetting("myplugin_options") or {}

-- Delete
G_reader_settings:delSetting("myplugin_count")
```

Stored in `<koreader>/settings.reader.lua`. Prefix all keys with your plugin name to avoid collisions.

### Per-document settings

```lua
-- In your plugin''s onReadSettings handler:
function MyPlugin:onReadSettings(config)
    self.doc_note = config:readSetting("myplugin_note") or ""
end

-- In onSaveSettings:
function MyPlugin:onSaveSettings()
    self.ui.doc_settings:saveSetting("myplugin_note", self.doc_note)
end
```

---

## 11. Event system

KOReader uses a publish/subscribe event model. Events flow through the widget stack (top to bottom), stopping when a handler returns `true`. `broadcastEvent` sends to all widgets regardless.

### Receiving events

Define methods named `on<EventName>` in your plugin/widget:

```lua
-- Document lifecycle
function MyPlugin:onReadSettings(config) end   -- doc opened, settings available
function MyPlugin:onReaderReady() end           -- reader UI fully ready
function MyPlugin:onSaveSettings() end          -- about to save (doc closing)
function MyPlugin:onCloseDocument() end         -- doc closed

-- Screen / UI
function MyPlugin:onScreenResize(new_dimen) end
function MyPlugin:onResume() end                -- device woke from sleep
function MyPlugin:onSuspend() end               -- device going to sleep

-- Generic close signal (back gesture, power button, etc.)
function MyPlugin:onClose()
    self:dismiss()
    return true
end
```

### Sending events

```lua
local Event = require("ui/event")

-- Send to the widget stack (top widget first):
UIManager:sendEvent(Event:new("MyCustomEvent", arg1, arg2))

-- Send to all widgets:
UIManager:broadcastEvent(Event:new("MyCustomEvent"))
```

Receiving widget must have `onMyCustomEvent(arg1, arg2)` defined.

---

## 12. Logging & debugging

```lua
local logger = require("logger")

logger.dbg("debug: table =", my_table)   -- only shown when debug mode on
logger.info("info message")
logger.warn("warning: something odd")
logger.err("error: something failed")
```

Logs go to `<koreader>/crash.log`.  

**Read logs live over SSH:**
```bash
ssh root@10.11.99.1 "tail -f /home/root/koreader/crash.log"
```

**Enable debug mode** (verbose logging):  
In KOReader: â˜° â†’ **Settings â†’ Developer options â†’ Enable debug logging**  
Or set `KODEBUG=1` in the launch environment.

**Test a widget in isolation** (emulator, Linux only):  
```bash
# From the KOReader source tree:
./kodev wbuilder
# Edit tools/wbuilder.lua, add UIManager:show(MyWidget:new{})
```

---

## 13. Common patterns (copy-paste snippets)

### Minimal plugin that adds a menu entry and shows a dialog

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local _               = require("gettext")

local MyPlugin = WidgetContainer:extend{
    name        = "myplugin",
    fullname    = _("My Plugin"),
    description = _("Does something useful"),
}

function MyPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function MyPlugin:addToMainMenu(menu_items)
    menu_items.myplugin = {
        text     = _("My Plugin"),
        callback = function()
            UIManager:show(InfoMessage:new{ text = _("Hello!") })
        end,
    }
end

return MyPlugin
```

### Sub-menu with multiple entries

```lua
function MyPlugin:addToMainMenu(menu_items)
    menu_items.myplugin = {
        text            = _("My Plugin"),
        sub_item_table  = {
            {
                text     = _("Action A"),
                callback = function() self:doA() end,
            },
            {
                text           = _("Toggle option"),
                checked_func   = function() return self.option_on end,
                callback       = function()
                    self.option_on = not self.option_on
                    G_reader_settings:saveSetting("myplugin_option", self.option_on)
                end,
            },
        },
    }
end
```

### Scrollable full-screen menu

```lua
local Menu  = require("ui/widget/menu")
local Screen = require("device").screen

local items = {}
for i = 1, 20 do
    table.insert(items, {
        text     = "Item " .. i,
        callback = function() logger.dbg("tapped", i) end,
    })
end

local menu = Menu:new{
    title          = _("Pick one"),
    item_table     = items,
    width          = Screen:getWidth(),
    height         = Screen:getHeight(),
    close_callback = function() UIManager:close(menu) end,
}
UIManager:show(menu)
```

### Running a background task with a progress notification

```lua
local Notification = require("ui/widget/notification")

Notification:notify(_("Workingâ€¦"))
UIManager:scheduleIn(0, function()
    -- do the work here (keep it fast or use coroutines for long tasks)
    local result = self:heavyComputation()
    Notification:notify(_("Done: ") .. result)
end)
```

### Drawing custom graphics directly to the screen

```lua
-- In a custom widget''s paintTo:
function MyWidget:paintTo(bb, x, y)
    -- Call parent first
    WidgetContainer.paintTo(self, bb, x, y)

    -- Draw a black rectangle
    bb:paintRect(x + 10, y + 10, 200, 5, Blitbuffer.COLOR_BLACK)

    -- Draw a circle (filled)
    bb:paintCircle(x + 100, y + 100, 40, Blitbuffer.COLOR_BLACK)
end
```

---

## 14. reMarkable 2 constraints & gotchas

### RM2FB shim requirement

The reMarkable 2 uses a non-standard framebuffer. KOReader requires `RM2FB_SHIM` to be set. The stock launch script (`koreader.sh`) handles this; plugins do not need to do anything.

### No colour

All `Blitbuffer` colour values must be greyscale:
- `Blitbuffer.COLOR_WHITE` â€” `0xFF`
- `Blitbuffer.COLOR_BLACK` â€” `0x00`
- `Blitbuffer.gray(n)` â€” where n is 0â€“15 (0 = black, 15 = white)

### E-ink refresh discipline

- Call `UIManager:show(widget, "partial")` for incremental updates.
- Call `UIManager:show(widget, "full")` only when the whole screen changes (e.g., opening a new full-screen view). Full refreshes cause a visible flash.
- Never call `setDirty` in a tight loop. Batch updates.

### Performance

- The CPU is slow (1 GHz single-core effective for LuaJIT work). Keep UI event handlers fast (<10 ms ideally).
- Avoid table allocations in hot paths (e.g., inside gesture handlers called at 60 Hz).
- LuaJIT''s JIT compiler is available, but cold-start for new code paths can be slow.

### Filesystem paths

```lua
local DataStorage = require("datastorage")
DataStorage:getDataDir()      -- /home/root/koreader  (settings, databases)
DataStorage:getFullDataDir()  -- same, resolved symlinks
-- self.path is set by PluginLoader to your .koplugin directory:
-- e.g. /home/root/koreader/plugins/myplugin.koplugin
```

### Network

Wi-Fi is available but may be disabled. Check:
```lua
if Device:hasWifiManager() then
    -- Device:enableWifi() / Device:disableWifi() if KO_DONT_MANAGE_NETWORK not set
end
```

### LuaJIT / Lua version

KOReader uses LuaJIT 2.1 (Lua 5.1 semantics + some 5.2 extensions). Key differences from Lua 5.3+:
- No integer division operator `//`
- No bitwise operators `&`, `|`, `~` (use `bit.band`, `bit.bor`, `bit.bnot` from the `bit` library)
- `string.format` does not support `%q` for all types

---

## 15. Checklist for a new plugin

- [ ] Directory name ends in `.koplugin`
- [ ] `_meta.lua` returns `{ fullname, description }` with no heavy requires
- [ ] `main.lua` returns the plugin table (not `nil`)
- [ ] Plugin table has `name`, `fullname`, `description` fields
- [ ] `init()` calls `self.ui.menu:registerToMainMenu(self)` if you want a menu entry
- [ ] `addToMainMenu(menu_items)` sets `menu_items.<unique_key>`
- [ ] All user-visible strings wrapped in `_()`
- [ ] Settings keys prefixed with plugin name
- [ ] No `require` calls at module load time that could fail on non-reMarkable targets (guard with `pcall` if needed)
- [ ] Tested by restarting KOReader after deploy (not just re-opening a doc)
- [ ] Crash log checked after first run: `tail /home/root/koreader/crash.log`

---

## Useful KOReader source paths (for reference)

```
frontend/ui/uimanager.lua            UIManager implementation
frontend/ui/widget/                  All built-in widgets
frontend/ui/widget/container/        Container widgets (Frame, Center, Inputâ€¦)
frontend/device/remarkable/device.lua  reMarkable device driver
frontend/device/screen.lua           Screen API
plugins/                             Built-in plugin examples (read these!)
  goodreads.koplugin/
  SSH.koplugin/
  newsdownloader.koplugin/
```

The built-in plugins are the best real-world examples of correct plugin patterns.

---

*Template version: 1.0 â€” compatible with KOReader 2023.x and later on reMarkable 2.*

---

## 16. Reusable components

The `components/` directory contains ready-to-use modules. Copy the entire `components/` directory into your `.koplugin` directory at deploy time, then require relative to the plugin root (which KOReader''s PluginLoader puts on `package.path`):

```lua
local WiFi    = require("components/wifi/wifi")
local Dropbox = require("components/dropbox/dropbox")
```

### Component index

| Directory | Module | What it does |
|---|---|---|
| `components/wifi/` | `wifi.lua` | WiFi status, `whenOnline()` guard, menu toggle item |
| `components/http/` | `http.lua` | GET, POST, JSON, file download/upload with timeouts |
| `components/dropbox/` | `dropbox.lua` | Dropbox v2 API: list, download, upload, delete |
| `components/webdav/` | `webdav.lua` | WebDAV: list, download, upload, delete, MKCOL |
| `components/webdav/` | `SHAREPOINT.md` | Notes on SharePoint (see Â§17 Roadmap) |
| `components/credentials/` | `credentials.lua` | MultiInputDialog wrappers for Dropbox and WebDAV credential entry |
| `components/progress/` | `progress.lua` | Progress bar dialog wrapper with async helper |
| `components/settings-screen/` | `settings_screen.lua` | Generic settings screen (toggle, input, number, select, action) |
| `components/text-viewer/` | `text_viewer.lua` | Wrapper around KOReader''s native `TextViewer` widget |
| `components/file-browser/` | `file_browser.lua` | Local folder/file picker; remote listing helper |
| `components/kv-page/` | `kv_page.lua` | Paginated key/value display (status, metadata, debug info) |

---

### WiFi

```lua
local WiFi = require("components/wifi/wifi")

WiFi:whenOnline(function()  -- ensure connected before HTTP
    myApi:fetchData()
end)

if WiFi:isConnected() then ... end

menu_items.wifi_toggle = WiFi:getMenuEntry()  -- nil on non-togglable platforms
```

---

### HTTP

```lua
local Http = require("components/http/http")

local body, code = Http.get("https://api.example.com/data", {
    ["Authorization"] = "Bearer " .. token,
})

local body, code = Http.postJSON("https://api.example.com/items",
    { name = "test" },
    { ["Authorization"] = "Bearer " .. token }
)

local ok, data = Http.parseJSON(body)

local code = Http.download("https://example.com/file.pdf", "/tmp/file.pdf",
    { ["Authorization"] = "Bearer " .. token },
    function(bytes) dlg:update(bytes) end)
```

---

### Dropbox

Requires a Dropbox app (app key + secret) and a pre-generated refresh token. Tokens are long-lived; generate once on a computer.

```lua
local Dropbox = require("components/dropbox/dropbox")

local db = Dropbox:new{
    app_key       = "...",
    app_secret    = "...",
    refresh_token = "...",
}

WiFi:whenOnline(function()
    local items = db:listFolder("/Papers")
    -- items[i] = { name, path, is_folder, size, modified }

    db:downloadFile("/Papers/doc.pdf", "/tmp/doc.pdf",
        function(bytes) dlg:update(bytes) end)

    db:uploadFile("/tmp/notes.txt", "/Papers/notes.txt")
end)
```

**Getting a refresh token (one-time, on a computer):**
```bash
# 1. Visit in a browser:
#    https://www.dropbox.com/oauth2/authorize?client_id=APP_KEY&response_type=code&token_access_type=offline
# 2. Exchange the auth code:
curl -X POST https://api.dropbox.com/oauth2/token \
  -u "APP_KEY:APP_SECRET" \
  -d "code=AUTH_CODE&grant_type=authorization_code"
# Save the refresh_token field.
```

---

### WebDAV

Works with Nextcloud, ownCloud, Synology DSM, Apache/Nginx with mod_dav, and on-premise SharePoint (older/on-prem only). **Not** compatible with SharePoint Online (Microsoft 365) â€” see Â§17.

```lua
local WebDAV = require("components/webdav/webdav")

local dav = WebDAV:new{
    address  = "https://nextcloud.example.com/remote.php/dav/files/alice",
    username = "alice",
    password = "secret",
}

WiFi:whenOnline(function()
    local items = dav:listFolder("/Documents")
    dav:downloadFile("/Documents/notes.pdf", "/tmp/notes.pdf")
    dav:uploadFile("/tmp/notes.pdf", "/Documents/notes.pdf")
end)
```

---

### Credentials

Uses `MultiInputDialog` (KOReader''s native multi-field input widget) for credential entry. Preferable to multiple separate `InputDialog` calls for multi-field forms.

```lua
local Credentials = require("components/credentials/credentials")

-- Dropbox setup screen
Credentials.showDropbox({
    app_key       = G_reader_settings:readSetting("myplugin_db_key"),
    app_secret    = G_reader_settings:readSetting("myplugin_db_secret"),
    refresh_token = G_reader_settings:readSetting("myplugin_db_token"),
    on_save = function(v)
        G_reader_settings:saveSetting("myplugin_db_key",    v.app_key)
        G_reader_settings:saveSetting("myplugin_db_secret", v.app_secret)
        G_reader_settings:saveSetting("myplugin_db_token",  v.refresh_token)
    end,
})

-- WebDAV setup screen
Credentials.showWebDAV({
    address = G_reader_settings:readSetting("myplugin_dav_addr"),
    username = G_reader_settings:readSetting("myplugin_dav_user"),
    password = G_reader_settings:readSetting("myplugin_dav_pass"),
    on_save = function(v) ... end,
})

-- Generic (custom fields)
Credentials.show({
    title  = "API Settings",
    fields = {
        { label = "API key", key = "api_key", hint = "sk-â€¦", password = true },
        { label = "Endpoint", key = "endpoint", hint = "https://â€¦" },
    },
    values  = { api_key = "â€¦", endpoint = "â€¦" },
    on_save = function(v) ... end,
})
```

---

### Progress

```lua
local Progress = require("components/progress/progress")

-- Manual handle:
local dlg = Progress.show("Downloadingâ€¦", "notes.pdf", file_size_bytes)
db:downloadFile(path, local_path, function(b) dlg:update(b) end)
dlg:close()

-- All-in-one async (schedules work on next tick so dialog renders first):
Progress.run("Syncingâ€¦", "notes.pdf", file_size, function(report, done)
    db:downloadFile(path, local_path, report)
    done()
end, function()
    UIManager:show(InfoMessage:new{ text = _("Done!") })
end)
```

Note: if `max` (file_size) is `nil`, `ProgressbarDialog` hides the bar but still requires at least `title` or `subtitle` â€” passing both is safest.

---

### Settings screen

```lua
local SettingsScreen = require("components/settings-screen/settings_screen")

UIManager:show(SettingsScreen:new{
    title = "My Plugin Settings",
    items = {
        { type = "heading", label = "Account" },
        { type = "input",   label = "Token",     key = "myplugin_token",
          password = true,  default = "" },
        { type = "toggle",  label = "Auto-sync", key = "myplugin_autosync",
          default = false },
        { type = "number",  label = "Timeout",   key = "myplugin_timeout",
          default = 30, min = 5, max = 300, step = 5, unit = "s" },
        { type = "select",  label = "Folder",    key = "myplugin_folder",
          options = {"/Documents", "/Papers"}, default = "/Documents" },
        { type = "action",  label = "Test connection",
          callback = function() ... end },
    },
})
```

The `select` type uses `RadioButtonWidget` (KOReader''s native single-select widget). The `number` type uses `SpinWidget`.

---

### Text viewer

Wrapper around KOReader''s native `TextViewer` widget, which includes `TitleBar`, `ScrollTextWidget`, built-in text search, and font size controls.

```lua
local TextViewer = require("components/text-viewer/text_viewer")

UIManager:show(TextViewer:new{
    title     = "Log output",
    text      = log_text,
    monospace = true,      -- maps to monospace_font = true in native widget
    font_size = 18,        -- maps to text_font_size
    on_close  = function() end,  -- maps to close_callback
    -- All native TextViewer fields also accepted directly
    justified = false,
    auto_para_direction = false,
})
```

For fullscreen display: `width = Screen:getWidth(), height = Screen:getHeight()`.

---

### File browser

```lua
local FileBrowser = require("components/file-browser/file_browser")

-- Pick a local download folder
FileBrowser.chooseFolder({
    initial_path = G_reader_settings:readSetting("myplugin_dir") or "/home/root",
    on_confirm   = function(path)
        G_reader_settings:saveSetting("myplugin_dir", path)
    end,
})

-- Build a Menu item_table from a cloud listing
local items = db:listFolder("/Papers")
local rows  = FileBrowser.buildRemoteItemTable(items,
    function(file_item)   -- file tapped
        Progress.run("Downloadingâ€¦", file_item.name, file_item.size,
            function(report, done)
                db:downloadFile(file_item.path, "/tmp/" .. file_item.name, report)
                done()
            end)
    end,
    function(folder_item)  -- folder tapped: navigate into it
        -- repopulate your menu with db:listFolder(folder_item.path)
    end
)
local menu = Menu:new{ title = "Papers", item_table = rows, ... }
UIManager:show(menu)
```

---

### Key/value page

Uses KOReader''s `KeyValuePage` â€” a paginated, tappable key/value list with `TitleBar`. Good for sync status, file metadata, settings summaries.

```lua
local KVPage = require("components/kv-page/kv_page")

KVPage.show({
    title = "Last sync",
    pairs = {
        { "Status",   "Success" },
        { "Files",    "12 downloaded, 3 uploaded" },
        { "Duration", "4.2 s" },
        "---",
        { "Last file", "notes.pdf", callback = function() openLastFile() end },
    },
})

-- Build pairs from a table (e.g. for debug/status display):
local pairs = KVPage.fromTable(my_status_table, "Network status")
KVPage.show({ title = "Debug", pairs = pairs })
```

---

## 17. Roadmap

### SharePoint Online (Microsoft 365)

SharePoint Online does not support WebDAV. The reliable path is the **Microsoft Graph API** with OAuth2 device-code flow â€” workable on the reMarkable 2 but requires an Azure app registration outside the device.

Planned component: `components/sharepoint/` â€” Microsoft Graph API client covering folder listing, file download, and file upload. Will reuse `components/http/http.lua` and `components/wifi/wifi.lua`.

Pre-requisites (one-time setup, outside the device):
1. Azure Active Directory â†’ App registrations â†’ new registration (Mobile/desktop platform)
2. Add `Files.ReadWrite` + `offline_access` Graph permissions
3. Run device-code OAuth2 flow to obtain a refresh token
4. Store `tenant_id`, `client_id`, and `refresh_token` in plugin settings

See `components/webdav/SHAREPOINT.md` for a detailed setup walkthrough that can serve as the basis for building this component.
