import base64
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bundle


class BundleTests(unittest.TestCase):
    def test_bundle_embeds_helpers_and_private_urls_without_runtime_github_fetch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / 'installer.sh'
            urls = root / 'addons.local'
            urls.write_text('https://private.example/not-a-real-token/manifest.json\n')
            bundle.build(output, urls)
            script = output.read_text()
            subprocess.run(['bash', '-n', str(output)], check=True)
            payload = script.split("<<'STREMIO_HTPC_BUNDLE' | tar -xz -C \"$bundle\"\n")[1].split('STREMIO_HTPC_BUNDLE')[0]
            with tarfile.open(fileobj=io.BytesIO(base64.b64decode(payload))) as archive:
                self.assertEqual(set(archive.getnames()), {*bundle.FILES, 'addons.local'})
                self.assertEqual(archive.extractfile('addons.local').read(), urls.read_bytes())
            self.assertIn('HTPC_SOURCE_DIR="$bundle" bash "$bundle/install.sh"', script)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_generated_script_runs_the_embedded_installer_and_cleans_up(self):
        if os.geteuid() != 0 and not shutil.which('sudo'):
            self.skipTest('root or passwordless sudo required')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            for filename in bundle.FILES:
                path = source / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('test fixture')
            (source / 'install.sh').write_text('printf "%s\\n" "$HTPC_SOURCE_DIR"; cat "$HTPC_SOURCE_DIR/addons.txt"; exit 23\n')
            output = root / 'bundle.sh'
            bundle.build(output, source=source)
            # Run only this harmless fixture installer, never appliance setup.
            command = ['bash', str(output)]
            if os.geteuid() != 0:
                command = ['sudo', '-n', *command]
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode == 1 and 'password' in result.stderr:
                self.skipTest('root or passwordless sudo required')
            self.assertEqual(result.returncode, 23, result.stderr)
            staging = Path(result.stdout.splitlines()[0])
            self.assertFalse(staging.exists())
            self.assertIn('test fixture', result.stdout)

    def test_refuses_output_inside_the_checkout(self):
        with self.assertRaises(ValueError):
            bundle.build(Path(bundle.__file__).parent / 'private.sh')

    def test_embedded_addons_work_without_extra_addons_environment_variable(self):
        source = Path(bundle.__file__).parent
        block = (source / 'install.sh').read_text().split('if [[ -n ${EXTRA_ADDONS:-}')[1].split('unset EXTRA_ADDONS')[0]
        block = 'if [[ -n ${EXTRA_ADDONS:-}' + block
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config'
            config.mkdir()
            (root / 'addons.local').write_text('https://private.example/test/manifest.json\n')
            environment = {k: v for k, v in os.environ.items() if k != 'EXTRA_ADDONS'}
            environment['HTPC_SOURCE_DIR'] = str(root)
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', block.replace('/etc/stremio-htpc', str(config))],
                                    capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((config / 'addons.local').read_text(), (root / 'addons.local').read_text())
            self.assertEqual((config / 'addons.local').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
