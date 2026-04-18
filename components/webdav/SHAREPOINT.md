# SharePoint Online â€” Component Stub

## Why there is no ready-made component here

SharePoint Online (Microsoft 365 cloud) deprecated WebDAV access. The only
reliable programmatic approach for modern tenants is the **Microsoft Graph API**
with **OAuth2 (PKCE or device-code flow)**.

## What you need to build one

### 1. Azure App Registration (one-time, outside the device)

1. Go to https://portal.azure.com â†’ Azure Active Directory â†’ App registrations
2. New registration â†’ platform: **Mobile and desktop applications**
   - Redirect URI: `https://login.microsoftonline.com/common/oauth2/nativeclient`
3. Under **API permissions**, add:
   - Microsoft Graph â†’ Delegated â†’ `Files.ReadWrite` (or `.ReadWrite.All`)
   - Microsoft Graph â†’ Delegated â†’ `offline_access`
4. Note your **Application (client) ID** and **Tenant ID**.

### 2. Obtain a refresh token (one-time, on a computer)

Use the **device code flow** so no browser is needed on the device:

```
POST https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/devicecode
Content-Type: application/x-www-form-urlencoded

client_id={client_id}&scope=Files.ReadWrite offline_access
```

The response gives you a `device_code` and a URL+code to visit on a browser.
After the user authenticates, poll:

```
POST https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token
grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=...&client_id=...
```

You receive `access_token` and `refresh_token`. Store the refresh token.

### 3. Token refresh on the device

```
POST https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token
grant_type=refresh_token
&refresh_token={stored_refresh_token}
&client_id={client_id}
&scope=Files.ReadWrite offline_access
```

### 4. Key Graph API calls

```
# List a drive folder
GET https://graph.microsoft.com/v1.0/sites/{site_id}/drive/root:/{folder}:/children
Authorization: Bearer {access_token}

# Download a file
GET https://graph.microsoft.com/v1.0/sites/{site_id}/drive/items/{item_id}/content

# Upload (small files < 4 MB)
PUT https://graph.microsoft.com/v1.0/sites/{site_id}/drive/root:/{folder}/{filename}:/content
Authorization: Bearer {access_token}
Content-Type: application/octet-stream
<file bytes>
```

### 5. Finding your site_id

```
GET https://graph.microsoft.com/v1.0/sites?search=yoursite
```

Or use `https://graph.microsoft.com/v1.0/sites/{hostname}:/{site_path}`.

## Implementation notes for reMarkable 2

- The token refresh logic is nearly identical to the Dropbox component. Copy
  `components/dropbox/dropbox.lua`''s `_refreshToken()` and adapt the endpoint.
- Use `components/http/http.lua` for all HTTP calls.
- Use `components/wifi/wifi.lua`''s `WiFi:whenOnline()` guard.
- The Graph API returns JSON; use `Http.parseJSON()`.
- Large file uploads (> 4 MB) require the upload-session API (chunked upload).
  For typical document files this should not be needed.

## Recommended settings storage

```lua
G_reader_settings:saveSetting("myplugin_sharepoint", {
    tenant_id     = "...",
    client_id     = "...",
    refresh_token = "...",
    site_id       = "...",
    drive_root    = "/Shared Documents/MyFolder",
})
```
