#!/usr/bin/env python3
"""scripts/ci/nightly_next_cancelled_tip.sh re-runs a nightly-next tip whose newest run ended cancelled."""
from __future__ import annotations

import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "nightly_next_cancelled_tip.sh"
TICK = ROOT / ".github" / "workflows" / "nightly-next-tick.yml"
TIP = "e22f93846f54d679fb95dea965" + "0" * 14

# git ls-remote prints the tip; gh api prints $RUNS (already --jq'd); gh run rerun is logged.
FAKE_GIT = f"""#!/bin/bash
[ "$1" = ls-remote ] && printf '%s\\trefs/heads/nightly-next\\n' "{TIP}"
"""
FAKE_GH = """#!/bin/bash
echo "$*" >> "$LOG"
case "$1" in
  api) printf '%s' "$RUNS" ;;
  run) exit 0 ;;
esac
"""


class CancelledTip(unittest.TestCase):
    def run_script(self, runs: str, **env: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bin_dir = Path(tmp.name) / "bin"
        bin_dir.mkdir()
        for name, body in (("git", FAKE_GIT), ("gh", FAKE_GH)):
            path = bin_dir / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC)
        log = Path(tmp.name) / "log"
        result = subprocess.run(["bash", str(SCRIPT), "o/r"], capture_output=True, text=True, timeout=30,
                                env={"PATH": f"{bin_dir}:/usr/bin:/bin", "LOG": str(log), "RUNS": runs, **env})
        calls = log.read_text().splitlines() if log.exists() else []
        return result, calls

    def test_a_cancelled_tip_run_is_re_run(self):
        result, calls = self.run_script("40340830337 completed cancelled 1\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"head_sha={TIP}", calls[0])
        self.assertEqual(calls[1], "run rerun 40340830337 --failed -R o/r")
        self.assertIn("re-ran its failed and cancelled jobs", result.stdout)

    def test_a_building_tip_is_left_alone(self):
        result, calls = self.run_script("41 in_progress - 2\n40340830337 completed cancelled 1\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("is building", result.stdout)

    def test_a_finished_tip_is_left_alone(self):
        for conclusion in ("success", "failure"):
            result, calls = self.run_script(f"40340830337 completed {conclusion} 1\n")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(calls), 1, conclusion)

    def test_attempts_are_bounded(self):
        result, calls = self.run_script("40340830337 completed cancelled 3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("not re-run again", result.stdout)

    def test_no_run_yet_is_left_alone(self):
        result, calls = self.run_script("")
        self.assertEqual((result.returncode, len(calls)), (0, 1))

    def test_the_tick_runs_it_from_its_own_tooling_before_the_promotion(self):
        steps = yaml.safe_load(TICK.read_text())["jobs"]["request"]["steps"]
        tooling = next(step for step in steps if step.get("with", {}).get("path") == ".tick-tooling")
        self.assertIn("scripts/ci/nightly_next_cancelled_tip.sh", tooling["with"]["sparse-checkout"].split())
        names = [step.get("name") for step in steps]
        check = steps[names.index("Re-run a cancelled nightly-next tip")]
        self.assertTrue(check["continue-on-error"])
        self.assertNotIn("if", check)  # every train mode, "off" included: the promotion still runs then
        self.assertEqual(check["run"], 'bash .tick-tooling/scripts/ci/nightly_next_cancelled_tip.sh "$GITHUB_REPOSITORY"')
        self.assertLess(names.index("Wait through GitHub API rate limits in this job's gh calls"),
                        names.index("Re-run a cancelled nightly-next tip"))


if __name__ == "__main__":
    unittest.main()
