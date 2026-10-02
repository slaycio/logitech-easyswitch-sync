<#
.SYNOPSIS
  Regenerates the git bundle used as the "onedrive" remote.

.DESCRIPTION
  A git bundle is a point-in-time snapshot, not a live repository - there is
  no such thing as pushing to it. To publish new commits through the
  OneDrive-synced bundle, just re-run this after committing; OneDrive picks
  up the changed file and syncs it to your other machines, where `git fetch
  onedrive` (or `git pull onedrive master`) picks up the new history.

.PARAMETER BundlePath
  Defaults to "<OneDrive>\logitech-easyswitch-sync-remote\logitech-easyswitch-sync.bundle".
#>

param(
    [string]$BundlePath = (Join-Path $env:OneDrive "logitech-easyswitch-sync-remote\logitech-easyswitch-sync.bundle")
)

$dir = Split-Path -Parent $BundlePath
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

git bundle create $BundlePath --all
Write-Host "Bundle updated: $BundlePath" -ForegroundColor Green
