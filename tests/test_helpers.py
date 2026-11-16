import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / 'lib' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


settings = load('settings')
addons = load('addons')


class SettingsTests(unittest.TestCase):
    def test_empty_merge_and_rerun(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'server-settings.json'
            settings.merge(path)
            settings.merge(path)
            self.assertEqual(json.loads(path.read_text()), {'cacheSize': 21474836480, 'transcodeHardwareAccel': True})

    def test_preserves_unknown_and_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'server-settings.json'
            original = '{"custom": 12, "cacheSize": 1}'
            path.write_text(original)
            settings.merge(path)
            settings.merge(path)
            self.assertEqual(json.loads(path.read_text())['custom'], 12)
            self.assertEqual(path.with_suffix('.json.pre-htpc').read_text(), original)

    def test_malformed_not_clobbered(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'server-settings.json'
            for content in ('bad-json', '[]'):
                path.write_text(content)
                with self.assertRaises(ValueError):
                    settings.merge(path)
                self.assertEqual(path.read_text(), content)


class AddonTests(unittest.TestCase):
    def test_merge_shapes_and_deduplication(self):
        existing = {'transportUrl': 'https://existing/manifest.json', 'flags': {'protected': True}}
        calls = []

        def fake_api(method, payload):
            calls.append((method, payload))
            return {'login': {'authKey': 'test-key'}, 'addonCollectionGet': {'addons': [existing]}, 'addonCollectionSet': True, 'logout': True}[method]

        manifest = dict(id='test', version='1.0.0', name='test', resources=[], types=[], catalogs=[])
        with patch.object(addons, 'api', side_effect=fake_api), patch.object(addons, 'request', return_value=manifest) as fetch:
            addons.sync([existing['transportUrl'], 'https://new/manifest.json', 'https://new/manifest.json'], 'test', 'not-real')
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(calls[0][1]['type'], 'Login')
        self.assertTrue(calls[1][1]['update'])
        self.assertEqual(calls[2][1]['addons'][0], existing)
        self.assertEqual(len(calls[2][1]['addons']), 2)
        self.assertEqual(calls[-1][0], 'logout')

    def test_empty_collection(self):
        with patch.object(addons, 'api', side_effect=[{'authKey': 'test'}, {'addons': []}, True, True]) as api:
            addons.sync([], 'test', 'test')
        self.assertEqual(api.call_args_list[2].args[1]['addons'], [])

    def test_manifest_failure_does_not_set(self):
        with patch.object(addons, 'api', side_effect=[{'authKey': 'test'}, {'addons': []}, True]) as api, patch.object(addons, 'request', return_value={}):
            with self.assertRaises(ValueError):
                addons.sync(['https://invalid/manifest.json'], 'test', 'test')
        self.assertNotIn('addonCollectionSet', [call.args[0] for call in api.call_args_list])

    def test_api_error(self):
        with patch.object(addons, 'request', return_value={'error': {'message': 'not logged'}}):
            with self.assertRaises(ValueError):
                addons.api('login', {})

    def test_url_validation_and_local_merge(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(addons, 'CONFIG', Path(directory)):
            self.assertEqual(addons.read_urls(), [])
            path = Path(directory) / 'addons.txt'
            path.write_text('https://test/manifest.json\nhttps://test/manifest.json')
            self.assertEqual(addons.read_urls(), ['https://test/manifest.json'])
            path.write_text('http://test/manifest.json')
            with self.assertRaises(ValueError):
                addons.read_urls()


if __name__ == '__main__':
    unittest.main()
