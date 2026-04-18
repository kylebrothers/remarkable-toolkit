# Deployment Guide

Step-by-step instructions for getting the template and OCR test plugin
onto your reMarkable 2 for the first time, and for iterating afterward.

---

## Prerequisites

### On your Windows machine
- **WinSCP** (free, recommended) or any SCP/SFTP client
  Download: https://winscp.net
- **PuTTY** (free) for SSH access
  Download: https://putty.org
- Alternatively, **Windows Terminal** with OpenSSH (built into Windows 11)
  â€” no extra download needed

### On your reMarkable 2
- KOReader must already be installed
  If not: https://github.com/koreader/koreader/wiki/Installation-on-Remarkable
- The device must be connected to your computer via USB-C **or** on the same Wi-Fi network

---

## Step 1 â€” Find your device''s IP address and password

### USB connection (recommended for first setup)
1. Connect the reMarkable to your computer with the USB-C cable
2. The device IP over USB is always **10.11.99.1**

### Wi-Fi connection
1. On the reMarkable: **Settings â†’ Help â†’ Copyrights and licenses**
2. Scroll all the way down on the right panel
3. You will see the device''s **IP address** and **root password**
   (The password looks like a short random word, e.g. `AbCd1234`)

> **Note:** Write down the root password â€” you''ll need it every time you connect.
> It does not change unless you factory reset the device.

---

## Step 2 â€” Connect via SSH/SFTP

### Option A: Windows Terminal (built-in, no extra software)

Open Windows Terminal (or PowerShell) and test the connection:

```powershell
ssh root@10.11.99.1
```

When prompted for the password, enter the root password from Step 1.
Type `exit` when done.

### Option B: PuTTY + WinSCP (easier for file transfer)

**PuTTY (SSH terminal):**
1. Open PuTTY
2. Host Name: `10.11.99.1` (or Wi-Fi IP)
3. Port: `22`, Connection type: SSH
4. Click Open â†’ enter root password when prompted

**WinSCP (file transfer):**
1. Open WinSCP
2. File protocol: **SCP**
3. Host name: `10.11.99.1`
4. User name: `root`
5. Password: your root password
6. Click Login

---

## Step 3 â€” Find your KOReader plugins directory

Once connected via SSH or WinSCP, navigate to:

```
/home/root/koreader/plugins/
```

This is where all `.koplugin` directories live. You can verify KOReader
is installed by checking this path exists.

> If KOReader was installed differently on your device the path might be
> `/home/root/.adds/koreader/plugins/` â€” check both if the first doesn''t exist.

---

## Step 4 â€” Transfer the files

You need to copy two things to the device:

| What | From (your computer) | To (reMarkable) |
|---|---|---|
| `components/` directory | `remarkable2-koplugin-template/components/` | `/home/root/koreader/plugins/components/` |
| OCR test plugin | `remarkable2-koplugin-template/ocrtest.koplugin/` | `/home/root/koreader/plugins/ocrtest.koplugin/` |

### Using WinSCP

1. In the left panel, navigate to your local `remarkable2-koplugin-template/` folder
2. In the right panel, navigate to `/home/root/koreader/plugins/`
3. Select the `components` folder â†’ drag to the right panel
4. Select the `ocrtest.koplugin` folder â†’ drag to the right panel

### Using Windows Terminal / PowerShell

Run these commands from the folder containing `remarkable2-koplugin-template/`:

```powershell
# Copy the shared components library
scp -r remarkable2-koplugin-template/components root@10.11.99.1:/home/root/koreader/plugins/

# Copy the OCR test plugin
scp -r remarkable2-koplugin-template/ocrtest.koplugin root@10.11.99.1:/home/root/koreader/plugins/
```

Enter the root password when prompted.

### Verify the transfer

In your SSH terminal:

```bash
ls /home/root/koreader/plugins/
```

You should see `components/` and `ocrtest.koplugin/` listed alongside the
other built-in plugins.

---

## Step 5 â€” Restart KOReader

The plugin will not appear until KOReader is restarted.

**On the reMarkable:**
1. In KOReader, swipe down from the top of the screen
2. Tap the icon in the top-right corner
3. Tap **Exit** â†’ **Exit**
4. Re-launch KOReader from xochitl (the default reMarkable interface)
   or from your launcher

**Alternatively, via SSH:**

```bash
# Restart KOReader without going back to xochitl:
systemctl restart koreader
```

---

## Step 6 â€” Enable the plugin

1. In KOReader: tap the **â˜°** menu (top-left)
2. Go to **More tools â†’ Plugin manager**
3. Find **OCR Test** in the list
4. Tap to enable it
5. KOReader will ask you to restart â€” tap **Restart**

After restart, the plugin appears under **â˜° â†’ More tools â†’ OCR Test**.

