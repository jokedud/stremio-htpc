#!/bin/bash
set -euo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/jokedud/stremio-htpc/main}
log() { printf '[stremio-htpc] %s\n' "$*"; }
die() { log "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run as root (sudo bash).'
[[ -r /etc/os-release ]] || die 'Debian/Ubuntu Linux required.'
# shellcheck source=/dev/null
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *debian*|*ubuntu*) ;;
    *) die 'Only apt-based Debian/Ubuntu systems are supported.' ;;
esac
command -v apt-get >/dev/null || die 'apt-get required.'
[[ -d /run/systemd/system ]] || [[ ${SKIP_SYSTEMD:-0} == 1 ]] || die 'Boot with systemd first (or SKIP_SYSTEMD=1 for container checks).'
user=${HTPC_USER:-${SUDO_USER:-htpc}}
[[ $user != root ]] || user=htpc
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'Invalid HTPC_USER.'
[[ ! -f /etc/stremio-htpc/user ]] || [[ $(cat /etc/stremio-htpc/user) == "$user" ]] || die 'Uninstall before changing HTPC_USER.'
log 'Installing OS dependencies'
apt-get update
apt-get install -y ca-certificates curl python3 flatpak bluez cage xwayland dbus-user-session dbus-x11 \
    mesa-va-drivers vainfo pipewire pipewire-pulse wireplumber pulseaudio-utils alsa-utils
if apt-cache show intel-media-va-driver >/dev/null 2>&1; then
    apt-get install -y intel-media-va-driver
fi
if apt-cache show keyd >/dev/null 2>&1; then
    apt-get install -y keyd
elif ! command -v keyd >/dev/null; then
    log 'Building keyd v2.5.0'
    apt-get install -y build-essential git
    build=$(mktemp -d)
    trap 'rm -rf "${build:-}" "${stage:-}"' EXIT
    git clone --depth 1 --branch v2.5.0 https://github.com/rvaiya/keyd.git "$build/keyd"
    make -C "$build/keyd"
    make -C "$build/keyd" install
fi
stage=$(mktemp -d)
trap 'rm -rf "${build:-}" "${stage:-}"' EXIT
for file in lib/settings.py lib/addons.py lib/kiosk.sh lib/session.sh lib/restart.sh lib/keyd.conf lib/pair.py addons.txt uninstall.sh; do
    mkdir -p "$stage/$(dirname "$file")"
    curl -fsSL --retry 3 "$REPO_RAW/$file" -o "$stage/$file"
done
install -d -m 755 /usr/local/lib/stremio-htpc /etc/stremio-htpc /etc/keyd
install -m 755 "$stage/lib/pair.py" /usr/local/lib/stremio-htpc/pair.py
install -m 644 "$stage/lib/settings.py" /usr/local/lib/stremio-htpc/settings.py
for file in addons.py kiosk.sh session.sh restart.sh; do
    install -m 755 "$stage/lib/$file" "/usr/local/lib/stremio-htpc/$file"
done
install -m 755 "$stage/uninstall.sh" /usr/local/sbin/stremio-htpc-uninstall
ln -sf /usr/local/lib/stremio-htpc/addons.py /usr/local/sbin/stremio-htpc-addons
install -m 644 "$stage/addons.txt" /etc/stremio-htpc/addons.txt
printf '%s\n' "$user" > /etc/stremio-htpc/user
chmod 644 /etc/stremio-htpc/user
if [[ -n ${EXTRA_ADDONS:-} ]]; then
    touch /etc/stremio-htpc/addons.local
    chmod 600 /etc/stremio-htpc/addons.local
    EXTRA_ADDONS="$EXTRA_ADDONS" python3 - <<'PY'
import os
from pathlib import Path
p = Path('/etc/stremio-htpc/addons.local')
p.write_text('\n'.join(dict.fromkeys(p.read_text().split() + os.environ['EXTRA_ADDONS'].split())) + '\n')
PY
fi
unset EXTRA_ADDONS
if ! id "$user" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$user"
fi
home=$(getent passwd "$user" | cut -d: -f6)
[[ -d $home && $home != / ]] || die 'Kiosk user needs a real home directory.'
for group in video render input audio bluetooth; do
    getent group "$group" >/dev/null || groupadd --system "$group"
    usermod -aG "$group" "$user"
