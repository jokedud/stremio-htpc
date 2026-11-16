#!/usr/bin/env python3
"""Synchronize addon descriptors; never print credentials or private URLs."""
import getpass
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

CONFIG = Path('/etc/stremio-htpc')


def request(url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = Request(url, data=data, headers={'Content-Type': 'application/json',
                                         'User-Agent': 'stremio-htpc/1'})
    with urlopen(req, timeout=40) as response:
        return json.load(response)


def api(method, payload):
    result = request('https://api.strem.io/api/' + method, payload)
    if not isinstance(result, dict) or 'error' in result or 'result' not in result:
        raise ValueError('Stremio API rejected ' + method)
    return result['result']


def read_urls():
    urls = []
    for name in ('addons.txt', 'addons.local'):
        path = CONFIG / name
        if path.exists():
            urls.extend(path.read_text().split())
    for url in urls:
        parsed = urlsplit(url)
        if parsed.scheme != 'https' or not parsed.netloc or not parsed.path.endswith('/manifest.json'):
            raise ValueError('Addon URLs must be HTTPS manifest.json URLs')
    return list(dict.fromkeys(urls))


def sync(urls, email, password):
    auth = api('login', {'type': 'Login', 'email': email,
                         'password': password, 'facebook': False})
    key = auth['authKey']
    try:
        collection = api('addonCollectionGet', {'type': 'AddonCollectionGet',
                         'authKey': key, 'update': True})
        addons = collection['addons']
        if not isinstance(addons, list):
            raise ValueError('Invalid addon collection')
        known = {addon['transportUrl'] for addon in addons}
        for url in urls:
            if url not in known:
                manifest = request(url)
                if not isinstance(manifest, dict) or not all(k in manifest for k in ('id', 'version', 'name', 'resources', 'types', 'catalogs')):
                    raise ValueError('Invalid addon manifest; collection left unchanged')
                addons.append({'transportUrl': url, 'manifest': manifest,
                               'flags': {'official': False, 'protected': False}})
                known.add(url)
        api('addonCollectionSet', {'type': 'AddonCollectionSet', 'authKey': key,
                                  'addons': addons})
    finally:
        try:
            api('logout', {'type': 'Logout', 'authKey': key})
        except Exception:
            pass


def main():
    if os.geteuid() != 0:
        raise ValueError('Run with sudo to read private addons')
    email = os.environ.get('STREMIO_EMAIL') or input('Stremio email: ')
    password = os.environ.pop('STREMIO_PASSWORD', '') or getpass.getpass('Stremio password: ')
    if not email or not password:
        raise ValueError('Email and password are required')
    sync(read_urls(), email, password)
    print('Addon collection synchronized. Log into this account in Stremio.')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt):
        print('Addon sync failed; check credentials, network and manifest availability. No secrets logged.', file=sys.stderr)
        sys.exit(1)
