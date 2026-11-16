#!/bin/bash
set -euo pipefail
mkdir -p "$HOME/.local/state/stremio-htpc"
exec >>"$HOME/.local/state/stremio-htpc/kiosk.log" 2>&1
export QT_QPA_PLATFORM=xcb
while true; do
    flatpak run com.stremio.Stremio || true
    sleep 3
done
