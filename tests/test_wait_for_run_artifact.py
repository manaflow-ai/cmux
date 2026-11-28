#!/usr/bin/env python3
"""The classic nightly's verify job queues beside signing and waits in-job for the signed app.

hosted#1103: classic main nightly runs piled up behind macOS runner pickups. verify-signed-nightly needed
build-sign-notarize-nightly, so GitHub queued it on blacksmith-6vcpu-macos-26 only when signing ended, and the
pickup was longer than the job: 8.1 min in run 46092619778 (signing ended 02:21:36Z, verify started 02:29:40Z)
and 9.5 min in run 46095010445 (02:18:44Z, 02:28:12Z). The class: a short job on a saturated label that
`needs:` its producer pays the whole pickup after it. The fix: need the producer's own predecessors, so both
are queued together, and wait for the producer's artifact in the job (scripts/ci/wait_for_run_artifact.py).

1. wait_for_run_artifact.wait: returns 0 once the artifact is listed, 1 when the producer completed without
   it (after one more look), 1 at the deadline; a failed read is retried and decides nothing.
2. nightly.yml verify-signed-nightly: does not need build-sign-notarize-nightly, runs whenever signing would,
   waits for each artifact signing uploads before downloading it, can read the run's artifacts, and keeps its
   runs-on string byte for byte (rule 6 of tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py:
   bundle code runs on a literal ephemeral label, a clean image).
"""

from __future__ import annotations

import io
import sys
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import wait_for_run_artifact as waiter  # noqa: E402

NAME = "cmux-nightly-signed-app-arm64-abc1234"
JOB = "build-sign-notarize-nightly (arm64)"
VERIFY_RUNS_ON = (
    "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.run_attempt > 1 && "
    "needs.pick-classic-sign-runner.outputs.attempt != github.run_attempt && "
    "needs.pick-classic-sign-runner.outputs.alternate || needs.pick-classic-sign-runner.outputs.runner || "
    "'blacksmith-6vcpu-macos-26' }}"
)


class FakeRun:
    """A run whose artifact list and producer status change over polls; reads may fail."""

    def __init__(self, artifact_at=None, done_at=None, fail_at=(), conclusion="failure", extra_jobs=0):
        self.polls = self.calls = 0
        self.artifact_at, self.done_at, self.fail_at = artifact_at, done_at, set(fail_at)
        self.conclusion, self.extra_jobs = conclusion, extra_jobs
        self.now = 0.0

    def get(self, path):
        self.calls += 1
        if self.calls in self.fail_at:
            raise urllib.error.URLError("503")
        if "/artifacts?" in path:
            self.polls += 1
            listed = self.artifact_at is not None and self.polls > self.artifact_at
            return {"artifacts": [{"name": NAME, "expired": False}] if listed else [{"name": "other"}]}
        page = int(path.rsplit("page=", 1)[1])
        jobs = [{"name": f"filler {i}", "status": "completed", "conclusion": "success"} for i in range(self.extra_jobs)]
        done = self.done_at is not None and self.polls > self.done_at
        jobs.append({"name": JOB, "status": "completed" if done else "in_progress",
                     "conclusion": self.conclusion if done else None})
        return {"jobs": jobs[(page - 1) * 100: page * 100]}

    def sleep(self, seconds):
        self.now += seconds

    def clock(self):
        return self.now

    def wait(self, deadline=600):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = waiter.wait(NAME, JOB, repo="o/r", run_id="1", interval=10, deadline=deadline,
                               get=self.get, sleep=self.sleep, clock=self.clock)
        return code, err.getvalue()


class WaitTests(unittest.TestCase):
    def test_returns_once_the_artifact_is_uploaded(self):
        run = FakeRun(artifact_at=3)
        self.assertEqual(run.wait()[0], 0)
        self.assertEqual(run.now, 30)

    def test_producer_that_ends_without_the_upload_fails_the_wait(self):
        run = FakeRun(done_at=2)
        code, err = run.wait()
        self.assertEqual(code, 1)
        self.assertIn("ended (failure) without uploading", err)

    def test_upload_racing_the_producer_end_counts(self):
        # Listed on the look after the job read that saw the producer completed.
        run = FakeRun(artifact_at=3, done_at=2, conclusion="success")
        self.assertEqual(run.wait()[0], 0)

    def test_producer_found_past_the_first_jobs_page(self):
        run = FakeRun(done_at=0, extra_jobs=150)
        self.assertEqual(run.wait()[0], 1)

    def test_failed_reads_are_retried(self):
        run = FakeRun(artifact_at=2, fail_at=(1, 2))
        code, err = run.wait()
        self.assertEqual(code, 0)
        self.assertIn("read failed, retrying", err)

    def test_deadline(self):
        run = FakeRun()
        code, err = run.wait(deadline=60)
        self.assertEqual(code, 1)
        self.assertIn("was not uploaded within 60 s", err)


class VerifyJobTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        jobs = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8"))["jobs"]
        cls.sign, cls.verify = jobs["build-sign-notarize-nightly"], jobs["verify-signed-nightly"]

    def step(self, name):
        steps = self.verify["steps"]
        return next(i for i, s in enumerate(steps) if s.get("name") == name), steps

    def test_queued_beside_signing(self):
        self.assertNotIn("build-sign-notarize-nightly", self.verify["needs"])
        self.assertEqual(set(self.verify["needs"]), set(self.sign["needs"]))
        # Runs exactly when signing runs, so a skipped signing job does not leave verify waiting.
        self.assertEqual(self.verify["if"], self.sign["if"])

    def test_runs_on_unchanged(self):
        self.assertEqual(self.verify["runs-on"], VERIFY_RUNS_ON)

    def test_reads_the_run_only(self):
        self.assertEqual(self.verify["permissions"], {"contents": "read", "actions": "read"})

    def test_waits_for_each_signing_upload_before_its_download(self):
        for wait_name, download_name in (("Wait for the signed app", "Download signed app"),
                                         ("Wait for the final DMG", "Download final DMG")):
            with self.subTest(wait_name):
                wait_at, steps = self.step(wait_name)
                download_at, _ = self.step(download_name)
                self.assertEqual(wait_at + 1, download_at)
                wait_step, download = steps[wait_at], steps[download_at]
                self.assertEqual(wait_step.get("if"), download.get("if"))
                run = wait_step["run"]
                self.assertIn("scripts/ci/wait_for_run_artifact.py", run)
                self.assertIn(f'--name "{download["with"]["name"]}"', run)
                self.assertIn('--job "build-sign-notarize-nightly (${{ matrix.variant }})"', run)
                self.assertEqual(wait_step["env"]["GH_TOKEN"], "${{ github.token }}")
                # The in-job wait outlives no step budget and the job outlives the wait.
                deadline = float(run.split("--deadline", 1)[1].split()[0])
                self.assertLess(deadline, wait_step["timeout-minutes"] * 60)
                self.assertLess(wait_step["timeout-minutes"], self.verify["timeout-minutes"])

    def test_signing_still_uploads_what_verify_waits_for(self):
        uploads = [s["with"]["name"] for s in self.sign["steps"]
                   if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
        self.assertIn("cmux-${{ needs.decide.outputs.channel }}-signed-app-${{ matrix.variant }}-"
                      "${{ needs.decide.outputs.short_sha }}", uploads)
        self.assertIn("cmux-nightly-variant-${{ matrix.variant }}", uploads)
        self.assertNotIn("name", self.sign)  # the check-run name is "build-sign-notarize-nightly (<variant>)"


if __name__ == "__main__":
    unittest.main()
