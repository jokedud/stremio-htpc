#!/usr/bin/env python3
"""Seed a fresh Stremio 5 WebKit guest profile, never an existing installation."""
import base64
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import struct
import sys
import tempfile

ORIGIN = 'http://127.0.0.1:11470'


def initial_profile(addons):
    # Schema 2 is migrated by Stremio itself, including newly introduced settings.
    return {'auth': None, 'addons': addons, 'settings': {
        'interfaceLanguage': 'eng', 'streamingServerUrl': ORIGIN,
        'bingeWatching': True, 'playInBackground': True,
        'playInExternalPlayer': False, 'hardwareDecoding': True,
        'subtitlesLanguage': 'eng', 'subtitlesSize': 100,
        'subtitlesFont': 'Roboto', 'subtitlesBold': False,
        'subtitlesOffset': 5, 'subtitlesTextColor': '#FFFFFFFF',
        'subtitlesBackgroundColor': '#00000000', 'subtitlesOutlineColor': '#000000',
    }}


def seed(home, addons):
    if not isinstance(addons, list) or not addons:
        raise ValueError('No addon descriptors received')
    storage = Path(home) / '.var/app/com.stremio.Stremio/data/stremio/storage'
    # WebKit owns this directory after first launch. Never edit a live database,
    # downgrade its schema, replace an account or touch an existing guest profile.
    if storage.exists():
        return False
    storage.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(dir=storage.parent) as directory:
        staging = Path(directory) / 'storage'
        staging.mkdir(mode=0o700)
        salt = os.urandom(8)
        (staging / 'salt').write_bytes(salt)
        origin_hash = base64.urlsafe_b64encode(hashlib.sha256(ORIGIN.encode() + salt).digest()).decode().rstrip('=')
        origin = staging / origin_hash / origin_hash
        database = origin / 'LocalStorage/localstorage.sqlite3'
        database.parent.mkdir(parents=True, mode=0o700)
        # WebKit's origin file stores the top/client SecurityOriginData pair.
        encoded_origin = b''.join(struct.pack('<IB', len(part), 1) + part
                                  for part in (b'http', b'127.0.0.1')) + struct.pack('<BH', 1, 11470)
        (origin / 'origin').write_bytes(encoded_origin * 2)
        with sqlite3.connect(database) as connection:
            connection.execute('CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)')
            for key, value in (('schema_version', 2), ('profile', initial_profile(addons))):
                connection.execute('INSERT INTO ItemTable VALUES (?, ?)',
                                   (key, json.dumps(value).encode('utf-16-le')))
        staging.rename(storage)
    return True


if __name__ == '__main__':
    try:
        os.umask(0o077)
        created = seed(sys.argv[1], json.load(sys.stdin))
        print('Guest addon profile seeded.' if created else
              'Existing Stremio storage retained; guest addon setup skipped.')
    except (Exception, KeyboardInterrupt):
        print('Guest addon setup failed. No secrets logged.', file=sys.stderr)
        sys.exit(1)
