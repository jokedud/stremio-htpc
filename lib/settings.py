#!/usr/bin/env python3
"""Merge server settings without replacing unrelated preferences."""
import json
import os
from pathlib import Path
import sys


def merge(path):
    path = Path(path)
    settings = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError("Settings must be a JSON object")
    settings.update(cacheSize=20 * 1024**3, transcodeHardwareAccel=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not path.with_suffix('.json.pre-htpc').exists():
        path.with_suffix('.json.pre-htpc').write_bytes(path.read_bytes())
    temp = path.with_suffix('.json.tmp')
    temp.write_text(json.dumps(settings, indent=2) + '\n')
    os.replace(temp, path)


if __name__ == '__main__':
    for filename in sys.argv[1:]:
        merge(filename)
