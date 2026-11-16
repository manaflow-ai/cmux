"""ios/scripts/reload.sh --review: the hand-off reports what each fleet job is really doing.

A real-phone test on 2026-11-16 (feat-cmux-next a5eb286482) found the hand-off:
- ended on `gh pr view` for a branch with no PR, and called it "fleet build or install failed";
- said "the fleet Mac build did not finish" when the Mac job was done;
- said "fleet build or install failed" when another run was only still waiting;
- waited up to 24 hours on a starved iOS queue without a word;
- ran in a clone whose pushes skipped the pre-push checks.

These tests run reload.sh's --review functions with a fake fleet installer, cmux-ci and gh. They never invoke
Apple tools. Run: python3 ios/tests/test_reload_review_handoff.py
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RELOAD = ROOT / 'ios/scripts/reload.sh'
MAC_JOB, IOS_JOB = 'a' * 24, 'b' * 24
GIT_ENV = {'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_AUTHOR_NAME': 't',
           'GIT_AUTHOR_EMAIL': 't@example.invalid', 'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.invalid'}
QUEUED = {'id': IOS_JOB, 'state': 'queued', 'placement_wait': 'waiting_for_worker: 9 online worker(s) can run '
          '[ios ram48]: 8 busy, 1 claim-paused (runner_job (1)); 2 offline; 2 older queued job(s) ask for the same labels'}
DONE_MAC = {'id': MAC_JOB, 'state': 'done', 'worker': 'cmux-linux-pool-1'}

# A fake build-fleet/ios-reload.py: saves the job receipts the real one saves, logs its arguments, exits FAKE_RC.
FAKE_IOS_RELOAD = r'''#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG/ios-reload.calls"
printf '%s\n' "${CMUX_IOS_RELOAD_RESUME:-}" >> "$FAKE_LOG/resume"
if [[ "${FAKE_SUBMIT:-1}" == 1 ]]; then
  mkdir -p "$FAKE_STATE"
  printf '{"id":"%s"}' "aaaaaaaaaaaaaaaaaaaaaaaa" > "$FAKE_STATE/cmux-submit.json"
  printf '{"id":"%s"}' "bbbbbbbbbbbbbbbbbbbbbbbb" > "$FAKE_STATE/ios-submit.json"
fi
exit "${FAKE_RC:-0}"
'''
FAKE_CMUX_CI = r'''#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG/cmux-ci.calls"
case "$1" in
  status) cat "$FAKE_LOG/status.json" ;;
  publish-hq) exit 0 ;;
  *) exit 9 ;;
esac
'''


class HandoffHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = Path(self.tmp.name)
        self.home = tmp / 'home'
        self.home.mkdir()
        self.repo = tmp / 'cmux'
        (self.repo / 'ios/scripts').mkdir(parents=True)
        shutil.copy2(RELOAD, self.repo / 'ios/scripts/reload.sh')
        env = {**os.environ, **GIT_ENV}
        for args in (['init', '-q'], ['add', '-A'], ['commit', '-q', '-m', 'one']):
            subprocess.run(['git', '-C', str(self.repo), *args], check=True, env=env, capture_output=True)
        self.sha = subprocess.run(['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], capture_output=True, text=True,
                                  check=True).stdout.strip()
        self.bin = tmp / 'bin'
        self.bin.mkdir()
        self.log = tmp / 'log'
        self.log.mkdir()
        self.state = self.home / 'Library/Application Support/cmux-dev/ios-builds/handoff-1' / self.sha
        for name, body in (('ios-reload', FAKE_IOS_RELOAD), ('cmux-ci', FAKE_CMUX_CI),
                           ('gh', '#!/bin/sh\necho \'no pull requests found for branch "x"\' >&2\nexit 1\n'),
                           ('verify-remote.sh', f'#!/bin/sh\nmkdir -p {tmp}/evidence\necho {tmp}/evidence\n')):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.status([DONE_MAC, QUEUED])

    def tearDown(self):
        self.tmp.cleanup()

    def status(self, jobs):
        (self.log / 'status.json').write_text(json.dumps(jobs))

    def calls(self, name):
        path = self.log / f'{name}.calls'
        return path.read_text().splitlines() if path.exists() else []

    def functions(self):
        text = (self.repo / 'ios/scripts/reload.sh').read_text()
        start = text.index('review_cmux_ci() {')
        end = text.index('\nif [[ "$REVIEW" -eq 1 ]]; then\n  review_resolve_phones')
        return text[start:end]

    def handoff(self, phones=1, wait='', **env):
        targets = ' '.join(f'"0000814{i}-001E3C840E8B001C\tPhone{i} (iPhone17,4, 0000814{i}-001E3C840E8B001C)"'
                           for i in range(phones))
        script = ('set -uo pipefail\n'
                  f'TAG=handoff-1\nIOS_DIR="{self.repo}/ios"\nREQUESTED_DEVICE_ID=""\nREVIEW_WORKSPACE=""\n'
                  f'REVIEW_WAIT={wait or 1800}\nREVIEW_WAIT_SET={1 if wait else 0}\nREVIEW_FAILED=0\n'
                  f'REVIEW_PHONE_STATUS=""\nREVIEW_MAC_STATUS=""\nREVIEW_SIM_STATUS=""\n'
                  'review_phone_result() { REVIEW_PHONE_STATUS+="${REVIEW_PHONE_STATUS:+$\'\\n  \'}$1"; }\n'
                  + self.functions() +
                  f'\nREVIEW_TARGETS=({targets})\nREVIEW_IOS_RELOAD=("{self.bin}/ios-reload")\n'
                  f'REVIEW_VERIFY_REMOTE="{self.bin}/verify-remote.sh"\n'
                  'review_fleet_handoff; exit $?\n')
        run_env = {**os.environ, 'HOME': str(self.home), 'PATH': f'{self.bin}:/usr/bin:/bin',
                   'CMUX_CI': str(self.bin / 'cmux-ci'), 'FAKE_LOG': str(self.log), 'FAKE_STATE': str(self.state),
                   **env}
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True, env=run_env, timeout=60)


class ReviewReadyReportsRealJobStates(HandoffHarness):
    def test_another_run_waiting_is_in_progress_and_the_finished_mac_build_is_published(self):
        # Run E: the Mac job is done, the iOS job is queued, and an earlier run still holds the tag (exit 76).
        result = self.handoff(FAKE_RC='76')
        self.assertEqual(result.returncode, 76, result.stdout + result.stderr)
        out = result.stdout
        self.assertNotIn('did not finish', out)
        self.assertNotIn('fleet build or install failed', out)
        self.assertNotIn('BLOCKED', out)
        self.assertIn(f'Mac build: job {MAC_JOB}: done on cmux-linux-pool-1', out)
        self.assertIn(f'iOS build: job {IOS_JOB}: queued; place in queue: 3 among jobs for the same labels; '
                      'waiting because: waiting_for_worker: 9 online worker(s)', out)
        self.assertIn(f'(fleet job {MAC_JOB}, head {self.sha[:12]}, published to HQ)', out)
        self.assertIn(['publish-hq', MAC_JOB], [line.split() for line in self.calls('cmux-ci')])
        self.assertIn('in progress: another run is waiting on this tag\'s fleet jobs', out)
        self.assertIn(f'not run yet: the iOS fleet build (job {IOS_JOB}) is queued', out)
        self.assertIn('Resume (waits on the same jobs, never resubmits):\n  ios/scripts/reload.sh --review --tag handoff-1',
                      out)

    def test_a_deadline_is_waiting_not_failed_and_stops_before_the_next_phone(self):
        result = self.handoff(phones=2, FAKE_RC='75')
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertEqual(len(self.calls('ios-reload')), 1)
        self.assertIn('Phone0 (iPhone17,4, 00008140-001E3C840E8B001C): waiting, not failed: the fleet jobs are still '
                      'queued or running after 1800s', result.stdout)
        self.assertIn('Phone1 (iPhone17,4, 00008141-001E3C840E8B001C): not started: waiting on the same fleet jobs',
                      result.stdout)
        self.assertNotIn('BLOCKED', result.stdout)

    def test_the_default_deadline_is_30_minutes_and_wait_passes_through(self):
        self.handoff(FAKE_RC='75')
        self.assertIn('--wait 1800', self.calls('ios-reload')[0])
        self.handoff(wait='600', FAKE_RC='75')
        self.assertIn('--wait 600', self.calls('ios-reload')[1])
        self.assertEqual((self.log / 'resume').read_text().splitlines()[1],
                         'ios/scripts/reload.sh --review --tag handoff-1 --wait 600')

    def test_a_failure_before_submission_says_so(self):
        result = self.handoff(FAKE_RC='1', FAKE_SUBMIT='0')
        self.assertEqual(result.returncode, 1)
        self.assertIn('BLOCKED, the fleet hand-off failed (exit 1; see the error above)', result.stdout)
        self.assertIn('not submitted: the hand-off stopped before it submitted the fleet jobs', result.stdout)
        self.assertIn('Mac build: not submitted', result.stdout)

    def test_a_failed_job_is_blocked_with_its_log(self):
        self.status([DONE_MAC, {'id': IOS_JOB, 'state': 'failed', 'worker': 'aws-m4pro-2'}])
        result = self.handoff(FAKE_RC='1')
        self.assertEqual(result.returncode, 1)
        self.assertIn(f'iOS build: job {IOS_JOB}: failed on aws-m4pro-2; see cmux-ci log {IOS_JOB}', result.stdout)
        self.assertIn(f'BLOCKED: the iOS fleet build (job {IOS_JOB}) failed', result.stdout)

    def test_a_ready_hand_off_runs_the_fleet_simulator(self):
        self.status([DONE_MAC, {'id': IOS_JOB, 'state': 'done', 'worker': 'aws-m4pro-2'}])
        result = self.handoff(FAKE_RC='0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('installed, signed in (verify-iphone-auth PASS)', result.stdout)
        self.assertIn('fleet simulator, signed in (agent account)', result.stdout)
        self.assertNotIn('Resume', result.stdout)

    def test_a_branch_without_a_pull_request_builds_under_the_task_workspace(self):
        result = self.handoff(FAKE_RC='75')
        self.assertIn('--workspace ios-review/handoff-1', self.calls('ios-reload')[0])
        self.assertNotIn('no pull requests found', result.stdout)


class HooksRequired(unittest.TestCase):
    """--review refuses in a clone whose pushes would skip cmux's pre-push checks."""

    def clone(self, tmp, hooks):
        repo = Path(tmp) / 'cmux'
        (repo / 'ios/scripts').mkdir(parents=True)
        shutil.copy2(RELOAD, repo / 'ios/scripts/reload.sh')
        subprocess.run(['git', 'init', '-q', str(repo)], check=True, env={**os.environ, **GIT_ENV})
        if hooks:
            common = repo / '.git/cmux-git-hooks'
            common.mkdir()
            (common / 'pre-push').write_text('#!/bin/sh\n')
            (common / 'pre-push').chmod(0o755)
            subprocess.run(['git', '-C', str(repo), 'config', 'core.hooksPath', str(common)], check=True)
        return repo

    def review(self, repo):
        env = {**os.environ, **GIT_ENV, 'HOME': str(repo.parent)}
        return subprocess.run(['bash', str(repo / 'ios/scripts/reload.sh'), '--review', '--tag', 'hooks-1'],
                              cwd=repo, capture_output=True, text=True, env=env, timeout=60)

    def test_a_clone_without_hooks_is_refused_with_the_install_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.clone(tmp, hooks=False)
            result = self.review(repo)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("does not run cmux's git hooks", result.stderr)
        self.assertIn(f'{repo}/scripts/install-git-hooks.sh', result.stderr.replace('/private', ''))

    def test_a_worktree_of_a_clone_with_hooks_passes_the_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = self.clone(tmp, hooks=True)
            env = {**os.environ, **GIT_ENV}
            subprocess.run(['git', '-C', str(repo), 'add', '-A'], check=True, env=env)
            subprocess.run(['git', '-C', str(repo), 'commit', '-q', '-m', 'one'], check=True, env=env)
            worktree = Path(tmp) / 'wt'
            subprocess.run(['git', '-C', str(repo), 'worktree', 'add', '-q', str(worktree)], check=True, env=env)
            result = self.review(worktree)
        self.assertNotIn("does not run cmux's git hooks", result.stderr)


class ReviewWaitFlag(unittest.TestCase):
    def reload(self, *args):
        return subprocess.run(['bash', str(RELOAD), *args], cwd=ROOT, capture_output=True, text=True, timeout=30)

    def test_wait_needs_review(self):
        result = self.reload('--tag', 'wait-1', '--wait', '60')
        self.assertEqual(result.returncode, 2)
        self.assertIn('--wait applies only to --review', result.stderr)

    def test_wait_takes_positive_seconds(self):
        result = self.reload('--tag', 'wait-1', '--review', '--wait', '0')
        self.assertEqual(result.returncode, 2)
        self.assertIn('--wait takes a positive number of seconds', result.stderr)

    def test_help_documents_the_deadline(self):
        result = self.reload('--help')
        self.assertIn('--wait seconds (default 1800)', result.stdout)
        self.assertIn('exits 75', result.stdout)


if __name__ == '__main__':
    unittest.main()
