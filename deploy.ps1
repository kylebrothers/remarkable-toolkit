# deploy.ps1
# Deploys all plugins to your reMarkable 2.
# Run from the root of your remarkable-toolkit repo.
#
# Usage:
#   .\deploy.ps1                        # USB connection (default)
#   .\deploy.ps1 -Device 192.168.x.x   # Wi-Fi connection

param(
    [string]$Device = "10.11.99.1"
)

$pluginsPath = "/home/root/xovi/exthome/appload/koreader/plugins"
$target      = "root@${Device}:${pluginsPath}"

# List of plugin directories to deploy.
# Add new plugin names here as you create them.
$plugins = @(
    "ocrtest.koplugin"
    # "myplugin.koplugin"   # uncomment when ready
)

Write-Host ""
Write-Host "Deploying to $Device..." -ForegroundColor Cyan
Write-Host "Target: $pluginsPath"
Write-Host ""

# Check SSH is reachable
Write-Host "Testing connection..." -ForegroundColor Yellow
$test = ssh -o ConnectTimeout=5 -o BatchMode=yes root@$Device "echo ok" 2>&1
if ($test -ne "ok") {
    Write-Host "ERROR: Cannot reach $Device. Check:" -ForegroundColor Red
    Write-Host "  - USB cable is connected, or device is on Wi-Fi"
    Write-Host "  - SSH password has been entered at least once in this session"
    Write-Host "  Tip: run  ssh root@$Device  first to cache credentials"
    exit 1
}
Write-Host "Connection OK" -ForegroundColor Green
Write-Host ""

# Deploy each plugin with its own copy of components/
foreach ($plugin in $plugins) {
    if (-not (Test-Path $plugin)) {
        Write-Host "WARNING: $plugin not found, skipping" -ForegroundColor Yellow
        continue
    }

    Write-Host "Deploying $plugin..." -ForegroundColor Cyan

    # Copy the plugin directory
    scp -r $plugin "$target/"

    # Copy components/ into the plugin on the device
    # This is required: KOReader's module loader looks for components/
    # relative to the plugin root, not as a sibling directory.
    Write-Host "  Copying components/ into $plugin..."
    scp -r components "$target/$plugin/"

    Write-Host "  Done" -ForegroundColor Green
}

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next: restart KOReader on the device to load updated plugins."
Write-Host "      (Swipe down → top-right icon → Exit → Exit → relaunch)"
