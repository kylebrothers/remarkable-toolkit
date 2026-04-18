--[[
components/progress/progress.lua
---------------------------------
Wrapper around KOReader''s ProgressbarDialog that makes the common
"show dialog â†’ do async work â†’ close dialog" pattern a one-liner.

USAGE
-----
    local Progress = require("components/progress/progress")

    -- Show a progress bar for a download:
    local dlg = Progress.show("Downloadingâ€¦", "notes.pdf", file_size_bytes)

    local ok = someApi:downloadFile(url, local_path, function(bytes)
        dlg:update(bytes)
    end)

    dlg:close()

    -- Or use the all-in-one async helper (runs callback on next tick):
    Progress.run(
        "Downloadingâ€¦",           -- title
        "notes.pdf",              -- subtitle
        file_size_bytes,          -- nil = indeterminate
        function(report, done)    -- work callback
            someApi:downloadFile(url, local_path, function(bytes)
                report(bytes)     -- update bar
            end)
            done()                -- signal completion
        end,
        function(success)         -- completion callback
            if success then UIManager:show(InfoMessage:new{ text = "Done!" }) end
        end
    )

ADAPTED FROM
------------
KOReader: frontend/ui/widget/progressbardialog.lua
          plugins/cloudstorage.koplugin/cloudstorage.lua  (download pattern)
--]]

local ProgressbarDialog = require("ui/widget/progressbardialog")
local UIManager         = require("ui/uimanager")
local logger            = require("logger")
local _                 = require("gettext")

local Progress = {}

-- â”€â”€ Handle object returned by Progress.show() â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local Handle = {}
Handle.__index = Handle

--- Update the progress bar.
-- @tparam number value  Bytes / units received so far.
function Handle:update(value)
    if self._dlg and not self._closed then
        self._dlg:reportProgress(value)
    end
end

--- Set a new subtitle line (e.g. current filename in a multi-file operation).
function Handle:setSubtitle(text)
    if self._dlg and not self._closed then
        -- ProgressbarDialog exposes setTitle for the main title; subtitle is set at creation.
        -- We re-use the title slot if subtitle update is needed.
        self._dlg:setTitle(self._title .. "\n" .. text)
    end
end

--- Close / dismiss the progress dialog.
function Handle:close()
    if not self._closed then
        self._closed = true
        if self._dlg then
            self._dlg:close()
            self._dlg = nil
        end
    end
end

-- â”€â”€ Public API â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

--- Show a progress dialog immediately and return a handle.
-- @tparam string   title     Main heading line.
-- @tparam string   subtitle  Secondary line (e.g. filename). Optional.
-- @tparam number   max       Total units (bytes). nil = indeterminate spinner.
-- @treturn Handle
function Progress.show(title, subtitle, max)
    local dlg = ProgressbarDialog:new{
        title        = title or _("Please waitâ€¦"),
        subtitle     = subtitle or "",
        progress_max = max,
    }
    dlg:show()
    UIManager:forceRePaint()

    local handle = setmetatable({
        _dlg    = dlg,
        _title  = title or _("Please waitâ€¦"),
        _closed = false,
    }, Handle)
    return handle
end

--- All-in-one: show dialog, run work function asynchronously, then close.
--
-- The work function receives (report_fn, done_fn):
--   report_fn(value)  â€” update the bar with the current progress value
--   done_fn()         â€” call when work is complete (closes the dialog)
--
-- The completion callback receives (true) always (error handling is the
-- caller''s responsibility inside the work function).
--
-- @tparam string   title
-- @tparam string   subtitle
-- @tparam number   max          nil = indeterminate
-- @tparam function work_fn      function(report, done)
-- @tparam function complete_fn  function()  called after dialog closes
function Progress.run(title, subtitle, max, work_fn, complete_fn)
    local handle = Progress.show(title, subtitle, max)

    -- Schedule work on the next UI tick so the dialog can render first
    UIManager:scheduleIn(0.05, function()
        local done_called = false
        local function done()
            if not done_called then
                done_called = true
                handle:close()
                if complete_fn then
                    complete_fn()
                end
            end
        end
        local function report(value)
            handle:update(value)
        end

        local ok, err = pcall(work_fn, report, done)
        if not ok then
            logger.err("Progress.run: work_fn error:", err)
            done()
        end
        -- If work_fn is synchronous and didn''t call done(), call it now
        if not done_called then
            done()
        end
    end)
end

return Progress
