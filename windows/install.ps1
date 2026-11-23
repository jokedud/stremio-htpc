<#
.SYNOPSIS
Turns a Windows PC into a fullscreen Stremio appliance with an optional WireGuard tunnel.
Run from an elevated PowerShell signed in as the account that should auto-login.
#>
[CmdletBinding()]
param(
    [string]$WireGuardConfig,
    [string]$ExtraAddons = $env:EXTRA_ADDONS,
    [string]$StremioEmail = $env:STREMIO_EMAIL,
    [securestring]$WindowsPassword,
    [switch]$NoAutoLogon,
    [switch]$NoStart,
    [string]$RepoRaw = $(if ($env:REPO_RAW) { $env:REPO_RAW } else { 'https://raw.githubusercontent.com/jokedud/stremio-htpc/main' })
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$StremioUrl = 'https://dl.strem.io/stremio-shell-ng/v5.0.24/StremioSetup-v5.0.24_x64.exe'
$WireGuardUrl = 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.1.msi'
$AutoHotkeyUrl = 'https://github.com/AutoHotkey/AutoHotkey/releases/download/v2.0.32/AutoHotkey_2.0.32.zip'
$AutoHotkeySha256 = '384A4C125E8D7B5B77DDBD5A593EC761D3E9E96E97A95931CF56E9A077FDA114'
$InstallDir = Join-Path $env:ProgramFiles 'stremio-htpc'
$ConfigDir = Join-Path $env:ProgramData 'stremio-htpc'
$StatePath = Join-Path $ConfigDir 'state.json'
$TaskName = 'Stremio HTPC'
$StremioExe = Join-Path $env:LOCALAPPDATA 'Programs\Stremio\stremio-shell-ng.exe'
$WireGuardExe = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'

function Step($message) { Write-Host "==> $message" }

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from an elevated (Administrator) PowerShell.' }
if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Version.Major -lt 10) { throw '64-bit Windows 10/11 required.' }
if ($WireGuardConfig) { $WireGuardConfig = (Resolve-Path -LiteralPath $WireGuardConfig).Path }

