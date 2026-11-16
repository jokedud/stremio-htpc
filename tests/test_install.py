import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.geteuid() == 0 and shutil.which('runuser'), 'requires root and runuser')
class SettingsProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.base.chmod(0o755)
        self.account = pwd.getpwnam('nobody')
        self.home = self.base / 'home'
        self.home.mkdir()
        os.chown(self.home, self.account.pw_uid, self.account.pw_gid)
        self.helper = self.base / 'settings.py'
        shutil.copyfile(ROOT / 'lib/settings.py', self.helper)

    def provision(self):
        installer = (ROOT / 'install.sh').read_text()
        start = installer.index('\nfor base in ')
        end = installer.index('\n# Ensure login shells', start)
        setup = installer[start:end].replace('/usr/local/lib/stremio-htpc/settings.py', str(self.helper))
        subprocess.run(
            ['bash', '-euc', 'user=$1; home=$2\n' + setup, 'settings-setup', 'nobody', str(self.home)],
            check=True, capture_output=True, text=True,
        )

    def assert_app_writable(self):
        app = self.home / '.var/app/com.stremio.Stremio'
        result = subprocess.run(
            ['runuser', '-u', 'nobody', '--', 'mkdir', '-p', str(app / 'data'), str(app / 'cache'), str(app / 'config')],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in (self.home / '.var', self.home / '.var/app', app):
            self.assertEqual(path.stat().st_uid, self.account.pw_uid)
            self.assertEqual(path.stat().st_gid, self.account.pw_gid)

    def test_fresh_user_can_create_flatpak_app_directories(self):
        self.provision()
        self.assert_app_writable()

    def test_rerun_repairs_root_owned_parents_without_changing_app_data(self):
        app = self.home / '.var/app/com.stremio.Stremio'
        app.mkdir(parents=True)
        existing = app / 'existing-data'
        existing.write_text('keep me')
        os.chown(existing, self.account.pw_uid, self.account.pw_gid)
        self.provision()
        self.provision()
        self.assert_app_writable()
        self.assertEqual(existing.read_text(), 'keep me')
        self.assertEqual(existing.stat().st_uid, self.account.pw_uid)


if __name__ == '__main__':
    unittest.main()
