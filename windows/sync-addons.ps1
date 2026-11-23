<#
.SYNOPSIS
Adds addons.txt and addons.local manifests to a Stremio account. Run elevated.
#>
[CmdletBinding()]
param([string]$Email = $env:STREMIO_EMAIL, [securestring]$Password)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Import-Module (Join-Path $PSScriptRoot 'StremioHtpc.psm1') -Force
$configDir = Join-Path $env:ProgramData 'stremio-htpc'
if (-not $Email) { $Email = Read-Host 'Stremio email' }
if (-not $Password) {
    $Password = if ($env:STREMIO_PASSWORD) { ConvertTo-SecureString $env:STREMIO_PASSWORD -AsPlainText -Force }
    else { Read-Host 'Stremio password' -AsSecureString }
}
$env:STREMIO_PASSWORD = $null
$urls = @(Read-HtpcAddonUrls -ConfigDir $configDir)
try { Sync-StremioAddons -Urls $urls -Email $Email -Password $Password }
catch { throw 'Addon sync failed; the account collection was not changed.' }
Write-Host "Synced $(@($urls).Count) addon URL(s). Restart Stremio (hold Home) to reload them."
