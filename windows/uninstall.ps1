<#
.SYNOPSIS
Removes the Stremio HTPC kiosk task, tunnel service, auto-logon and power changes.
#>
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramFiles 'stremio-htpc'
$configDir = Join-Path $env:ProgramData 'stremio-htpc'
$statePath = Join-Path $configDir 'state.json'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from an elevated (Administrator) PowerShell.' }
if (-not (Test-Path $statePath)) { Write-Host 'No managed installation found.'; exit 0 }
$moduleDir = if (Test-Path (Join-Path $installDir 'StremioHtpc.psm1')) { $installDir } else { $PSScriptRoot }
Import-Module (Join-Path $moduleDir 'StremioHtpc.psm1') -Force
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

Unregister-ScheduledTask -TaskName 'Stremio HTPC' -Confirm:$false -ErrorAction SilentlyContinue
Get-Process AutoHotkey64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$installDir\*" } | Stop-Process -Force
if ($state.Tunnel) {
    $wireguard = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    if ((Get-Service "WireGuardTunnel`$$($state.Tunnel)" -ErrorAction SilentlyContinue) -and (Test-Path $wireguard)) {
        & $wireguard /uninstalltunnelservice $state.Tunnel
    }
}
if ($state.AutoLogon) { Restore-HtpcAutoLogon $state.AutoLogon }
if ($state.Power) {
    $previous = @{}
    foreach ($property in $state.Power.PSObject.Properties) { $previous[$property.Name] = $property.Value }
    [void](Set-HtpcPowerIndexes $previous)
}
Remove-Module StremioHtpc
Remove-Item -LiteralPath $configDir -Recurse -Force
Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Kiosk configuration removed. Stremio, WireGuard, account addons and Stremio data retained.'
Write-Host 'Sign out to leave the running kiosk. Restore server-settings.json.pre-htpc manually to undo server preferences.'
