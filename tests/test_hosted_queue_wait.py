#!/usr/bin/env python3
"""hosted_queue_wait.py on its own. No nightly job reads it any more: nightlies run only on our own Mac minis."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hosted_queue_wait", ROOT / "scripts/ci/hosted_queue_wait.py")
wait = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wait)


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
            self.assertEqual(out.read(), "hosted_slow=true\nhosted_wait_s=\nslow_runner=\n")

    def test_a_slow_start_names_the_light_jobs_blacksmith_size(self):
        pools = '{"linux_4": "blacksmith-4vcpu-ubuntu-2404", "linux": "glaeda-linux"}'
        self.assertEqual(wait.slow_runner({"RUNNER_POOLS": pools}, True), "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(wait.slow_runner({"RUNNER_POOLS": pools}, False), "")
        # Only a Blacksmith Ubuntu label: never hosted, never a Mac, never an unreadable pool.
        for pools in ('{"linux_4": "ubuntu-24.04"}', '{"linux_4": "blacksmith-6vcpu-macos-15"}', "not json", "[]", ""):
            with self.subTest(pools=pools):
                self.assertEqual(wait.slow_runner({"RUNNER_POOLS": pools}, True), "")




if __name__ == "__main__":
    unittest.main()
