#!/usr/bin/env python3
"""The nightly signer route leaves hosted Ubuntu on attempt 1 only when hosted was slow to start this run."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hosted_queue_wait", ROOT / "scripts/ci/hosted_queue_wait.py")
wait = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wait)
JOBS = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]


def job(name, runner, created, started):
    return {"name": name, "runner_name": runner, "created_at": created, "started_at": started}


HOSTED = {"RUNNER_ENVIRONMENT": "github-hosted", "JOB_NAME": "decide", "RUNNER_NAME": "GitHub Actions 7"}


class Decide(unittest.TestCase):
    def test_a_wait_over_two_minutes_is_slow(self):
        # Run 41684606067: the pick waited 6.8 min, signer-app 9.3 min.
        jobs = [job("decide", "GitHub Actions 7", "2026-11-03T18:00:00Z", "2026-11-03T18:06:48Z")]
        self.assertEqual(wait.decide(HOSTED, jobs), (True, 408.0))

    def test_a_prompt_start_is_not_slow(self):
        jobs = [job("decide", "GitHub Actions 7", "2026-11-03T18:00:00Z", "2026-11-03T18:00:09Z")]
        self.assertEqual(wait.decide(HOSTED, jobs), (False, 9.0))
        self.assertEqual(wait.decide({**HOSTED, "THRESHOLD_SECONDS": "5"}, jobs), (True, 9.0))

    def test_another_runner_or_an_unread_run_keeps_the_inherited_route(self):
        jobs = [job("decide", "GitHub Actions 8", "2026-11-03T18:00:00Z", "2026-11-03T18:09:00Z")]
        for inherited, expected in (("true", True), ("", False)):
            env = {**HOSTED, "INHERITED_SLOW": inherited}
            self.assertEqual(wait.decide(env, jobs), (expected, None))
            self.assertEqual(wait.decide(env, None), (expected, None))
            # A pick already on Blacksmith can't measure hosted; it keeps decide's answer.
            self.assertEqual(wait.decide({**env, "RUNNER_ENVIRONMENT": "self-hosted"}, jobs), (expected, None))

    def test_a_failed_read_writes_the_inherited_answer_and_exits_zero(self):
        with tempfile.NamedTemporaryFile("r+") as out, \
             mock.patch.object(wait, "read_jobs", side_effect=OSError("403")):
            self.assertEqual(wait.main({**HOSTED, "INHERITED_SLOW": "true", "GITHUB_OUTPUT": out.name}), 0)
            self.assertEqual(out.read(), "hosted_slow=true\nhosted_wait_s=\n")


class Wiring(unittest.TestCase):
    def test_the_signers_take_the_re_run_route_when_hosted_was_slow(self):
        route = ("(github.run_attempt > 1 || needs.pick-nightly-sign-runner.outputs.hosted_slow == 'true') "
                 "&& 'blacksmith-4vcpu-ubuntu-2404' || 'ubuntu-24.04'")
        for name in ("signer-app", "signer-dmg", "legacy-identity-target", "legacy-signer-app", "legacy-signer-dmg"):
            with self.subTest(job=name):
                self.assertIn(route, JOBS[name]["runs-on"])
                self.assertIn("pick-nightly-sign-runner", JOBS[name]["needs"])
        # cmux#34164: signer-build, before the pick, reads decide's answer (run 41683652930: 327 s on hosted).
        self.assertIn("(github.run_attempt > 1 || needs.decide.outputs.hosted_slow == 'true') "
                      "&& 'blacksmith-4vcpu-ubuntu-2404' || 'ubuntu-24.04'", JOBS["signer-build"]["runs-on"])
        pick = JOBS["pick-nightly-sign-runner"]
        self.assertIn("(github.run_attempt > 1 || needs.decide.outputs.hosted_slow == 'true') "
                      "&& fromJSON(vars.RUNNER_POOLS).linux_4", pick["runs-on"])
        self.assertEqual(pick["outputs"]["hosted_slow"],
                         "${{ steps.hosted-wait.outputs.hosted_slow || needs.decide.outputs.hosted_slow }}")
        self.assertEqual(JOBS["decide"]["outputs"]["hosted_slow"], "${{ steps.hosted-wait.outputs.hosted_slow }}")
        for owner, name in (("decide", "decide"), ("pick-nightly-sign-runner", "pick-nightly-sign-runner")):
            with self.subTest(step=owner):
                step = next(s for s in JOBS[owner]["steps"] if s.get("id") == "hosted-wait")
                self.assertEqual((step["continue-on-error"], step["timeout-minutes"]), (True, 1))
                self.assertEqual(step["env"]["JOB_NAME"], name)
                self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")


if __name__ == "__main__":
    unittest.main()
