# Deployment Guide

Complete instructions for deploying plugins to your reMarkable 2 and
iterating during development.

---

## Your device specifics

| Property | Value |
|---|---|
| KOReader plugins path | `/home/root/xovi/exthome/appload/koreader/plugins/` |
| Device IP (USB) | `10.11.99.1` |
| Device IP (Wi-Fi) | Shown in Settings → Help → Copyrights and licenses |
| SSH user | `root` |
| SSH password | Shown in Settings → Help → Copyrights and licenses (scroll to bottom) |

---

## Prerequisites

### On your Windows 11 machine
- **Git for Windows**: https://git-scm.com/download/win
  Install with all defaults. Choose "main" as default branch name.
- **OpenSSH**: already built into Windows 11 (no install needed)
- **WinSCP** (optional, for GUI file transfer): https://winscp.net

---

## Repository structure

Every plugin is self-contained. The `components/` shared library lives
**inside** each plugin directory, not alongside it. This is required by
KOReader's module loader.

```
remarkable-toolkit/
├── README.md
├── DEPLOYMENT.md
├── .gitignore
├── deploy.ps1                  ← run this to push to device
├── components/                 ← master copy of shared library
│   ├── ocr/ocr.lua
│   ├── http/http.lua
│   ├── wifi/wifi.lua
│   ├── credentials/credentials.lua
│   ├── dropbox/dropbox.lua
│   ├── webdav/webdav.lua
│   ├── progress/progress.lua
│   ├── settings-screen/settings_screen.lua
│   ├── text-viewer/text_viewer.lua
│   ├── file-browser/file_browser.lua
│   └── kv-page/kv_page.lua
├── myplugin.koplugin/          ← plugin template (rename for new apps)
│   ├── _meta.lua
│   ├── main.lua
│   ├── mywidget.lua
│   └── components/ → copy of shared library (deploy.ps1 handles this)
└── ocrtest.koplugin/           ← OCR test harness
    ├── _meta.lua
    ├── main.lua
    └── components/ → copy of shared library (deploy.ps1 handles this)
```

**Key rule:** when deploying, `deploy.ps1` copies `components/` into each
`.koplugin` directory automatically. You never manually manage this.

---

## First-time setup

### 1. Clone the repo

Open PowerShell:

```powershell
cd C:\Users\YourName\Documents
git clone https://github.com/YOURUSERNAME/remarkable-toolkit.git
cd remarkable-toolkit
```

### 2. Connect the reMarkable via USB-C

The device will be reachable at `10.11.99.1`.

Test the connection:

```powershell
ssh root@10.11.99.1
```

Enter the root password when prompted. Type `exit` to disconnect.

### 3. Run the deploy script

```powershell
.\deploy.ps1
```

If you get a script execution error, run this first (one time only):

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\deploy.ps1
```

Then run `.\deploy.ps1` again.

### 4. Restart KOReader on the device

On the reMarkable:
1. Swipe down from the top
2. Tap the icon in the top-right
3. Tap **Exit → Exit**
4. Relaunch KOReader

### 5. Enable the OCR Test plugin

1. In KOReader: **☰ → More tools → Plugin manager**
2. Find **OCR Test** → tap to enable
3. Restart when prompted

The plugin now appears under **☰ → More tools → OCR Test**.

---

## Configuring the OCR backend

Before converting handwriting you need an API key.

1. Open **☰ → More tools → OCR Test**
2. Tap **Settings**
3. Set **Backend** to `gemini` (recommended — cheapest, free tier available)
4. Enter your API key:
   - Gemini (free key): https://aistudio.google.com/app/apikey
   - OpenAI: https://platform.openai.com/api-keys
   - Anthropic: https://console.anthropic.com/
5. Leave **Model** blank to use the backend default
6. Close settings (triggers save)

---

## Using the OCR Test plugin

1. Open **☰ → More tools → OCR Test**
2. Write on the canvas with your stylus
3. Tap **Convert**
4. Wait 3–8 seconds
5. Result screen shows recognised text, backend name, and elapsed time
6. Tap **Clear** to start a new drawing

---

## Day-to-day development workflow

```powershell
# 1. Make changes to files in your local repo

# 2. Deploy to device (USB connected)
.\deploy.ps1

# 3. Restart KOReader on the device

# 4. Test

# 5. Commit and push to GitHub
git add .
git commit -m "Description of changes"
git push
```

### Deploying over Wi-Fi

Find your device's Wi-Fi IP in Settings → Help → Copyrights and licenses, then:

```powershell
.\deploy.ps1 -Device 192.168.x.x
```

### Deploying a single file quickly

```powershell
# Example: update only ocr.lua in the ocrtest plugin
scp components/ocr/ocr.lua root@10.11.99.1:/home/root/xovi/exthome/appload/koreader/plugins/ocrtest.koplugin/components/ocr/ocr.lua
```

---

## Adding a new plugin

1. Copy `myplugin.koplugin/` and rename it to `yourplugin.koplugin/`
2. Edit `_meta.lua` and `main.lua` — update name, fullname, description
3. Update the `$plugins` array in `deploy.ps1` to include `yourplugin.koplugin`
4. Run `.\deploy.ps1` to deploy
5. Enable in KOReader Plugin Manager

---

## Troubleshooting

### Plugin doesn't appear in Plugin Manager

Check the structure on the device:

```bash
ls /home/root/xovi/exthome/appload/koreader/plugins/ocrtest.koplugin/
# Should show: _meta.lua  main.lua  components/

ls /home/root/xovi/exthome/appload/koreader/plugins/ocrtest.koplugin/components/ocr/
# Should show: ocr.lua
```

### "module not found" error

The `components/` directory is missing from inside the plugin. Run `deploy.ps1`
again — it copies components into each plugin automatically.

### Check crash log for Lua errors

```bash
tail -80 /home/root/xovi/exthome/appload/koreader/crash.log
```

Lua errors appear as `WARN Error when loading plugins/...` with a stack trace.

### "OCR not configured" message

Go to Settings in the plugin and re-enter your API key.

### HTTP 401 / 403 errors

API key is incorrect or not yet activated. Double-check the key on the
provider's website.

### Strokes not appearing on canvas

This may be a gesture threshold issue on your specific firmware. Check the
crash log for input-related errors and report them.

---

## SSH quick reference

```bash
# Connect
ssh root@10.11.99.1

# Check plugin loaded correctly
tail -80 /home/root/xovi/exthome/appload/koreader/crash.log

# List plugins
ls /home/root/xovi/exthome/appload/koreader/plugins/

# Restart KOReader from SSH
systemctl restart koreader
```
