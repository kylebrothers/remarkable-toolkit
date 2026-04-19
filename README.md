# remarkable-toolkit

A framework for building KOReader plugins on the reMarkable 2, with a
shared component library and a handwriting OCR test harness.

---

## What this is

KOReader plugins that run on the reMarkable 2 as standalone full-screen
apps, built on KOReader's Lua/UI framework. This repository provides:

- A **shared component library** (`components/`) covering networking,
  cloud storage, UI patterns, and AI-powered handwriting recognition
- A **plugin template** (`myplugin.koplugin/`) as a starting point
- An **OCR test plugin** (`ocrtest.koplugin/`) for validating the
  handwriting recognition pipeline before building apps that depend on it

---

## Quick start

See **[DEPLOYMENT.md](DEPLOYMENT.md)** for full setup instructions.

Short version:
```powershell
# Deploy to device (USB connected)
.\deploy.ps1

# Deploy over Wi-Fi
.\deploy.ps1 -Device 192.168.x.x
```

---

## Component library

All components live in `components/`. They are copied into each plugin
at deploy time by `deploy.ps1`.

| Component | Purpose |
|---|---|
| `ocr/` | Handwriting recognition — Gemini, OpenAI, Anthropic, Ollama |
| `http/` | HTTP GET/POST/download/upload with timeout handling |
| `wifi/` | WiFi status, `whenOnline()` guard, menu toggle |
| `credentials/` | Multi-field credential dialogs (Dropbox, WebDAV) |
| `dropbox/` | Dropbox v2 API: list, download, upload, delete |
| `webdav/` | WebDAV: list, download, upload (Nextcloud, Synology, etc.) |
| `progress/` | Progress bar dialog with async helper |
| `settings-screen/` | Generic settings screen (toggle, input, number, select) |
| `text-viewer/` | Wrapper around KOReader's native TextViewer widget |
| `file-browser/` | Local folder/file picker; remote listing helper |
| `kv-page/` | Paginated key/value display for status and metadata |

---

## OCR component

The OCR component supports four backends, configurable at runtime:

| Backend | Model | Notes |
|---|---|---|
| `gemini` | gemini-1.5-flash | Cheapest cloud option, free tier available |
| `openai` | gpt-4o | Highest accuracy, more expensive |
| `anthropic` | claude-3-5-haiku | Good balance of cost and accuracy |
| `ollama` | qwen2-vl:7b | Self-hosted, requires local server with GPU |

```lua
local OCR = require("components/ocr/ocr")

OCR.configure({
    backend = "gemini",
    api_key = "your-key-here",
})

OCR.recognize("/tmp/handwriting.png", function(text, err, elapsed_ms)
    if err then return end
    print(text, elapsed_ms)
end)
```

API keys:
- Gemini (free): https://aistudio.google.com/app/apikey
- OpenAI: https://platform.openai.com/api-keys
- Anthropic: https://console.anthropic.com/

---

## Architecture notes

### Plugin structure

Each plugin is a `.koplugin` directory containing:
```
myplugin.koplugin/
├── _meta.lua        # loaded even when disabled (name, description)
├── main.lua         # plugin entry point, returns plugin table
└── components/      # copy of shared library (added by deploy.ps1)
```

The `components/` copy inside each plugin is required by KOReader's
module loader, which resolves `require("components/x/y")` relative to
the plugin root.

### Module loading

```lua
-- In any plugin file, require components like this:
local OCR  = require("components/ocr/ocr")
local WiFi = require("components/wifi/wifi")
local Http = require("components/http/http")
```

### Plugin lifecycle

```lua
local MyPlugin = WidgetContainer:extend{
    name     = "myplugin",
    fullname = _("My Plugin"),
}

function MyPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    -- load settings, subscribe to events
end

function MyPlugin:addToMainMenu(menu_items)
    menu_items.myplugin = {
        text     = _("My Plugin"),
        callback = function() self:onOpen() end,
    }
end

return MyPlugin
```

---

## Device specifics (reMarkable 2)

| Property | Value |
|---|---|
| Screen | 1404 × 1872 px, 226 DPI, greyscale e-ink |
| CPU | ARM Cortex-A7, 1 GHz |
| RAM | 1 GB |
| Input | Wacom EMR stylus + capacitive touch |
| KOReader plugins path | `/home/root/xovi/exthome/appload/koreader/plugins/` |
| Stylus compatibility | Wacom EMR only (not Samsung S Pen) |

**E-ink refresh types** (use in `UIManager:show` and `setDirty`):

| Type | Use when |
|---|---|
| `"full"` | Opening a new full-screen view |
| `"ui"` | Standard UI element appeared/changed |
| `"partial"` | Small incremental update |
| `"fast"` | Stroke drawing, progress updates |

---

## Roadmap

- **SharePoint Online**: Microsoft Graph API client (OAuth2 device-code
  flow). Requires Azure app registration. See
  `components/webdav/SHAREPOINT.md` for setup guide.
- **Email triage**: IMAP client for reading and filing Outlook email
- **Dropbox auto-library**: monitor a folder and sync new documents automatically
- **Web article reader**: fetch and reflow web pages for reading
- **Meeting prep**: pull calendar events and related documents before meetings
- **Conference note-taker**: structured note capture synced to Dropbox/OneDrive

---

## Troubleshooting

See [DEPLOYMENT.md](DEPLOYMENT.md) for full troubleshooting guidance.

**Check crash log on device:**
```bash
tail -80 /home/root/xovi/exthome/appload/koreader/crash.log
```

**"module not found" error**: run `.\deploy.ps1` again — it copies
`components/` into each plugin automatically.

**Script execution blocked**: run these once in PowerShell:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\deploy.ps1
```
