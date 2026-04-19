--[[
components/canvas/canvas.lua
-----------------------------
Stylus drawing canvas for the reMarkable 2.

ARCHITECTURE
------------
This module bypasses KOReader's gesture recogniser entirely and reads the
Wacom digitizer directly from /dev/input/event1. This is the same approach
used by harmony (the reMarkable drawing app) and is necessary because:

  1. KOReader's gesture system fires events at most ~10 Hz and was designed
     for UI navigation, not continuous drawing.
  2. The Wacom digitizer produces events at ~200 Hz with sub-pixel precision
     and pressure data that the gesture layer discards.
  3. Pen-up detection via the gesture layer is unreliable, causing ghost lines
     between separate strokes. The raw BTN_TOUCH=0 event is authoritative.

INPUT EVENT FORMAT
------------------
Linux input events are 16-byte structs:
  [0..7]   timeval  (8 bytes, ignored)
  [8..9]   type     (uint16)
  [10..11] code     (uint16)
  [12..15] value    (int32)

Relevant events from the Wacom digitizer (event1 on rM2):
  EV_KEY  / BTN_TOUCH (330)  value=1 pen down, value=0 pen up
  EV_ABS  / ABS_X     (0)    X coordinate, range 0–20967
  EV_ABS  / ABS_Y     (1)    Y coordinate, range 0–15725
  EV_ABS  / ABS_PRESSURE(24) Pressure,     range 0–4095
  EV_SYN  / SYN_REPORT(0)    Marks end of one logical event packet

COORDINATE MAPPING
------------------
The Wacom digitizer uses its own coordinate space (20967×15725) which is
rotated relative to the screen (1404×1872, portrait). The mapping is:

  screen_x = wacom_x * SCREEN_W / WACOM_MAX_X
  screen_y = wacom_y * SCREEN_H / WACOM_MAX_Y

RENDERING
---------
Strokes are painted into a private BB8 (greyscale) blitbuffer that mirrors
the canvas region on screen. After each SYN_REPORT that contains new stroke
data, the dirty region is blitted to the screen framebuffer and a "fast"
e-ink refresh is triggered on that region only. This keeps latency low while
avoiding full-screen flicker.

PRESSURE RESPONSE
-----------------
Stroke width is mapped from pressure using a simple curve:
  width = MIN_WIDTH + (MAX_WIDTH - MIN_WIDTH) * (pressure / MAX_PRESSURE) ^ PRESSURE_GAMMA

GAMMA < 1 gives a more responsive feel at light pressure (like a real pen).
GAMMA = 0.5 is a good starting point.

USAGE
-----
    local Canvas = require("components/canvas/canvas")

    local c = Canvas:new{
        screen_x = 0,              -- top-left of canvas on screen
        screen_y = toolbar_height,
        width    = Screen:getWidth(),
        height   = Screen:getHeight() - toolbar_height,
    }
    c:start()          -- opens /dev/input/event1 and begins polling

    -- later:
    local png_path, err = c:saveAsPNG("/tmp/canvas.png")
    c:clear()
    c:stop()           -- closes the input device

--]]

local Blitbuffer  = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device      = require("device")
local Geom        = require("ui/geometry")
local UIManager   = require("ui/uimanager")
local ffi         = require("ffi")
local logger      = require("logger")

local Screen = Device.screen

-- ── Linux input event FFI ────────────────────────────────────────────────────

ffi.cdef[[
    /* input_event (from linux/input.h) */
    struct rm_input_event {
        uint32_t tv_sec;
        uint32_t tv_usec;
        uint16_t type;
        uint16_t code;
        int32_t  value;
    };

    int open(const char *path, int flags);
    int close(int fd);
    ssize_t read(int fd, void *buf, size_t count);
]]

-- O_RDONLY and O_NONBLOCK as plain Lua constants (LuaJIT cdef doesn't accept
-- static const int; values are standard on ARM Linux / glibc)
local O_RDONLY   = 0
local O_NONBLOCK = 2048  -- 0x800

