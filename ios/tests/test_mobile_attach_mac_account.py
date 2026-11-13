"""scripts/lib/mobile-attach.sh reads the tagged Mac's account through `cmux whoami --json`.

The bundled CLI no longer has `auth status`; asking it always failed, so every
mac-rpc readiness check reported "did not reach signed-in auth status". This
drives cmux_attach_mac_auth_account against a fake cmux-debug-cli.sh.
Run: python3 ios/tests/test_mobile_attach_mac_account.py
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ATTACH = ROOT / 'scripts/lib/mobile-attach.sh'


def account(cli_body):
    with tempfile.TemporaryDirectory() as temp:
        repo = Path(temp)
        (repo / 'scripts').mkdir()
        cli = repo / 'scripts/cmux-debug-cli.sh'
        cli.write_text('#!/bin/sh\n' + cli_body)
        cli.chmod(0o755)
        script = f'source "{ATTACH}"; cmux_attach_mac_auth_account review-test "{repo}"'
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=30)


class MacAccountTests(unittest.TestCase):
    def test_reads_email_from_whoami(self):
        result = account('[ "$1 $2" = "whoami --json" ] || exit 9\n'
                         'echo \'{"signed_in":true,"user":"user_1","team":"team_1","email":"Person@Example.com"}\'\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'person@example.com')

    def test_accepts_the_older_auth_status_shape(self):
        result = account('echo \'{"signed_in":true,"user":{"id":"u","email":"person@example.com"}}\'\n')
        self.assertEqual(result.stdout, 'person@example.com')

    def test_signed_out_or_missing_email_fails(self):
        self.assertNotEqual(account('echo \'{"signed_in":false,"email":"person@example.com"}\'\n').returncode, 0)
        self.assertNotEqual(account('echo \'{"signed_in":true,"user":"user_1","email":null}\'\n').returncode, 0)
        self.assertNotEqual(account('exit 3\n').returncode, 0)


if __name__ == '__main__':
    unittest.main()