$stage = Join-Path ([IO.Path]::GetTempPath()) "stremio-htpc-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $helpers = 'windows/StremioHtpc.psm1', 'windows/HtpcLsa.cs', 'windows/kiosk.ahk', 'windows/sync-addons.ps1', 'windows/uninstall.ps1', 'addons.txt'
    $localRoot = if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'StremioHtpc.psm1'))) { Split-Path -Parent $PSScriptRoot }
    foreach ($file in $helpers) {
        $target = Join-Path $stage (Split-Path -Leaf $file)
        if ($localRoot) { Copy-Item -LiteralPath (Join-Path $localRoot $file) -Destination $target }
        else { Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/$file" -OutFile $target }
    }
    Import-Module (Join-Path $stage 'StremioHtpc.psm1') -Force
    if ($WireGuardConfig) { $tunnel = Test-WireGuardConfig $WireGuardConfig }
    $state = if (Test-Path $StatePath) { Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } else { $null }
    if ($state -and $state.User -ne $env:USERNAME) { throw "Already installed for $($state.User); run uninstall.ps1 first." }

    if (-not (Test-Path $StremioExe)) {
        Step 'Installing Stremio'
        $setup = Join-Path $stage 'StremioSetup.exe'
        Invoke-WebRequest -UseBasicParsing -Uri $StremioUrl -OutFile $setup
        Test-HtpcDownload $setup -Signer 'Smart Code OOD'
        $process = Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER' -Wait -PassThru
        if ($process.ExitCode -ne 0 -or -not (Test-Path $StremioExe)) { throw "Stremio setup failed ($($process.ExitCode))" }
    }
    if (-not (Test-Path $WireGuardExe)) {
        Step 'Installing WireGuard'
        $msi = Join-Path $stage 'wireguard.msi'
        Invoke-WebRequest -UseBasicParsing -Uri $WireGuardUrl -OutFile $msi
        Test-HtpcDownload $msi -Signer 'WireGuard LLC'
        $process = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', 'DO_NOT_LAUNCH=1' -Wait -PassThru
        if ($process.ExitCode -notin 0, 3010) { throw "WireGuard setup failed ($($process.ExitCode))" }
    }

    Step 'Installing kiosk helpers'
    $zip = Join-Path $stage 'ahk.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $AutoHotkeyUrl -OutFile $zip
    Test-HtpcDownload $zip -Sha256 $AutoHotkeySha256
    Get-Process AutoHotkey64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallDir\*" } | Stop-Process -Force
    New-Item -ItemType Directory -Force -Path $InstallDir, $ConfigDir | Out-Null
    Protect-HtpcPath $ConfigDir
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $stage 'ahk') -Force
    Copy-Item -LiteralPath (Join-Path $stage 'ahk\AutoHotkey64.exe'), (Join-Path $stage 'ahk\license.txt') -Destination $InstallDir -Force -ErrorAction SilentlyContinue
    foreach ($file in 'StremioHtpc.psm1', 'HtpcLsa.cs', 'kiosk.ahk', 'sync-addons.ps1', 'uninstall.ps1') {
        Copy-Item -LiteralPath (Join-Path $stage $file) -Destination $InstallDir -Force
    }
    if (-not (Test-Path (Join-Path $InstallDir 'AutoHotkey64.exe'))) { throw 'AutoHotkey extraction failed' }
    Copy-Item -LiteralPath (Join-Path $stage 'addons.txt') -Destination $ConfigDir -Force
    if ($ExtraAddons) { Add-HtpcLocalAddons -ConfigDir $ConfigDir -Urls $ExtraAddons }
    $ExtraAddons = $null
    $env:EXTRA_ADDONS = $null

    Step 'Applying Stremio server settings'
    Stop-Process -Name stremio-shell-ng, stremio-runtime -Force -ErrorAction SilentlyContinue
    Merge-StremioServerSettings (Join-Path $env:APPDATA 'stremio\stremio-server\server-settings.json')

    if ($WireGuardConfig) {
        Step "Installing WireGuard tunnel $($tunnel.Name)"
        if ($tunnel.FullTunnel) { Write-Warning 'This tunnel routes all traffic (AllowedIPs 0.0.0.0/0 or ::/0); streams will use the VPN.' }
        $tunnelDir = Join-Path $ConfigDir 'wireguard'
        New-Item -ItemType Directory -Force -Path $tunnelDir | Out-Null
        $names = @($tunnel.Name) + @(if ($state -and $state.Tunnel) { $state.Tunnel }) | Select-Object -Unique
        foreach ($name in $names) {
            if (-not (Get-Service "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue)) { continue }
            [void](Start-Process $WireGuardExe -ArgumentList '/uninstalltunnelservice', $name -Wait -PassThru)
            for ($i = 0; $i -lt 30 -and (Get-Service "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
        }
        $tunnelPath = Join-Path $tunnelDir "$($tunnel.Name).conf"
        Copy-Item -LiteralPath $WireGuardConfig -Destination $tunnelPath -Force
        Protect-HtpcPath $tunnelPath
        $process = Start-Process $WireGuardExe -ArgumentList '/installtunnelservice', "`"$tunnelPath`"" -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "WireGuard tunnel install failed ($($process.ExitCode))" }
        $service = $null
        for ($i = 0; $i -lt 40; $i++) {
            $service = Get-Service $tunnel.Service -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $service -or $service.Status -ne 'Running') { throw "WireGuard tunnel $($tunnel.Name) did not start; check the config and the WireGuard log." }
    }

    Step 'Disabling sleep and display timeouts'
    $power = if ($state -and $state.Power) { $state.Power } else { Set-HtpcPowerIndexes }
    if ($state -and $state.Power) { [void](Set-HtpcPowerIndexes) }

    $autoLogon = if ($state) { $state.AutoLogon } else { $null }
    if (-not $NoAutoLogon) {
        Step "Enabling auto-login for $env:USERNAME"
        if (-not $WindowsPassword -and -not $autoLogon) { $WindowsPassword = Read-Host "Windows password for $env:USERNAME (stored in LSA secrets for auto-login)" -AsSecureString }
        if (-not $autoLogon) { $autoLogon = Backup-HtpcAutoLogon }
        if ($WindowsPassword) { Set-HtpcAutoLogon -UserName $env:USERNAME -Password $WindowsPassword }
    }

    [ordered]@{
        User = $env:USERNAME
        AutoLogon = $autoLogon
        Power = $power
        Tunnel = if ($WireGuardConfig) { $tunnel.Name } elseif ($state) { $state.Tunnel } else { $null }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8

    if ($StremioEmail) {
        Step 'Syncing addons to the Stremio account'
        & (Join-Path $InstallDir 'sync-addons.ps1') -Email $StremioEmail
    }

    Step 'Registering the kiosk logon task'
    $account = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute (Join-Path $InstallDir 'AutoHotkey64.exe') -Argument "`"$(Join-Path $InstallDir 'kiosk.ahk')`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    [void](Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Force)
    if (-not $NoStart) { Start-ScheduledTask -TaskName $TaskName }

    Write-Host 'Done. Pair the Fire TV remote in Settings > Bluetooth & devices, then reboot.'
    Write-Host "Uninstall: powershell -ExecutionPolicy Bypass -File `"$InstallDir\uninstall.ps1`""
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
