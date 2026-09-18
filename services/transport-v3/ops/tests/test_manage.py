import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

path = Path(__file__).resolve().parents[1] / 'azure' / 'manage.py'
spec = importlib.util.spec_from_file_location('manage', path)
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


class ManageTests(unittest.TestCase):
    def test_drain_is_idempotent_after_clean_process_exit(self):
        script = manage.operation_script('drain')
        self.assertIn('docker inspect', script)
        self.assertIn('[ "$state" = "exited 0" ]', script)
        self.assertIn('drain is idempotent', script)
        self.assertIn('CMUX_V3_OK', script)
        with tempfile.NamedTemporaryFile('w') as file:
            file.write(script)
            file.flush()
            subprocess.run(['bash', '-n', file.name], check=True)


if __name__ == '__main__':
    unittest.main()
