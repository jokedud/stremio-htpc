# Stremio HTPC

Turn a dedicated Debian/Ubuntu systemd PC into a fullscreen Stremio appliance,
controlled with an Amazon Fire TV Bluetooth remote. Installs Flathub Stremio,
BlueZ, keyd, Cage/Xwayland, PipeWire audio and available Mesa/Intel VA-API drivers.
tty1 automatically logs in and starts a restart-loop kiosk. No desktop is needed.

**Status:** initial implementation; macOS static/unit checks only. Real Linux boot,
Bluetooth, video playback, audio, GPU acceleration and remote timing are unverified.
Use a dedicated machine, not a desktop whose existing keyd/profile configuration you
need to preserve unchanged. The wildcard keyd map affects attached keyboards too.

## Install

On a fresh Debian 12+/Ubuntu 24.04+ installation with networking:

```sh
curl -fsSL https://raw.githubusercontent.com/jokedud/stremio-htpc/main/install.sh | sudo bash
```

Review downloaded root scripts before running them. This URL only works once the
project is published on `main`. No repository clone is needed: helpers are fetched
using `REPO_RAW` (defaults to that same raw GitHub directory). To test another
published branch, change **both** the entrypoint URL and `sudo REPO_RAW=... bash`.

`HTPC_USER` defaults to the non-root sudo caller; otherwise creates `htpc` with a
locked password. An existing user is retained. You can specify `sudo HTPC_USER=htpc bash`.
Pair the remote before rebooting. Stremio account sign-in on screen is still required;
addon synchronization does not inject a local login session. A new account's login
may require a temporary keyboard or remote-control app. This does not bypass Stremio's
own initial setup screens.

### Account + private addons

The defaults in [addons.txt](addons.txt) are Torrentio and the supplied public Comet
configuration. Addons are account-scoped, not a local editable collection file.
Use only streams you are authorized to access. Availability is controlled by the
addon providers; the supplied Comet configuration has torrent results disabled.

```sh
curl -fsSL https://raw.githubusercontent.com/jokedud/stremio-htpc/main/install.sh | sudo EXTRA_ADDONS="https://private.example/token/manifest.json https://other.example/token/manifest.json" STREMIO_EMAIL=you@x bash
```

The password is securely prompted via `/dev/tty` if `STREMIO_EMAIL` is set and
`STREMIO_PASSWORD` is absent. For fully unattended operation supply both variables
from your provisioning secret manager. Passwords/auth keys are never written to disk
or printed by these scripts. **Shell history, process environments and sudo audit
logging can expose inline secrets, including addon URLs.** Avoid literal credentials
in shell history; do not use `set -x`. Child processes inherit the installer environment.

Private URLs in `EXTRA_ADDONS` (space/newline separated HTTPS manifest URLs) are
deduplicated into root-owned mode-0600 `/etc/stremio-htpc/addons.local`, never into
the repository. Existing local URLs and account addons are kept. The sync fetches
all missing manifests before sending the updated collection; failure aborts the
write, with a generic error that does not expose tokenized URLs. Avoid simultaneous
addon edits from other devices during sync (the API has no compare-and-swap here).

Run later, prompting for credentials:

```sh
sudo stremio-htpc-addons
```

If no credentials are supplied, account sync is skipped. **Automatic first-boot
deep-link confirmation is not implemented**: without a Stremio ready/confirmation
signal, opening a series of links could replace dialogs before you press Select.
Instead, sign in, run the sync helper from SSH, and restart Stremio; or install each
addon individually from Stremio's addon UI. A manual deep-link alternative from the
running kiosk user's Wayland/X session is:

```sh
flatpak run com.stremio.Stremio 'stremio://torrentio.strem.fun/manifest.json'
```

Replace only `https://` with `stremio://` for each URL, one at a time, then confirm
in Stremio. Deep-link dispatch is version-dependent and has not been runtime-tested.
Do not copy private URLs into shared command histories.

## Pair the Fire TV remote

Disconnect the remote from its previous Fire TV if necessary. Hold **Home ~10s**
until its indicator flashes, then from SSH or a temporary keyboard:

```text
sudo bluetoothctl
power on
agent NoInputNoOutput
default-agent
scan on
# Wait for the remote's MAC address, then replace AA:BB:CC:DD:EE:FF below:
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
connect AA:BB:CC:DD:EE:FF
scan off
quit
```

Some generations require a different pairing gesture/agent. Reboot after installation;
autologin is enabled but the installer deliberately does not restart your active tty.

## Button map

| Button / Linux keyd name | Result |
|---|---|
| D-pad `up/down/left/right` | Arrow keys |
| Select emitting `enter` / `kpenter` | Enter |
| Back `back` / Escape | Backspace (navigate history) |
| `playpause`, `play`, `pause` | Space |
| `rewind` / `fastforward` | Left / right (seek) |
| `menu` | F11 (fullscreen toggle; Cage also constrains the window) |
| Remote Home `homepage`, short tap | Backspace (navigate history) |
| Remote Home `homepage` held alone ~1.5s | Kill only the kiosk user's Stremio; loop relaunches it |
| Ctrl+Alt+Backspace on a keyboard | Same kill switch |
| `volumeup`, `volumedown`, `mute` | Passed through unchanged |

Different Fire TV generations emit different HID/evdev events. The listed names
are verified keyd names, **not verified captures from your particular remote**.
Published [Fire TV Remote evtest output (1949:0404)](https://forum.kodi.tv/showthread.php?pid=1931078)
reports KPEnter, arrows, Menu, Back, PlayPause, Rewind, Homepage and FastForward;
the [OSMC Fire TV mapping](https://discourse.osmc.tv/t/rpi2-support-for-fire-tv-stick-remote-bluetooth/5738)
independently lists the same keys. Enter/Play/Pause are compatibility variants.
Keyboard Backspace and Home retain their normal behavior.
Stremio's [history shortcut](https://github.com/Stremio/stremio-web/blob/development/src/common/Shortcuts/shortcuts.json)
is Backspace; Escape alone can exit fullscreen without leaving movie details.
Because the wildcard map also affects keyboards, their Escape key becomes Backspace
too; use Menu/F11 to toggle fullscreen. In a focused text field, Backspace deletes text.
keyd v2.5.0's name table handles only codes below 256 and does **not** support
`KEY_SELECT` (353). If your remote emits that code instead of `KEY_ENTER` (28) or
`KEY_KPENTER` (96), it needs a device-specific HID/udev remap before keyd; this
installer does not guess scan codes or ship an invalid `select` binding.
Use `sudo keyd monitor` and `sudo evtest` (install `evtest` if needed) to diagnose.
Some volume/power buttons send IR to the TV instead of Bluetooth; passthrough
also requires an application/media-key handler to act on those keys in the kiosk.

## Cache and acceleration

Merges `cacheSize: 21474836480` (20 GiB) and `transcodeHardwareAccel: true` into:

* `~/.stremio-server/server-settings.json`
* `~/.var/app/com.stremio.Stremio/.stremio-server/server-settings.json`

Unrelated keys survive; malformed JSON stops installation without clobbering it.
Existing files get one `.json.pre-htpc` backup. Stop Stremio before re-running the
installer so it cannot overwrite your changes. Settings request acceleration; the
server can disable it if GPU tests fail. This is **server transcoding**, not a
guarantee that every client playback codec uses hardware decoding. Check Stremio's
player settings too. Flatpak installs driver extensions matching its runtime/host
GPU automatically; no obsolete fixed runtime branch is hard-coded.

Verified sources:

* [Server v4.20.16 bundle](https://dl.strem.io/server/v4.20.16/desktop/server.js),
  linked by [stremio-shell/server-url.txt](https://github.com/Stremio/stremio-shell/blob/master/server-url.txt):
  loads `server-settings.json` under appPath and reads both keys above.
* [Core API requests](https://github.com/Stremio/stremio-core/blob/master/src/types/api/request.rs),
  [authentication tests](https://github.com/Stremio/stremio-core/blob/master/src/unit_tests/ctx/authenticate.rs),
  [push-addon tests](https://github.com/Stremio/stremio-core/blob/master/src/unit_tests/ctx/push_addons_to_api.rs):
  POST `/api/login`, `/api/addonCollectionGet`, `/api/addonCollectionSet` with
  `type`, `authKey`, `update`, `addons`/descriptor shapes. A bogus login returned
  `{"error":{"code":2,"message":"User not found","wrongEmail":true}}`.
  No real account mutation has been tested.
* [Flathub manifest](https://github.com/flathub/com.stremio.Stremio/blob/master/com.stremio.Stremio.json):
  `--persist=.stremio-server`, GPU access, PulseAudio socket and conditional Intel
  VAAPI extension. The per-app host path follows Flatpak's persist semantics.
  The latest Flatpak may ship a newer server than the inspected shell bundle.
* [keyd v2.5.0 docs](https://github.com/rvaiya/keyd/blob/v2.5.0/docs/keyd.scdoc)
  and [key table](https://github.com/rvaiya/keyd/blob/v2.5.0/src/keys.c):
  `timeout(esc, 1500, command(...))`, root command execution and supported names.
  Apt's keyd version may differ; source fallback is pinned to v2.5.0.

## Troubleshooting

* Remote not responding: `sudo keyd monitor`, `sudo journalctl -u keyd -b`, check
  batteries, re-enter pairing mode, remove the old device in `bluetoothctl`, re-pair
  and trust it. Speech/Alexa, power and IR functionality are not configured.
* No hardware acceleration: run `vainfo` as the kiosk user with GPU access (headless:
  `vainfo --display drm --device /dev/dri/renderD128`); inspect `/dev/dri`, group
  membership and `flatpak --gl-drivers`. Host `vainfo` success alone does not prove
  sandbox GPU decoding. Proprietary NVIDIA/older Intel drivers may need manual work.
* No audio: `systemctl --user status pipewire pipewire-pulse wireplumber` as the
  kiosk user; `pactl list short sinks` and `pactl set-default-sink SINK` to choose HDMI.
* Not starting: `journalctl -b -u getty@tty1`, `journalctl -b -u user@$(id -u htpc)`
  (substitute your user), and `~/.local/state/stremio-htpc/kiosk.log`. From a real tty,
  run `/usr/local/lib/stremio-htpc/session.sh` as the kiosk user. Cage needs DRM/seat
  access and a connected display. Existing display managers may contend for the GPU;
  this installer does not disable an existing desktop for you.
* Screen blanking: the Linux console's blanking is disabled in the session and Cage
  runs without a screensaver; TV energy saving, firmware and suspend policies are
  outside this script. The reboot/autologin session itself remains unverified.
* Stremio dies: it restarts after three seconds. Home hold/Ctrl+Alt+Backspace kill
  only Stremio, not Cage. Use SSH for administration.

## Reset / uninstall

```sh
sudo stremio-htpc-uninstall
# or: sudo bash uninstall.sh
```

Restores saved keyd/getty/profile files, removes our hooks/helpers and local private
addon file. Reboot to leave an already running kiosk. Existing profile backups are
restored in full, so save any edits made since installation first. Packages, user,
group membership, linger, account addons and Stremio data remain deliberately.
Restore `server-settings.json.pre-htpc` manually to undo server preferences; delete
the two server-settings files to reset them. To remove the app:
`sudo flatpak uninstall --system com.stremio.Stremio`. Delete the kiosk user/home
and disable linger with `sudo loginctl disable-linger USER` only if appropriate.
Never expose SSH or autologin credentials publicly. Physical access to tty1 grants
access to the logged-in Stremio account and cached content; input-group membership
can read local keyboard events.

## Development checks

```sh
for file in install.sh uninstall.sh lib/*.sh; do bash -n "$file" || exit; done
shellcheck install.sh uninstall.sh lib/*.sh
python3 -m unittest discover -s tests -v
```

For container provisioning checks, serve this checkout from a trusted reachable
HTTP server and set `REPO_RAW` to it, then run in a disposable Debian 12/Ubuntu 24.04
container with `SKIP_SYSTEMD=1 SKIP_FLATPAK=1 HTPC_USER=htpc bash install.sh`.
These flags skip service activation and Flatpak only; apt/users/config files really
change. They are not a dry-run and cannot prove GPU, Bluetooth, boot or audio behavior.