local INPUT_EVENT_SIZE = ffi.sizeof("struct rm_input_event")

-- ── Linux input event constants ──────────────────────────────────────────────

local EV_SYN      = 0x00
local EV_KEY      = 0x01
local EV_ABS      = 0x03
local SYN_REPORT  = 0x00
local BTN_TOUCH   = 0x014a   -- 330
local ABS_X       = 0x00
local ABS_Y       = 0x01
local ABS_PRESSURE = 0x18    -- 24

-- ── reMarkable 2 digitizer constants ─────────────────────────────────────────

local WACOM_MAX_X   = 20967
local WACOM_MAX_Y   = 15725
local WACOM_MAX_P   = 4095

-- ── Stroke rendering constants ────────────────────────────────────────────────

local MIN_WIDTH       = 1.5   -- px at zero pressure
local MAX_WIDTH       = 4.5   -- px at full pressure
local PRESSURE_GAMMA  = 0.5   -- <1 = more responsive at light pressure
local POLL_INTERVAL   = 0.005 -- 5 ms between read() calls (~200 Hz)

-- ── Canvas ────────────────────────────────────────────────────────────────────

local Canvas = {}
Canvas.__index = Canvas

--- Create a new Canvas instance.
-- @tparam table opts
--   screen_x  number  X position of canvas top-left on screen (default 0)
--   screen_y  number  Y position of canvas top-left on screen (default 0)
--   width     number  Canvas width in pixels (default full screen)
--   height    number  Canvas height in pixels (default full screen)
function Canvas:new(opts)
    local o = setmetatable({}, self)
    o.screen_x    = opts.screen_x or 0
    o.screen_y    = opts.screen_y or 0
    o.width       = opts.width    or Screen:getWidth()
    o.height      = opts.height   or Screen:getHeight()

    -- Backbuffer: holds all strokes painted so far.
    o._bb = Blitbuffer.new(o.width, o.height, Blitbuffer.TYPE_BB8)
    o._bb:fill(Blitbuffer.COLOR_WHITE)

    -- Input state
    o._fd          = nil      -- file descriptor for /dev/input/event1
    o._running     = false
    o._pen_down    = false
    o._last_sx     = nil      -- last screen-space X
    o._last_sy     = nil      -- last screen-space Y
    o._last_width  = nil      -- stroke width at last point

    -- Pending event packet (accumulated between SYN_REPORTs)
    o._pkt_x       = nil
    o._pkt_y       = nil
    o._pkt_pressure = 0

    -- Dirty rect tracking (reset each SYN cycle)
    o._dirty_x1    = math.huge
    o._dirty_y1    = math.huge
    o._dirty_x2    = -math.huge
    o._dirty_y2    = -math.huge

    o.has_content  = false

    -- Pre-bind poll callback for stable unschedule
    o._poll_cb = function() o:_poll() end

    -- Reusable FFI event buffer
    o._ev = ffi.new("struct rm_input_event")

    return o
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open the Wacom input device and begin reading events.
-- Safe to call multiple times (no-op if already running).
function Canvas:start()
    if self._running then return end

    local dev_path = self:_detectInputDevice()
    if not dev_path then
        logger.warn("Canvas: could not detect Wacom input device")
        return
    end

    local fd = ffi.C.open(dev_path, O_RDONLY + O_NONBLOCK)
    if fd < 0 then
        logger.warn("Canvas: failed to open", dev_path)
        return
    end

    self._fd      = fd
    self._running = true
    logger.dbg("Canvas: opened", dev_path, "fd=", fd)

    UIManager:scheduleIn(POLL_INTERVAL, self._poll_cb)
end

--- Stop reading events and close the input device.
function Canvas:stop()
    if not self._running then return end
    self._running = false
    UIManager:unschedule(self._poll_cb)
    if self._fd then
        ffi.C.close(self._fd)
        self._fd = nil
    end
    logger.dbg("Canvas: stopped")
end

