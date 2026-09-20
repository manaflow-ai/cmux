"""Execute checkout failure diagnostics in an empty workspace."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class CheckoutDiagnosticsTests(unittest.TestCase):
    def test_empty_checkout_keeps_evidence_and_failure(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/ci.yml').read_text())
        for job in ('app-host-unit-tests', 'macos-compile-admission'):
            with self.subTest(job=job), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                commands = root / 'bin'
                commands.mkdir()
                for command in ('scutil', 'route', 'ifconfig', 'dscacheutil', 'curl'):
                    executable = commands / command
                    executable.write_text(f'#!/bin/sh\necho probe-{command}\nexit 9\n')
                    executable.chmod(0o755)
                step = next(s for s in workflow['jobs'][job]['steps']
                            if s['name'] == 'Diagnose checkout network failure')
                env = dict(os.environ, PATH=str(commands), RUNNER_NAME='warp-test')
                result = subprocess.run(['/bin/bash', '-e', '-c', step['run']],
                                        cwd=root, env=env, capture_output=True,
                                        text=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                output = result.stdout + result.stderr
                for command in ('scutil', 'route', 'ifconfig', 'dscacheutil', 'curl'):
                    self.assertIn(f'probe-{command}', output)
                self.assertIn('end network diagnostics', output)


if __name__ == '__main__':
    unittest.main()
