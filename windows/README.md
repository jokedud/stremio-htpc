# Stremio HTPC for Windows

Turns a dedicated Windows 10/11 x64 PC into a fullscreen Stremio box controlled
with an Amazon Fire TV Bluetooth remote, with an optional WireGuard tunnel.
The desktop stays installed; there is no locked-down shell. On sign-in a logon task
starts an AutoHotkey script that:

* launches official Stremio 5 for Windows and relaunches it ~3s after it exits;
* keeps the Stremio window fullscreen (sends F11 whenever it gets a title bar);
* maps Fire TV remote buttons to the keys Stremio uses.

The installer also turns on auto-login for your account, sets display, sleep and
hibernate timeouts to never (AC), and merges the same 20 GiB cache / hardware
transcoding server settings as the Linux installer.

**Status:** install, re-install, uninstall, the WireGuard tunnel service, fullscreen
enforcement and the restart keys were checked on Windows Server 2022. A real Fire TV
remote, TV/HDMI audio, GPU decoding and a real reboot into auto-login were not.

## Install

Sign in with the account that should auto-login, open **PowerShell as administrator**:

```powershell
irm https://raw.githubusercontent.com/jokedud/stremio-htpc/main/windows/install.ps1 -OutFile $env:TEMP\htpc-install.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\htpc-install.ps1
```

Or run `windows\install.ps1` from a clone; helpers next to it are used instead of
being downloaded (`-RepoRaw`/`REPO_RAW` picks another published branch).

You are prompted once for your Windows password. It goes into LSA secrets (where
Windows' own auto-logon reads it), never into a file or the plain `DefaultPassword`
registry value. Use `-NoAutoLogon` to skip this, `-NoStart` to not start the kiosk
right away. Windows 11 ignores auto-login for Microsoft accounts while *"For improved
security, only allow Windows Hello sign-in"* is on (Settings > Accounts > Sign-in
options); turn it off or use a local account.

Downloads are pinned and checked before running: Stremio 5.0.24 (Authenticode,
Smart Code OOD), WireGuard 1.1.1 MSI (Authenticode, WireGuard LLC), AutoHotkey 2.0.32
portable zip (SHA-256). Stremio and WireGuard are skipped if already installed.
Re-running the installer is safe and keeps the original backups.

## WireGuard

Get a `.conf` tunnel file from your VPN provider or WireGuard server, then:

```powershell
powershell -ExecutionPolicy Bypass -File $env:TEMP\htpc-install.ps1 -WireGuardConfig C:\path\home.conf
```

The file name becomes the tunnel name (`home` here; 1-32 letters, digits, `_=+.-`).
The installer validates `[Interface]` (PrivateKey, Address) and every `[Peer]`
(PublicKey, AllowedIPs, Endpoint), copies it to
`C:\ProgramData\stremio-htpc\wireguard\` readable only by SYSTEM/Administrators,
and installs it as the `WireGuardTunnel$home` service (starts at boot, before
sign-in). It fails if the service does not reach Running. `AllowedIPs = 0.0.0.0/0`
or `::/0` sends all traffic, including streams, through the VPN and prints a warning;
list only your home subnet for a split tunnel. Re-run with another file to replace
the tunnel. Check status with `& 'C:\Program Files\WireGuard\wg.exe' show`. Keys
never leave your machine; don't commit `.conf` files.

## Pair the Fire TV remote

Remove it from the old Fire TV if needed, hold **Home ~10s** until the light flashes,
then Windows **Settings > Bluetooth & devices > Add device > Bluetooth** and pick it.
It pairs as a Bluetooth keyboard/consumer-control device.

| Button | Result |
|---|---|
| D-pad, Select | Arrow keys, Enter (native) |
| Back | Escape |
| Play/Pause, Play, Pause | Space |
| Rewind / Fast forward | Left / Right (seek) |
| Menu | Toggle fullscreen (pauses fullscreen enforcement until pressed again) |
| Home, short tap | Escape |
| Home, held ~1.5s | Restart Stremio |
| Ctrl+Alt+Backspace on a keyboard | Restart Stremio |
| Volume / Mute | Windows volume (native) |

Remaps apply only while Stremio is the active window, except Home and
Ctrl+Alt+Backspace. Rewind/fast forward/play/pause are caught as unhandled
`WM_APPCOMMAND` media commands. Fire TV generations differ; volume and power often
go over IR to the TV, and Alexa/voice is not supported. If a button does nothing,
run a one-line `KeyHistory` script with `C:\Program Files\stremio-htpc\AutoHotkey64.exe`
to see what your remote sends, then adjust `kiosk.ahk`.

## Addons

Same as Linux: [addons.txt](../addons.txt) plus private URLs saved to
`C:\ProgramData\stremio-htpc\addons.local` (Administrators only):

```powershell
powershell -ExecutionPolicy Bypass -File $env:TEMP\htpc-install.ps1 -ExtraAddons "https://private.example/token/manifest.json" -StremioEmail you@x
# later:
powershell -ExecutionPolicy Bypass -File "C:\Program Files\stremio-htpc\sync-addons.ps1"
```

The password is prompted (or read from `STREMIO_PASSWORD`) and never written to disk.
Sign in to Stremio on screen yourself; sync only edits the account's addon collection.

## Troubleshooting

* Kiosk not starting: `Get-ScheduledTask 'Stremio HTPC'`, `Start-ScheduledTask 'Stremio HTPC'`.
* Exit the kiosk for maintenance: end `AutoHotkey64.exe` in Task Manager, then close Stremio.
* Tunnel: `Get-Service 'WireGuardTunnel$*'`; the WireGuard app's Log tab shows handshake errors.
* Hardware transcoding: the Stremio server may switch `transcodeHardwareAccel` back
  off when its GPU test fails (it did on a GPU-less VM).

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\stremio-htpc\uninstall.ps1"
```

Removes the logon task, kiosk files, the tunnel service and saved config, and
restores the previous auto-login values/password and power timeouts. Stremio,
WireGuard, account addons and Stremio data stay. Restore
`%APPDATA%\stremio\stremio-server\server-settings.json.pre-htpc` manually to undo
server preferences.

## Development checks

```powershell
Invoke-Pester windows/tests            # Pester 5+
Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows/PSScriptAnalyzerSettings.psd1
AutoHotkey64.exe /ErrorStdOut /Validate windows/kiosk.ahk
```
