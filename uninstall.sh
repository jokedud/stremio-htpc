#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -f /etc/stremio-htpc/user ]] || { echo 'No managed installation found.'; exit 0; }
user=$(cat /etc/stremio-htpc/user)
home=$(getent passwd "$user" | cut -d: -f6)
dropin=/etc/systemd/system/getty@tty1.service.d/stremio-htpc.conf
rm -f "$dropin"
if [[ -f /etc/stremio-htpc/getty.original ]]; then
    cp -p /etc/stremio-htpc/getty.original "$dropin"
fi
if [[ -f /etc/stremio-htpc/bash_profile.original ]]; then
    cp -p /etc/stremio-htpc/bash_profile.original "$home/.bash_profile"
elif [[ -f /etc/stremio-htpc/profile-created ]]; then
    sed -i '/# BEGIN stremio-htpc/,/# END stremio-htpc/d' "$home/.bash_profile"
fi
rm -f /etc/keyd/default.conf
if [[ -f /etc/stremio-htpc/keyd.original ]]; then
    cp -p /etc/stremio-htpc/keyd.original /etc/keyd/default.conf
fi
if [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl restart keyd.service || true
fi
rm -rf /usr/local/lib/stremio-htpc /etc/stremio-htpc
rm -f /usr/local/sbin/stremio-htpc-addons /usr/local/sbin/stremio-htpc-uninstall
echo 'Kiosk configuration removed. User, packages, group membership, linger and Stremio data retained.'
echo 'Reboot to exit the running kiosk. Server-settings backups (*.json.pre-htpc) can be restored manually.'
