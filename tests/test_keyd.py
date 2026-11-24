import configparser
from pathlib import Path
import unittest


class RemoteMapTests(unittest.TestCase):
    def setUp(self):
        self.config = configparser.ConfigParser(interpolation=None, allow_no_value=True)
        self.config.read(Path(__file__).resolve().parents[1] / 'lib/keyd.conf')

    def test_remote_back_uses_stremio_history_shortcut(self):
        for key in ('back', 'esc'):
            with self.subTest(key=key):
                self.assertEqual(self.config['main'][key], 'backspace')

    def test_home_tap_goes_back_without_changing_hold_kill_switch(self):
        self.assertEqual(
            self.config['main']['homepage'],
            'timeout(backspace, 1500, command(/usr/local/lib/stremio-htpc/restart.sh))',
        )
        self.assertEqual(
            self.config['control+alt']['backspace'],
            'command(/usr/local/lib/stremio-htpc/restart.sh)',
        )


if __name__ == '__main__':
    unittest.main()
