# deploy.ps1
# Deploys all plugin files to your reMarkable 2.
# Run from the root of your remarkable-toolkit repo.
#
# Usage:
#   .\deploy.ps1
#   .\deploy.ps1 -Device 192.168.1.x   # if using Wi-Fi IP instead of USB

param(
    [string]$Device = "10.11.99.1"   # USB default; change to Wi-Fi IP if needed
)

$target = "root@${Device}:/home/root/koreader/plugins"

Write-Host "Deploying to $Device..." -ForegroundColor Cyan

# Deploy shared components library
Write-Host "Copying components/..."
scp -r components "$target/"

# Deploy plugins
Get-ChildItem -Directory -Filter "*.koplugin" | ForEach-Object {
    Write-Host "Copying $($_.Name)/..."
    scp -r $_.FullName "$target/"
}

Write-Host ""
Write-Host "Done. Restart KOReader on the device to load updated plugins." -ForegroundColor Green