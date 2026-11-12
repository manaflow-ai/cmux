"""ios/scripts/reload.sh --review argument contract; never invokes Apple tools.

--review is the end-of-task hand-off (AGENTS.md "Finishing a task"): always the
tag's isolated simulator plus the authenticated iPhone install. Flags that would
drop a leg or skip the auth gate must be refused before anything is built.
Run: python3 ios/tests/test_reload_review_flag.py
"""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
RELOAD = ROOT / 'ios/scripts/reload.sh'


def reload(*args):
    return subprocess.run(['bash', str(RELOAD), *args], cwd=ROOT, capture_output=True, text=True, timeout=30)


class ReviewFlagTests(unittest.TestCase):
    def test_help_documents_review(self):
        result = reload('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('--review', result.stdout)
        self.assertIn('verify-iphone-auth.sh', result.stdout)

    def test_review_refuses_flags_that_drop_a_leg_or_the_auth_gate(self):
        for extra in (['--simulator-only'], ['--device-only'], ['--no-launch'], ['--no-sign-in'],
                      ['--no-attach'], ['--no-setup'], ['--prod-auth'], ['--simulator', 'iPhone 17'],
                      ['--device-name', 'Phone']):
            with self.subTest(extra=extra):
                result = reload('--tag', 'review-test', '--review', *extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('--review always installs', result.stderr)

    def test_workspace_needs_review(self):
        result = reload('--tag', 'review-test', '--workspace', 'https://github.com/manaflow-ai/cmux/pull/1')
        self.assertEqual(result.returncode, 2)
        self.assertIn('--workspace applies only to --review', result.stderr)


if __name__ == '__main__':
    unittest.main()
