#!/usr/bin/env python3
"""Build a standalone root installer. Keep its private output out of git."""
import argparse
import base64
import io
import os
from pathlib import Path
import tarfile

FILES = ('install.sh', 'uninstall.sh', 'addons.txt', 'lib/settings.py',
         'lib/addons.py', 'lib/guest.py', 'lib/kiosk.sh', 'lib/session.sh',
         'lib/restart.sh', 'lib/keyd.conf')


def build(output, addons=None, source=None):
    source = Path(source or Path(__file__).resolve().parent)
    if Path(output).resolve().is_relative_to(source.resolve()):
        raise ValueError('Write private bundles outside the source checkout')
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode='w:gz') as bundle:
        for filename in FILES:
            bundle.add(source / filename, arcname=filename, recursive=False)
        if addons:
            bundle.add(addons, arcname='addons.local', recursive=False)
    payload = base64.encodebytes(archive.getvalue()).decode()
    script = '''#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run as root (sudo bash).' >&2; exit 1; }
bundle=$(mktemp -d)
trap 'rm -rf "$bundle"' EXIT
base64 -d <<'STREMIO_HTPC_BUNDLE' | tar -xz -C "$bundle"
''' + payload + '''STREMIO_HTPC_BUNDLE
HTPC_SOURCE_DIR="$bundle" bash "$bundle/install.sh" "$@"
'''
    with open(output, 'w', opener=lambda path, flags: os.open(path, flags, 0o600)) as file:
        os.fchmod(file.fileno(), 0o600)
        file.write(script)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='private output path outside the checkout')
    parser.add_argument('--addons', type=Path, help='HTTPS manifest URLs, one per line')
    args = parser.parse_args()
    build(args.output, args.addons)