--- Clear the canvas to white.
function Canvas:clear()
    self._bb:fill(Blitbuffer.COLOR_WHITE)
    self.has_content = false
    self._pen_down   = false
    self._last_sx    = nil
    self._last_sy    = nil

    -- Full repaint of canvas region
    UIManager:setDirty("all", function()
        return "ui", Geom:new{
            x = self.screen_x,
            y = self.screen_y,
            w = self.width,
            h = self.height,
        }
    end)
end

--- Save the canvas contents as a PNG file.
-- @tparam  string path  Destination file path.
-- @treturn string|nil   Path on success, nil on failure.
-- @treturn string|nil   Error message on failure.
function Canvas:saveAsPNG(path)
    -- Ensure directory exists
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
    end
    local ok, err = pcall(self._bb.writePNG, self._bb, path)
    if not ok then
        return nil, "Canvas.saveAsPNG failed: " .. tostring(err)
    end
    return path, nil
end

--- Called by the KOReader widget system to composite the canvas into a
--- parent blitbuffer (e.g. during a full screen refresh).
-- @tparam  Blitbuffer bb   Target buffer.
-- @tparam  number     x    Destination X.
-- @tparam  number     y    Destination Y.
function Canvas:paintTo(bb, x, y)
    bb:blitFrom(self._bb, x + self.screen_x, y + self.screen_y,
                0, 0, self.width, self.height)
end

-- ── Input device detection ────────────────────────────────────────────────────

function Canvas:_detectInputDevice()
    -- Read machine name to distinguish rM1 vs rM2
    local f = io.open("/sys/devices/soc0/machine", "r")
    if f then
        local machine = f:read("*l") or ""
        f:close()
        if machine:find("reMarkable 2") then
            return "/dev/input/event1"
        elseif machine:find("reMarkable") then
            return "/dev/input/event0"
        end
    end
    -- Default: try event1 (rM2 is more common target)
    logger.warn("Canvas: machine name unreadable, defaulting to event1")
    return "/dev/input/event1"
end

-- ── Poll loop ─────────────────────────────────────────────────────────────────

function Canvas:_poll()
    if not self._running then return end

    -- Drain all available events (non-blocking)
    local count = 0
    while true do
        local n = ffi.C.read(self._fd, self._ev, INPUT_EVENT_SIZE)
        if n < INPUT_EVENT_SIZE then break end  -- EAGAIN or error: no more events
        self:_handleEvent(self._ev)
        count = count + 1
        if count > 256 then break end  -- safety: don't hog CPU
    end

    UIManager:scheduleIn(POLL_INTERVAL, self._poll_cb)
end

-- ── Event dispatch ────────────────────────────────────────────────────────────

function Canvas:_handleEvent(ev)
    local t = ev.type
    local c = ev.code
    local v = ev.value

    if t == EV_SYN and c == SYN_REPORT then
        self:_flushPacket()

    elseif t == EV_KEY and c == BTN_TOUCH then
        if v == 1 then
            self._pen_down   = true
            self._last_sx    = nil   -- start of a new stroke
            self._last_sy    = nil
            self._last_width = nil
        else
            -- Pen up: end stroke, clear last position so next stroke is
            -- a fresh start with no connecting line
            self._pen_down   = false
            self._last_sx    = nil
            self._last_sy    = nil
            self._last_width = nil
        end

    elseif t == EV_ABS then
        if     c == ABS_X        then self._pkt_x        = v
        elseif c == ABS_Y        then self._pkt_y        = v
        elseif c == ABS_PRESSURE then self._pkt_pressure = v
        end
    end
end

-- ── Packet flush (called on SYN_REPORT) ──────────────────────────────────────

