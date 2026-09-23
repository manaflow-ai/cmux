"""Execute the nightly tag step with a controlled Git transport."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NightlyTagPushTests(unittest.TestCase):
    def run_step(self, failures):
        workflow = (ROOT / '.github/workflows/nightly.yml').read_text()
        step = workflow.split('      - name: Move channel release tag to built commit\n', 1)[1]
        script = textwrap.dedent(step.split('        run: |\n', 1)[1].split('\n  #', 1)[0])
        script = script.replace('${{ needs.decide.outputs.head_sha }}', 'a' * 40)
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            git = directory / 'git'
            git.write_text('''#!/bin/bash
printf '%s\\n' "$@" >> "$ARGS"
if [ "$1" != push ]; then exit 0; fi
count=0
[ ! -f "$STATE" ] || count=$(cat "$STATE")
count=$((count + 1))
echo "$count" > "$STATE"
if [ "$count" -le "$FAILURES" ]; then
  echo 'Unable to determine if workflow can be created or updated due to timeout' >&2
  exit 1
fi
''')
            sleep = directory / 'sleep'
            sleep.write_text('#!/bin/bash\necho "$1" >> "$SLEEPS"\n')
            git.chmod(0o755)
            sleep.chmod(0o755)
            env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'],
                       STATE=tmp + '/count', ARGS=tmp + '/args', SLEEPS=tmp + '/sleeps',
                       FAILURES=str(failures), GITHUB_TOKEN='test-token',
                       GITHUB_REPOSITORY='manaflow-ai/cmux', CHANNEL_RELEASE_TAG='nightly')
            result = subprocess.run(['bash', '-e', '-c', script], env=env, capture_output=True, text=True)
            pauses = (directory / 'sleeps').read_text().splitlines() if (directory / 'sleeps').exists() else []
            return result, int((directory / 'count').read_text()), pauses, (directory / 'args').read_text()

    def test_immediate_success(self):
        result, count, pauses, args = self.run_step(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 1)
        self.assertEqual(pauses, [])
        self.assertIn('refs/tags/nightly\n--force\n', args)
        self.assertIn('tag\n-f\nnightly\n' + 'a' * 40 + '\n', args)

    def test_timeout_recovers(self):
        result, count, pauses, _ = self.run_step(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 3)
        self.assertEqual(pauses, ['5', '10'])

    def test_persistent_failure_stays_failed(self):
        result, count, pauses, _ = self.run_step(99)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(count, 3)
        self.assertEqual(pauses, ['5', '10'])


if __name__ == '__main__':
    unittest.main()
