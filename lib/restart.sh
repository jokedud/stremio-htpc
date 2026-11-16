#!/bin/bash
set -euo pipefail
user=$(cat /etc/stremio-htpc/user)
uid=$(id -u "$user")
runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" flatpak kill com.stremio.Stremio || true
