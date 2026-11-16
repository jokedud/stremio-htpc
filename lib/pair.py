#!/usr/bin/env python3
"""Unattended pairing of discoverable Fire TV remotes using BlueZ's CLI."""
import argparse
import os
import re
import subprocess
import time

MAC = r'(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'


def parse_devices(output):
    return list(dict.fromkeys(re.findall(r'^Device (' + MAC + r')\b', output, re.M)))


def parse_info(output):
    return dict(re.findall(r'^\s*([\w]+):\s*(.*?)\s*$', output, re.M))


def is_fire_tv(info):
    names = ' '.join(info.get(key, '') for key in ('Name', 'Alias'))
    return bool(re.search(r'\bfire\s*tv\b', names, re.I)
                or re.fullmatch(r'usb:v1949p[0-9a-f]+d[0-9a-f]+',
                                info.get('Modalias', ''), re.I))


def known_remote(info):
    return is_fire_tv(info) and info.get('Paired') == 'yes' and info.get('Trusted') == 'yes'


def run_command(arguments):
    try:
        result = subprocess.run(['bluetoothctl', *arguments], capture_output=True,
                                text=True, timeout=45, env={**os.environ, 'LC_ALL': 'C'})
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode or re.search(r'Failed|not available|No default controller', result.stdout):
        return None
    return result.stdout


def cycle(run=run_command, log=print, scan_seconds=15):
    controller = run(['show'])
    if not controller or not re.search(r'^Controller ' + MAC, controller, re.M):
        return
    if parse_info(controller).get('Powered') != 'yes':
        log('Power on Bluetooth adapter')
        if run(['power', 'on']) is None:
            return

    def devices():
        output = run(['devices'])
        if output is None:
            return None
        return [(address, parse_info(run(['info', address]) or ''))
                for address in parse_devices(output)]

    existing = devices()
    if existing is None:
        return
    known = [(address, info) for address, info in existing if known_remote(info)]
    if known:
        for address, info in known:
            if info.get('Connected') != 'yes':
                log('Connect ' + address)
                if run(['connect', address]) is None:
                    log('Connect failed; retry next cycle')
        return
    log('Scan for Fire TV remote')
    if run(['--timeout', str(scan_seconds), 'scan', 'on']) is None:
        return
    for address, info in devices() or []:
        if not is_fire_tv(info):
            continue
        log('Found Fire TV remote ' + address)
        if info.get('Paired') != 'yes':
            log('Pair ' + address)
            if run(['--agent', 'NoInputNoOutput', '--timeout', '30', 'pair', address]) is None:
                log('Pair failed; retry next cycle')
                return
        for action in ('trust', 'connect'):
            log(action.capitalize() + ' ' + address)
            if run([action, address]) is None:
                log(action.capitalize() + ' failed; retry next cycle')
                return
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interval', type=float, default=15)
    parser.add_argument('--cycles', type=int, help='Exit after this many cycles (diagnostics)')
    args = parser.parse_args()
    if args.interval <= 0 or (args.cycles is not None and args.cycles <= 0):
        parser.error('interval and cycles must be positive')
    count = 0
    while True:
        cycle(log=lambda message: print(message, flush=True))
        count += 1
        if args.cycles is not None and count >= args.cycles:
            return
        time.sleep(args.interval)


if __name__ == '__main__':
    main()
