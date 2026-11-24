import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import addons
import guest


class GuestTests(unittest.TestCase):
    def test_fresh_profile_is_unauthenticated_and_contains_every_descriptor(self):
        descriptors = [{'transportUrl': 'https://addon.example/manifest.json'}]
        with tempfile.TemporaryDirectory() as directory:
            self.assertTrue(guest.seed(directory, descriptors))
            storage = Path(directory) / '.var/app/com.stremio.Stremio/data/stremio/storage'
            self.assertEqual(len((storage / 'salt').read_bytes()), 8)
            database = next(storage.glob('*/*/LocalStorage/localstorage.sqlite3'))
            with sqlite3.connect(database) as connection:
                rows = {k: json.loads(v.decode('utf-16-le'))
                        for k, v in connection.execute('SELECT * FROM ItemTable')}
            self.assertEqual(rows['schema_version'], 2)
            self.assertIsNone(rows['profile']['auth'])
            self.assertEqual(rows['profile']['addons'], descriptors)
            self.assertTrue(rows['profile']['settings']['hardwareDecoding'])
            self.assertEqual(next(storage.glob('*/*/origin')).read_bytes(),
                             bytes.fromhex('04000000016874747009000000013132372e302e302e3101ce2c') * 2)
            before = database.read_bytes()
            self.assertFalse(guest.seed(directory, [{'transportUrl': 'changed'}]))
            self.assertEqual(database.read_bytes(), before)

    def test_existing_storage_is_never_modified_even_without_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            storage = Path(directory) / '.var/app/com.stremio.Stremio/data/stremio/storage'
            storage.mkdir(parents=True)
            (storage / 'unrecognized').write_text('keep this')
            self.assertFalse(guest.seed(directory, [{}]))
            self.assertEqual(list(storage.iterdir()), [storage / 'unrecognized'])

    def test_bad_descriptors_leave_no_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(TypeError):
                guest.seed(directory, [object()])
            self.assertFalse(list(Path(directory).glob('**/storage')))
            with self.assertRaises(ValueError):
                guest.seed(directory, [])

    def test_fetches_all_manifests_and_deduplicates_before_any_write(self):
        manifest = dict(id='test', version='1.0.0', name='Test', resources=[], types=[], catalogs=[])
        urls = [*addons.OFFICIAL_URLS, 'https://custom.example/manifest.json']
        with patch.object(addons, 'request', return_value=manifest) as fetch:
            result = addons.descriptors([*urls, urls[-1]])
        self.assertEqual(fetch.call_count, 3)
        self.assertEqual([x['transportUrl'] for x in result], urls)
        self.assertEqual(result[0]['flags'], {'official': True, 'protected': True})
        self.assertEqual(result[-1]['flags'], {'official': False, 'protected': False})
        with patch.object(addons, 'request', return_value={}):
            with self.assertRaises(ValueError):
                addons.descriptors(urls)


if __name__ == '__main__':
    unittest.main()
