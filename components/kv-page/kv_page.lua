--[[
components/kv-page/kv_page.lua
-------------------------------
Thin wrapper around KOReader''s KeyValuePage widget.

KeyValuePage displays a paginated list of key/value pairs with a TitleBar.
It is ideal for: sync status, file metadata, debug info, statistics, and
any situation where you want to show labelled data without a custom widget.

Features (built into the native widget):
  â€¢ Paginated display (swipe east/west to navigate pages)
  â€¢ Tappable rows with optional callbacks and hold-callbacks
  â€¢ Horizontal separator lines (use "---" as an entry)
  â€¢ Values can overflow with a tap-to-expand TextViewer
  â€¢ TitleBar with optional return/back button

USAGE
-----
    local KVPage = require("components/kv-page/kv_page")

    -- Simple display:
    KVPage.show({
        title = "File info",
        pairs = {
            { "Filename",  "notes.pdf" },
            { "Size",      "1.2 MB" },
            { "Modified",  "2024-03-15" },
            "---",   -- separator line
            { "Status", "Synced", callback = function() ... end },
        },
    })

    -- With a close callback:
    KVPage.show({
        title         = "Sync status",
        pairs         = build_status_pairs(),
        close_callback = function() myPlugin:onStatusClosed() end,
    })

PAIR FORMAT
-----------
Each entry in opts.pairs is either:
  â€¢ A string of dashes "---" or "â”€â”€â”€â”€â”€â”€" â†’ horizontal separator
  â€¢ A two-element array {key_string, value_string}
    Optional extra fields:
      callback       function  Called when the row is tapped
      hold_callback  function  Called when the row is held
      value_lang     string    Language tag for the value (e.g. "zh")
      separator      bool      Draw a line below this item

ADAPTED FROM
------------
KOReader: frontend/ui/widget/keyvaluepage.lua
--]]

local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager    = require("ui/uimanager")

local KVPage = {}

--- Show a KeyValuePage.
-- @tparam table opts
--   opts.title          string   Page title
--   opts.pairs          table    Array of pair entries (see PAIR FORMAT above)
--   opts.close_callback function Called when the page is closed (optional)
--   opts.items_per_page number   Rows per page (default: KOReader''s default, ~10)
--   opts.single_page    bool     If true, show all items on one page (scrollable)
function KVPage.show(opts)
    opts = opts or {}

    -- Normalise: convert plain string separators and array-form pairs
    -- into the kv_pairs format KeyValuePage expects
    local kv_pairs = {}
    for _, entry in ipairs(opts.pairs or {}) do
        if type(entry) == "string" then
            -- String â†’ separator line (any string works; dashes look cleanest)
            table.insert(kv_pairs, entry)
        elseif type(entry) == "table" then
            -- {key, value, callback=â€¦, hold_callback=â€¦, separator=â€¦}
            local item = { entry[1], entry[2] }
            if entry.callback      then item.callback      = entry.callback end
            if entry.hold_callback then item.hold_callback = entry.hold_callback end
            if entry.value_lang    then item.value_lang    = entry.value_lang end
            if entry.separator     then item.separator     = entry.separator end
            table.insert(kv_pairs, item)
        end
    end

    local page = KeyValuePage:new{
        title          = opts.title or "",
        kv_pairs       = kv_pairs,
        close_callback = opts.close_callback,
        items_per_page = opts.items_per_page,
        -- single_page: not a native field â€” KeyValuePage auto-paginates,
        -- but you can compute items_per_page = #kv_pairs to get one page.
    }
    if opts.single_page then
        page.items_per_page = math.max(#kv_pairs, 1)
    end
    UIManager:show(page)
    return page
end

--- Build a kv_pairs array from a flat Lua table (useful for debug/status display).
-- Keys are sorted alphabetically. Values are tostring''d.
-- @tparam  table  t      Source table
-- @tparam  string title  Optional section heading inserted at top
-- @treturn table  kv_pairs array
function KVPage.fromTable(t, title)
    local pairs_list = {}
    if title then
        table.insert(pairs_list, "â”€â”€ " .. title .. " â”€â”€")
    end
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        table.insert(pairs_list, { tostring(k), tostring(t[k]) })
    end
    return pairs_list
end

return KVPage
