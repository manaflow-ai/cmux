#!/usr/bin/env python3
"""scripts/ci/hosted_queue_stall.py: the nightly signer route leaves hosted Ubuntu once this run saw it stall.

Run 41683652930 (2026-11-03): pick-nightly-sign-runner waited 526 s and signer-app 532 s on GitHub-hosted
ubuntu-24.04, and nothing failed them over (a started nightly is never cancelled, so no re-run route applies).
"""

from __future__ import annotations

import datetime as dt
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import hosted_queue_stall as stall  # noqa: E402

NOW = dt.datetime(2026, 11, 3, 17, 46, 30, tzinfo=dt.timezone.utc)


def at(seconds_ago: float) -> str:
    return (NOW - dt.timedelta(seconds=seconds_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(name: str, created: float, started: float | None, labels=("ubuntu-24.04",), status: str | None = None) -> dict:
    return {"name": name, "labels": list(labels), "created_at": at(created),
            "started_at": at(started) if started is not None else None,
            "status": status or ("queued" if started is None else "completed")}


class Verdict(unittest.TestCase):
    def test_run_41683652930_is_stalled(self):
        # signer-build 327 s, the pick itself 526 s (created 17:37:19, started 17:46:05).
        jobs = [job("signer-build", created=1268, started=941), job("pick-nightly-sign-runner", 551, 25, status="in_progress"),
                job("build-nightly-app", 1205, 1200, labels=("glaeda-nightly-only-m4pro",))]
        state, why = stall.verdict(jobs, NOW)
        self.assertEqual(state, "stalled")
        self.assertIn("pick-nightly-sign-runner", why)

    def test_a_moving_queue_keeps_hosted(self):
        jobs = [job("signer-build", 300, 296), job("pick-nightly-sign-runner", 40, 36, status="in_progress")]
        self.assertEqual(stall.verdict(jobs, NOW)[0], "moving")

    def test_a_job_still_queued_past_the_threshold_counts(self):
        jobs = [job("sentry-dsyms-nightly", 200, None), job("pick-nightly-sign-runner", 30, 26, status="in_progress")]
        self.assertEqual(stall.verdict(jobs, NOW)[0], "stalled")

    def test_only_hosted_ubuntu_alone_counts(self):
        # A Blacksmith or owned Mac wait says nothing about hosted Ubuntu.
        jobs = [job("signer-dmg-image", 900, 10, labels=("blacksmith-6vcpu-macos-26",)),
                job("x", 900, 10, labels=("ubuntu-24.04", "extra")), job("pick-nightly-sign-runner", 20, 18)]
        self.assertEqual(stall.verdict(jobs, NOW)[0], "moving")

    def test_no_hosted_job_yet_is_moving(self):
        self.assertEqual(stall.verdict([], NOW)[0], "moving")


class Main(unittest.TestCase):
    def run_main(self, env: dict, read) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            env = {"RUN_ID": "41683652930", "RUN_ATTEMPT": "1", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "GITHUB_OUTPUT": str(out), **env}
            self.assertEqual(stall.main(env, read=read, now=lambda: NOW), 0)
            return out.read_text()

    def test_writes_the_verdict(self):
        seen = []

        def read(repo, run_id, attempt, token):
            seen.append((repo, run_id, attempt))
            return [job("pick-nightly-sign-runner", 551, 25, status="in_progress")]

        self.assertEqual(self.run_main({}, read), "hosted=stalled\n")
        self.assertEqual(seen, [("manaflow-ai/cmux", "41683652930", "1")])

    def test_an_unreadable_run_keeps_hosted(self):
        def read(*_):
            raise OSError("403")

        self.assertEqual(self.run_main({}, read), "hosted=unknown\n")

    def test_a_bad_run_id_reads_nothing(self):
        def read(*_):
            raise AssertionError("no read")

        self.assertEqual(self.run_main({"RUN_ID": "x"}, read), "hosted=unknown\n")


class Wiring(unittest.TestCase):
    def test_the_pick_measures_and_every_signer_route_reads_it(self):
        import yaml
        sys.path.insert(0, str(ROOT / "tests"))
        from nightly_workflow_text import nightly_text

        jobs = yaml.safe_load(nightly_text())["jobs"]
        pick = jobs["pick-nightly-sign-runner"]
        step = next(s for s in pick["steps"] if s.get("id") == "hosted")
        self.assertEqual(step["env"]["PLATFORM"], "hosted")
        self.assertIn("scripts/ci/nightly_sign_runner.py", step["run"])
        self.assertTrue(step.get("continue-on-error"))
        self.assertEqual(pick["outputs"]["hosted"], "${{ steps.hosted.outputs.hosted }}")
        for name in ("signer-app", "signer-dmg", "legacy-identity-target", "legacy-signer-app", "legacy-signer-dmg"):
            with self.subTest(job=name):
                self.assertIn("pick-nightly-sign-runner", jobs[name]["needs"])
                self.assertIn("needs.pick-nightly-sign-runner.outputs.hosted == 'stalled') && "
                              "'blacksmith-4vcpu-ubuntu-2404'", jobs[name]["runs-on"])

    def test_the_picker_hands_platform_hosted_to_this_check(self):
        import nightly_sign_runner

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            env = {"PLATFORM": "hosted", "RUN_ID": "x", "RUN_ATTEMPT": "1", "GITHUB_OUTPUT": str(out)}
            self.assertEqual(nightly_sign_runner.main(env), 0)
            self.assertEqual(out.read_text(), "hosted=unknown\n")


if __name__ == "__main__":
    unittest.main()
