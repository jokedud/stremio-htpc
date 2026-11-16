import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('pair', Path(__file__).resolve().parents[1] / 'lib/pair.py')
pair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair)
ADDRESS = 'AA:BB:CC:DD:EE:FF'


class FakeBluetooth:
    def __init__(self, paired=False, trusted=False, connected=False, fail=None):
        self.paired, self.trusted, self.connected = paired, trusted, connected
        self.visible = paired
        self.fail = fail
        self.calls = []

    def __call__(self, args):
        self.calls.append(args)
        if self.fail in args:
            return None
        if args == ['show']:
            return 'Controller ' + ADDRESS + '\n\tPowered: yes\n'
        if args == ['devices']:
            return 'Device ' + ADDRESS + ' Amazon Fire TV Remote\n' if self.visible else ''
        if args[0] == 'info':
            return ('Name: Amazon Fire TV Remote\nPaired: %s\nTrusted: %s\nConnected: %s\n'
                    % tuple('yes' if value else 'no' for value in
                            (self.paired, self.trusted, self.connected)))
        if 'scan' in args:
            self.visible = True
        if 'pair' in args:
            self.paired = True
        if args[0] == 'trust':
            self.trusted = True
        if args[0] == 'connect':
            self.connected = True
        return ''


class PairTests(unittest.TestCase):
    def test_parsers(self):
        self.assertEqual(pair.parse_devices('noise\nDevice ' + ADDRESS + ' Name\nDevice ' + ADDRESS + ' Name'), [ADDRESS])
        self.assertEqual(pair.parse_devices('Device not-a-mac Name'), [])
        self.assertEqual(pair.parse_devices(''), [])
        self.assertEqual(pair.parse_info('\tName: Fire TV\n\tPaired: yes\nnoise'),
                         {'Name': 'Fire TV', 'Paired': 'yes'})
        self.assertEqual(pair.parse_info(''), {})

    def test_identification(self):
        for info in ({'Name': 'Amazon Fire TV Remote'}, {'Alias': 'Fire TV'},
                     {'Modalias': 'usb:v1949p0404d0110'}):
            self.assertTrue(pair.is_fire_tv(info))
        for info in ({}, {'Name': 'Keyboard'}, {'Name': 'Amazon Echo'},
                     {'Name': 'Bonfire TV'}, {'Modalias': 'usb:v1234p1949d0001'}):
            self.assertFalse(pair.is_fire_tv(info))

    def test_known_remote_does_not_scan(self):
        for connected in (True, False):
            run = FakeBluetooth(paired=True, trusted=True, connected=connected)
            pair.cycle(run, lambda _: None)
            self.assertFalse(any('scan' in args for args in run.calls))
            self.assertEqual(['connect', ADDRESS] in run.calls, not connected)

    def test_full_flow_then_idle(self):
        run = FakeBluetooth()
        pair.cycle(run, lambda _: None)
        self.assertEqual(run.calls, [
            ['show'], ['devices'], ['--timeout', '15', 'scan', 'on'], ['devices'],
            ['info', ADDRESS], ['--agent', 'NoInputNoOutput', '--timeout', '30', 'pair', ADDRESS],
            ['trust', ADDRESS], ['connect', ADDRESS]])
        run.calls.clear()
        pair.cycle(run, lambda _: None)
        self.assertEqual(run.calls, [['show'], ['devices'], ['info', ADDRESS]])

    def test_failed_pair_retries_next_cycle(self):
        run = FakeBluetooth(fail='pair')
        pair.cycle(run, lambda _: None)
        self.assertFalse(run.trusted)
        self.assertFalse(run.connected)
        run.fail = None
        pair.cycle(run, lambda _: None)
        self.assertTrue(run.paired and run.trusted and run.connected)

    def test_no_controller_is_quiet(self):
        for output in (None, '', 'No default controller available'):
            calls, logs = [], []
            def run(args):
                calls.append(args)
                return output
            pair.cycle(run, logs.append)
            self.assertEqual(calls, [['show']])
            self.assertEqual(logs, [])

    def test_power_and_failures(self):
        for failure in ('power', 'devices', 'scan', 'info', 'trust', 'connect'):
            run = FakeBluetooth(fail=failure)
            def powered_off(args):
                if args == ['show']:
                    return 'Controller ' + ADDRESS + '\nPowered: no'
                return run(args)
            pair.cycle(powered_off, lambda _: None)
            if failure != 'connect':
                self.assertFalse(run.connected)

    def test_unrelated_device_is_not_paired(self):
        run = FakeBluetooth()
        def keyboard(args):
            output = run(args)
            return output.replace('Amazon Fire TV Remote', 'Keyboard') if output else output
        pair.cycle(keyboard, lambda _: None)
        self.assertFalse(run.paired)

    def test_command_failures_and_timeout(self):
        for error in (FileNotFoundError(), subprocess.TimeoutExpired('bluetoothctl', 45)):
            with patch.object(pair.subprocess, 'run', side_effect=error):
                self.assertIsNone(pair.run_command(['show']))
        for code, output in ((1, ''), (0, 'Failed to pair: org.bluez.Error.Failed')):
            with patch.object(pair.subprocess, 'run', return_value=subprocess.CompletedProcess([], code, output)):
                self.assertIsNone(pair.run_command(['show']))


if __name__ == '__main__':
    unittest.main()
