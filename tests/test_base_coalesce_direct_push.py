#!/usr/bin/env python3
"""A direct push to feat-cmux-next compiles on its own commit, even inside a coalesce window an earlier push took.

On 2026-11-25 a hand push (a3b465f1367..72e28bfd2b6, 09:17Z) broke the macOS app compile. Its cmux-next.yml run
skipped every compile job (compile-status, release-compile, release-compile-fast, the fast tier, the fleet app
compile), because `pure-checks-coalesce` (base-coalesce.yml, key cmux-next-pure-checks, 30 min) had already given
the 09:00-09:30 window to an earlier push. The base stayed red until #56147 at 09:43Z and the NIGHTLY broke.

The rule since: a caller that passes `run_direct_pushes: true` runs on any feat-cmux-next push whose head commit
GitHub did not commit (no PR merge made it), taken window or not; lander merges (committed by
`GitHub <noreply@github.com>`) coalesce as before. This test runs base-coalesce.yml's own Decide script under bash
for each case, and checks that cmux-next.yml passes the input.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
COALESCE = ROOT / ".github" / "workflows" / "base-coalesce.yml"
CMUX_NEXT = ROOT / ".github" / "workflows" / "cmux-next.yml"

SHA = "72e28bfd2b6294" + "0" * 26
LAST = "a3b465f13675b9" + "0" * 26


def coalesce_job() -> dict:
    return yaml.safe_load(COALESCE.read_text())["jobs"]["coalesce"]


def step(name: str) -> dict:
    for s in coalesce_job()["steps"]:
        if s.get("name") == name:
            return s
    raise AssertionError(f"base-coalesce.yml has no step {name!r}")


def decide(*, on: str = "1", direct: str = "0", claimed: str = "", own_hit: str = "",
           last_key: str = f"base-coalesce-cmux-next-pure-checks-t-{LAST}") -> dict[str, str]:
    script = step("Decide")["run"]
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out"
        summary = Path(tmp) / "summary"
        (Path(tmp) / ".base-coalesce").mkdir()
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "ON": on, "DIRECT": direct, "CLAIMED": claimed, "OWN_HIT": own_hit, "LAST_KEY": last_key,
            "RETRY": "", "RETRIED": "", "ROUND": "",
            "WINDOW": "1", "KEY": "cmux-next-pure-checks", "HOLD_MINUTES": "30", "GITHUB_SHA": SHA,
            "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary),
        }
        subprocess.run(["bash", "-c", script], cwd=tmp, env=env, check=True, capture_output=True, text=True)
        return dict(line.split("=", 1) for line in out.read_text().splitlines() if "=" in line)


class DirectPushInsideATakenWindow(unittest.TestCase):
    def test_direct_push_in_a_taken_window_still_runs(self) -> None:
        got = decide(direct="1", claimed="true")
        self.assertEqual(got["run"], "true")
        self.assertEqual(got["base"], LAST, "it covers every commit since the last tested tip")
        self.assertEqual(got["save"], "true", "it records itself as a tested tip")
        self.assertEqual(got["save_window"], "false", "the window is already claimed; it is not claimed again")

    def test_lander_merge_in_a_taken_window_still_coalesces(self) -> None:
        got = decide(direct="0", claimed="true")
        self.assertEqual(got["run"], "false")

    def test_first_push_of_a_window_claims_it(self) -> None:
        for direct in ("0", "1"):
            got = decide(direct=direct, claimed="")
            self.assertEqual((got["run"], got["save"], got["save_window"]), ("true", "true", "true"), direct)

    def test_last_tip_lookup_runs_for_a_direct_push_in_a_taken_window(self) -> None:
        cond = step("Find the last tested tip")["if"]
        self.assertIn("env.DIRECT == '1'", cond)
        self.assertEqual(step("Claim this window")["if"],
                         "${{ steps.decide.outputs.save_window == 'true' && github.run_attempt == '1' }}")
        self.assertIn("steps.decide.outputs.save == 'true'", step("Record this tip as tested")["if"])


class DirectPushDetection(unittest.TestCase):
    def test_direct_is_read_from_the_push_payload_committer(self) -> None:
        direct = coalesce_job()["env"]["DIRECT"]
        self.assertIn("inputs.run_direct_pushes", direct)
        self.assertIn("github.event.head_commit.committer.email != 'noreply@github.com'", direct)

    def test_input_defaults_off_for_other_callers(self) -> None:
        inputs = yaml.safe_load(COALESCE.read_text())[True]["workflow_call"]["inputs"]
        self.assertIs(inputs["run_direct_pushes"]["default"], False)

    def test_cmux_next_pure_checks_run_direct_pushes(self) -> None:
        job = yaml.safe_load(CMUX_NEXT.read_text())["jobs"]["pure-checks-coalesce"]
        self.assertEqual(job["uses"], "./.github/workflows/base-coalesce.yml")
        self.assertIs(job["with"]["run_direct_pushes"], True)
        # The app compile jobs are gated on this one coalesce job, so a direct push reaches them.
        jobs = yaml.safe_load(CMUX_NEXT.read_text())["jobs"]
        for name in ("compile-status", "release-compile", "release-compile-fast"):
            self.assertIn("needs.pure-checks-coalesce.outputs.run != 'false'", jobs[name]["if"], name)


if __name__ == "__main__":
    unittest.main()