---

## Step 7 â€” Configure the OCR backend

Before you can convert handwriting, you need to give the plugin an API key.

1. Open **â˜° â†’ More tools â†’ OCR Test**
2. Tap **Settings** in the toolbar
3. Set **Backend** to `gemini` (recommended for first test â€” cheapest)
4. Enter your **API key**:
   - Gemini: get a free key at https://aistudio.google.com/app/apikey
   - OpenAI: https://platform.openai.com/api-keys
   - Anthropic: https://console.anthropic.com/
5. Leave **Model** blank to use the backend''s default
6. Tap the back gesture or close to save

---

## Step 8 â€” Test it

1. Open **â˜° â†’ More tools â†’ OCR Test**
2. Write something with your stylus on the white canvas
3. Tap **Convert**
4. Wait 3-8 seconds (first call may be slower)
5. A result screen appears showing:
   - The recognised text
   - Which backend processed it
   - How long it took (milliseconds)

If it works, you''re done. The OCR component is validated.

---

## Troubleshooting

### Plugin doesn''t appear in Plugin Manager
Check the directory structure is correct:
```bash
ls /home/root/koreader/plugins/ocrtest.koplugin/
# Should show: _meta.lua  main.lua
ls /home/root/koreader/plugins/components/ocr/
# Should show: ocr.lua
```

### "OCR not configured" message
The settings weren''t saved. Go back to Settings and re-enter your API key,
then close the settings screen (this triggers the save).

### "OCR failed: HTTP 400/401/403"
- 401/403: API key is wrong or not activated yet
- 400: Usually a model name typo â€” clear the Model field to use the default

### "OCR failed: network" or no response
- Make sure Wi-Fi is on: **â˜° â†’ Wi-Fi connection**
- Check the API key is for the correct service

### Strokes don''t appear / drawing feels wrong
This is likely a gesture threshold issue. Connect via SSH and check
`/home/root/koreader/crash.log` for error messages:
```bash
tail -50 /home/root/koreader/crash.log
```

### Plugin causes KOReader to crash on load
Check crash.log immediately after the crash:
```bash
cat /home/root/koreader/crash.log | tail -100
```
The Lua error will be near the bottom. Share it and we can fix it.

---

## Iterating â€” updating files after changes

Once the initial setup is done, updating is faster:

```powershell
# Update just the OCR component (most common)
scp remarkable2-koplugin-template/components/ocr/ocr.lua root@10.11.99.1:/home/root/koreader/plugins/components/ocr/ocr.lua

# Update the test plugin main file
scp remarkable2-koplugin-template/ocrtest.koplugin/main.lua root@10.11.99.1:/home/root/koreader/plugins/ocrtest.koplugin/main.lua
```

Then restart KOReader. You do **not** need to re-enable the plugin after
updates â€” only after the initial install.

**Faster restart via SSH:**
```bash
# On the reMarkable, from SSH:
killall -HUP luajit   # soft restart â€” faster than full restart
# If that doesn''t work:
systemctl restart koreader
```

---

## File structure on the device after deployment

```
/home/root/koreader/plugins/
â”œâ”€â”€ components/
â”‚   â”œâ”€â”€ ocr/
â”‚   â”‚   â””â”€â”€ ocr.lua
â”‚   â”œâ”€â”€ http/
â”‚   â”‚   â””â”€â”€ http.lua
â”‚   â”œâ”€â”€ wifi/
â”‚   â”‚   â””â”€â”€ wifi.lua
â”‚   â”œâ”€â”€ credentials/
â”‚   â”‚   â””â”€â”€ credentials.lua
â”‚   â”œâ”€â”€ dropbox/
â”‚   â”‚   â””â”€â”€ dropbox.lua
â”‚   â”œâ”€â”€ webdav/
â”‚   â”‚   â””â”€â”€ webdav.lua
â”‚   â”œâ”€â”€ progress/
â”‚   â”‚   â””â”€â”€ progress.lua
â”‚   â”œâ”€â”€ settings-screen/
â”‚   â”‚   â””â”€â”€ settings_screen.lua
â”‚   â”œâ”€â”€ text-viewer/
â”‚   â”‚   â””â”€â”€ text_viewer.lua
â”‚   â”œâ”€â”€ file-browser/
â”‚   â”‚   â””â”€â”€ file_browser.lua
â”‚   â””â”€â”€ kv-page/
â”‚       â””â”€â”€ kv_page.lua
â””â”€â”€ ocrtest.koplugin/
    â”œâ”€â”€ _meta.lua
    â””â”€â”€ main.lua
```

> The `components/` directory is **shared** across all plugins you build.
> Each new plugin you create only needs to contain its own `.koplugin/`
> directory â€” it requires the components by path, and they only need to
> exist once on the device.