function Canvas:_flushPacket()
    if not self._pen_down then return end
    if not self._pkt_x or not self._pkt_y then return end

    -- Map Wacom coordinates to screen coordinates
    local sx = math.floor(self._pkt_x * self.width  / WACOM_MAX_X)
    local sy = math.floor(self._pkt_y * self.height / WACOM_MAX_Y)
    sx = math.max(0, math.min(sx, self.width  - 1))
    sy = math.max(0, math.min(sy, self.height - 1))

    -- Pressure → stroke width
    local p = math.max(0, math.min(self._pkt_pressure, WACOM_MAX_P))
    local t = (p / WACOM_MAX_P) ^ PRESSURE_GAMMA
    local width = MIN_WIDTH + (MAX_WIDTH - MIN_WIDTH) * t
    local iwidth = math.max(1, math.floor(width + 0.5))

    if self._last_sx and self._last_sy then
        -- Interpolate width along the segment for a tapered feel
        self:_paintSegment(self._last_sx, self._last_sy, self._last_width or iwidth,
                           sx, sy, iwidth)
    else
        self:_paintDot(sx, sy, iwidth)
    end
    self._last_sx    = sx
    self._last_sy    = sy
    self._last_width = iwidth
    self.has_content = true

    -- Accumulate dirty rect
    local margin = iwidth + 2
    if sx - margin < self._dirty_x1 then self._dirty_x1 = sx - margin end
    if sy - margin < self._dirty_y1 then self._dirty_y1 = sy - margin end
    if sx + margin > self._dirty_x2 then self._dirty_x2 = sx + margin end
    if sy + margin > self._dirty_y2 then self._dirty_y2 = sy + margin end

    -- Flush dirty region to screen every packet (each SYN_REPORT = ~5 ms)
    self:_flushToScreen()
end

-- ── Stroke rendering ──────────────────────────────────────────────────────────

function Canvas:_paintDot(x, y, width)
    local r = math.floor(width / 2)
    self._bb:paintRect(
        math.max(0, x - r),
        math.max(0, y - r),
        width, width,
        Blitbuffer.COLOR_BLACK
    )
end

-- Bresenham segment with per-pixel width interpolation.
-- w0 = width at (x0,y0), w1 = width at (x1,y1).
function Canvas:_paintSegment(x0, y0, w0, x1, y1, w1)
    local dx  = math.abs(x1 - x0)
    local dy  = math.abs(y1 - y0)
    local sx  = x0 < x1 and 1 or -1
    local sy  = y0 < y1 and 1 or -1
    local err = dx - dy
    local steps = math.max(dx, dy)
    if steps == 0 then
        self:_paintDot(x0, y0, w0)
        return
    end

    local step = 0
    while true do
        -- Interpolate width
        local t = step / steps
        local w = math.max(1, math.floor(w0 + (w1 - w0) * t + 0.5))
        self:_paintDot(x0, y0, w)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x0 = x0 + sx end
        if e2 <  dx then err = err + dx; y0 = y0 + sy end
        step = step + 1
    end
end

-- ── Screen update ─────────────────────────────────────────────────────────────

function Canvas:_flushToScreen()
    if self._dirty_x1 >= self._dirty_x2 then return end  -- nothing to flush

    -- Clamp to canvas bounds
    local x = math.max(0, math.floor(self._dirty_x1))
    local y = math.max(0, math.floor(self._dirty_y1))
    local x2 = math.min(self.width,  math.ceil(self._dirty_x2))
    local y2 = math.min(self.height, math.ceil(self._dirty_y2))
    local w = x2 - x
    local h = y2 - y
    if w <= 0 or h <= 0 then return end

    -- Blit our backbuffer region into the screen framebuffer directly.
    -- Screen:getCanvas() returns the live framebuffer blitbuffer.
    local fb = Screen:getCanvas()
    if fb then
        fb:blitFrom(self._bb,
            self.screen_x + x,
            self.screen_y + y,
            x, y, w, h)
        Screen:refreshFast(
            self.screen_x + x,
            self.screen_y + y,
            w, h)
    end

    -- Reset dirty rect
    self._dirty_x1 = math.huge
    self._dirty_y1 = math.huge
    self._dirty_x2 = -math.huge
    self._dirty_y2 = -math.huge
end

return Canvas
