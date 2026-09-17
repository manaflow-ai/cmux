import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


def load(name):
    path = Path(__file__).resolve().parents[1] / 'azure' / (name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


snapshot = load('observe_snapshot')
observe = load('observe')


class ObserveTests(unittest.TestCase):
    def test_no_user_material_or_unknown_labels_can_enter_snapshot(self):
        body = '\n'.join(name + ' 1' for name in snapshot.METRICS)
        body += '\nsecret_token abc\ncmux_v3_circuits{team="secret"} 9\n'
        health = json.dumps({'draining': False, 'peer_id': 'secret-device', 'token': 'secret-grant'})
        value = snapshot.snapshot(lambda path: body if path == 'metrics' else health)
        self.assertTrue(value['scrape_ok'])
        self.assertNotIn('secret', json.dumps(value))
        self.assertLess(len(json.dumps(value)), 4096)

    def test_missing_invalid_or_failed_scrape_still_emits_failure(self):
        for body in ['cmux_v3_ready 1', 'cmux_v3_circuits NaN', 'cmux_v3_ready -1']:
            self.assertFalse(snapshot.snapshot(lambda _: body)['scrape_ok'])
        def denied(_):
            raise OSError('secret in error response')
        value = snapshot.snapshot(denied)
        self.assertFalse(value['scrape_ok'])
        self.assertNotIn('secret', json.dumps(value))
        body = '\n'.join(name + ' 1' for name in snapshot.METRICS)
        for malformed in ['[]', 'null', '{"draining":"false"}']:
            self.assertFalse(snapshot.snapshot(lambda path: body if path == 'metrics' else malformed)['scrape_ok'])

    def test_collector_shell_valid_and_runs_without_relay_credentials(self):
        script = observe.install_script()
        with tempfile.NamedTemporaryFile('w') as f:
            f.write(script); f.flush()
            subprocess.run(['bash', '-n', f.name], check=True)
        self.assertIn('DynamicUser=yes', script)
        self.assertIn('IPAddressAllow=127.0.0.1/32', script)
        self.assertNotIn('/etc/cmux-v3/', script)
        self.assertNotIn('docker', script)


if __name__ == '__main__':
    unittest.main()