done
if [[ ${SKIP_FLATPAK:-0} != 1 ]]; then
    flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    flatpak install --system --noninteractive -y flathub com.stremio.Stremio
    # Flatpak resolves matching GL/VAAPI driver branches from runtime extensions.
    flatpak update --system --noninteractive -y com.stremio.Stremio
else
    log 'SKIP_FLATPAK=1: Stremio and GPU runtimes NOT installed.'
fi
for base in "$home/.stremio-server" "$home/.var/app/com.stremio.Stremio/.stremio-server"; do
    install -d -o "$user" -g "$(id -gn "$user")" -m 700 "$base"
    runuser -u "$user" -- python3 /usr/local/lib/stremio-htpc/settings.py "$base/server-settings.json"
done
# Ensure login shells use our hook without discarding existing profile content.
profile=$home/.bash_profile
if [[ ! -e /etc/stremio-htpc/profile-managed ]]; then
    if [[ -e $profile ]]; then
        cp -p "$profile" /etc/stremio-htpc/bash_profile.original
    else
        # shellcheck disable=SC2016
        printf '[ ! -f "$HOME/.profile" ] || . "$HOME/.profile"\n' > "$profile"
        touch /etc/stremio-htpc/profile-created
    fi
    cat >> "$profile" <<'PROFILE'

# BEGIN stremio-htpc
if [ "$(tty)" = /dev/tty1 ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    exec /usr/local/lib/stremio-htpc/session.sh
fi
# END stremio-htpc
PROFILE
    touch /etc/stremio-htpc/profile-managed
    chown "$user:$(id -gn "$user")" "$profile"
fi
install -d -m 755 /etc/systemd/system/getty@tty1.service.d
dropin=/etc/systemd/system/getty@tty1.service.d/stremio-htpc.conf
if [[ ! -e /etc/stremio-htpc/getty-managed ]]; then
    [[ ! -e $dropin ]] || cp -p "$dropin" /etc/stremio-htpc/getty.original
    touch /etc/stremio-htpc/getty-managed
fi
cat > "$dropin" <<GETTY
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $user --noclear %I \$TERM
GETTY
if [[ ! -e /etc/stremio-htpc/keyd-managed ]]; then
    [[ ! -f /etc/keyd/default.conf ]] || cp -p /etc/keyd/default.conf /etc/stremio-htpc/keyd.original
    touch /etc/stremio-htpc/keyd-managed
fi
install -m 644 "$stage/lib/keyd.conf" /etc/keyd/default.conf
cat > /etc/systemd/system/stremio-htpc-pair.service <<'PAIR'
[Unit]
Description=Automatic Fire TV remote pairing
After=bluetooth.service
Wants=bluetooth.service

[Service]
ExecStart=/usr/bin/python3 -u /usr/local/lib/stremio-htpc/pair.py
Restart=on-failure
RestartSec=15
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
PAIR
if [[ ${SKIP_SYSTEMD:-0} != 1 ]]; then
    systemctl daemon-reload
    systemctl enable --now bluetooth.service keyd.service
    systemctl enable --now stremio-htpc-pair.service
    systemctl restart keyd.service
    systemctl enable getty@tty1.service
    loginctl enable-linger "$user"
    uid=$(id -u "$user")
    systemctl start "user@$uid.service"
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
fi
if [[ -n ${STREMIO_EMAIL:-} ]]; then
    /usr/local/sbin/stremio-htpc-addons
else
    log 'Addons not synced: run sudo stremio-htpc-addons, or use the manual deep links described in README.'
fi
unset STREMIO_PASSWORD
log "Installed for $user. Hold remote Home ~10s for automatic pairing, then reboot. tty1 will autologin (physical access is trusted)."
