"""screen-share-vs-pair-launch.sh sends the host half only once the viewer half is accepted.

A pinned half the controller refuses at submit (a fleet reservation on the viewer Mac, HTTP 409) used to leave
the host half in the pair wait for its whole 30 min before both failed. The launcher now waits for the viewer's
`cmux-ci: step` line and exits 5 without sending the host; a refused host cancels the queued viewer; a paused or
reserved Mac is refused (exit 6) before anything queues. --host-label reaches the host half only (a bench-only
worker needs --label bench). This runs the real launcher against a stub cmux-ci that logs each call.
"""
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAUNCH = ROOT / 'scripts/measure/screen-share-vs-pair-launch.sh'

STUB = r'''#!/bin/bash
echo "$*" >>"$CALLS"
if [[ "$1" == workers ]]; then
  name=$3 pause=-
  [[ "$name" == "${PAUSE_MAC:-}" ]] && pause=disk
  echo "workers: 1 of 2 match"
  echo "$name  state=online  healthy=yes  fits=-  paused=$pause  job=-  36 GB  last_seen=x"
  [[ "$name" == "${RESERVE_MAC:-}" ]] && echo "RESERVED $name: node:someone until 2026-11-28T03:10:52Z (lease-x)"
  exit 0
fi
[[ "$1" == cancel ]] && exit 0
case " $* " in
  *" --target-worker viewer-mac "*)
    if [[ -n "${REFUSE_VIEWER:-}" ]]; then echo "cmux-ci: controller HTTP 409: worker viewer-mac is reserved"; exit 1; fi
    # The viewer half blocks in the pair wait until the launcher cancels it (or 20 s, a test failure).
    if [[ -n "${REFUSE_HOST:-}" ]]; then echo "cmux-ci: step 0123456789abcdef01234567 (exclusive, key k)"; sleep 20; exit 1; fi ;;
  *" --target-worker host-mac "*)
    if [[ -n "${REFUSE_HOST:-}" ]]; then echo "cmux-ci: controller HTTP 409: worker host-mac is reserved"; exit 1; fi ;;
esac
echo "cmux-ci: step 0123456789abcdef01234567 (exclusive, key k)"
exit 0
'''


class LaunchRefusedHalfTests(unittest.TestCase):
    def launch(self, refuse_viewer=False, **env_extra):
        if shutil.which('bash') is None or shutil.which('git') is None or shutil.which('openssl') is None:
            self.skipTest('needs bash, git and openssl')
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        subprocess.run(['git', 'init', '-q', str(tmp)], check=True)
        (tmp / 'launch.sh').write_text(LAUNCH.read_text())
        bin_dir = tmp / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'cmux-ci').write_text(STUB)
        (bin_dir / 'cmux-ci').chmod(0o755)
        calls = tmp / 'calls'
        env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', CALLS=str(calls), OUT=str(tmp / 'out'))
        if refuse_viewer:
            env['REFUSE_VIEWER'] = '1'
        env.update(env_extra)
        run = subprocess.run(['bash', str(tmp / 'launch.sh'), 'host-mac', 'viewer-mac', '--ref', 'a' * 40,
                              '--viewer-ip', '10.0.0.2', '--host-label', 'bench'],
                             cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
        lines = calls.read_text().splitlines() if calls.exists() else []
        return run, [c for c in lines if not c.startswith(('workers ', 'cancel '))], lines

    def test_a_refused_viewer_half_never_sends_the_host(self):
        run, calls, _ = self.launch(refuse_viewer=True)
        self.assertEqual(run.returncode, 5, run.stdout + run.stderr)
        self.assertIn('reserved', run.stderr)
        self.assertEqual(len(calls), 1, calls)
        self.assertIn('--target-worker viewer-mac', calls[0])

    def test_an_accepted_viewer_half_sends_the_host_with_its_labels(self):
        run, calls, _ = self.launch(refuse_viewer=False)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        host = [c for c in calls if '--target-worker host-mac' in c]
        viewer = [c for c in calls if '--target-worker viewer-mac' in c]
        self.assertEqual((len(host), len(viewer)), (1, 1), calls)
        self.assertIn('--label bench', host[0])
        self.assertNotIn('--label bench', viewer[0])


    def test_a_paused_or_reserved_mac_is_refused_before_anything_queues(self):
        for extra, word in (({'PAUSE_MAC': 'viewer-mac'}, 'paused=disk'), ({'RESERVE_MAC': 'host-mac'}, 'RESERVED host-mac')):
            run, calls, _ = self.launch(**extra)
            self.assertEqual(run.returncode, 6, run.stdout + run.stderr)
            self.assertIn(word, run.stderr)
            self.assertEqual(calls, [])

    def test_a_refused_host_half_cancels_the_queued_viewer(self):
        start = time.monotonic()
        run, calls, lines = self.launch(REFUSE_HOST='1')
        self.assertEqual(run.returncode, 5, run.stdout + run.stderr)
        self.assertLess(time.monotonic() - start, 15, 'the launcher waited out the viewer instead of cancelling it')
        self.assertIn('cancel 0123456789abcdef01234567 --reason screen-share-vs-pair-launch', ' '.join(lines))


if __name__ == '__main__':
    unittest.main()
