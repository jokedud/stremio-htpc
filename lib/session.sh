#!/bin/bash
set -euo pipefail
setterm --blank 0 --powerdown 0 || true
exec dbus-run-session -- cage -- /usr/local/lib/stremio-htpc/kiosk.sh
