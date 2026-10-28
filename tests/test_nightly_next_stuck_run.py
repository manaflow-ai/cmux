#!/usr/bin/env python3
"""scripts/ci/nightly_next_stuck_run.sh cancels a nightly run stuck on a runner label that stopped serving."""
from __future__ import annotations

import datetime as dt
import json
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "nightly_next_stuck_run.sh"
TICK = ROOT / ".github" / "workflows" / "nightly-next-tick.yml"
TIP = "1f0f687b2f32a9f506e19e7f683e8362fd3da6b2"

# git ls-remote prints the tip. gh api answers the nightly-next run list ($NEXT_RUNS), main's
# dispatch list ($MAIN_RUNS) and a run's jobs ($JOBS, {"run id": [jobs]}) through the script's real
# --jq filter, and a run's status with $STATUS (default completed). Writes are logged.
FAKE_GIT = f"""#!/bin/bash
[ "$1" = ls-remote ] && printf '%s\\trefs/heads/nightly-next\\n' "{TIP}"
"""
FAKE_GH = """#!/bin/bash
echo "$*" >> "$LOG"
jq_arg=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" = --jq ] && jq_arg="${args[i+1]}"; done
case "$1" in
  api) case "$*" in
         *"-X POST"*) ;;
         *branch=nightly-next*) printf '%s' "${NEXT_RUNS:-{\\"workflow_runs\\":[]\\}}" | jq -r "$jq_arg" ;;
         *branch=main*) printf '%s' "${MAIN_RUNS:-{\\"workflow_runs\\":[]\\}}" | jq -r "$jq_arg" ;;
         */jobs*) all="$*"; id="${all#*actions/runs/}"; id="${id%%/*}"
                  printf '%s' "$JOBS" | jq -c --arg id "$id" '{jobs: (.[$id] // [])}' | jq -c "$jq_arg" ;;
         */actions/runs/[0-9]*) printf '%s' "${STATUS:-completed}" ;;
       esac ;;
  run) exit 0 ;;
esac
"""


def ago(minutes: float) -> str:
    return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(name: str, minutes: float, label: str = "blacksmith-4vcpu-ubuntu-2404", status: str = "queued",
        runner: str | None = None) -> dict:
    return {"name": name, "status": status, "runner_name": runner, "labels": [label], "created_at": ago(minutes)}


def runs(*items: tuple) -> str:
    return json.dumps({"workflow_runs": [
        {"id": run_id, "status": status, "event": event, "head_sha": sha, "run_attempt": attempt,
         "display_title": title} for run_id, status, event, sha, attempt, title in items]})


STUCK_DECIDE = job("decide", 34)


class StuckRun(unittest.TestCase):
    def run_script(self, jobs: dict, **env: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
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
                                env={"PATH": f"{bin_dir}:/usr/bin:/bin", "LOG": str(log), "SETTLE_SECONDS": "0",
                                     "JOBS": json.dumps({str(k): v for k, v in jobs.items()}), **env})
        calls = log.read_text().splitlines() if log.exists() else []
        return result, calls

    def writes(self, calls: list[str]) -> list[str]:
        return [call for call in calls if "-X POST" in call or call.startswith("run rerun")]

    def test_the_tips_run_stuck_on_a_dead_label_is_cancelled_for_the_next_step_to_re_run(self):
        # Run 40771197361: decide waited 34 min on blacksmith-4vcpu-ubuntu-2404, two jobs queued beside it.
        jobs = {40771197361: [STUCK_DECIDE, job("signer-build", 34, "blacksmith-8vcpu-ubuntu-2404"),
                              job("probe", 34, status="completed")]}
        result, calls = self.run_script(jobs, NEXT_RUNS=runs((40771197361, "queued", "push", TIP, 1, "")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/40771197361/cancel"])
        self.assertIn("decide has waited 34 min with no runner on blacksmith-4vcpu-ubuntu-2404", result.stdout)
        self.assertIn("the next step re-runs it", result.stdout)

    def test_a_run_that_is_running_waiting_or_briefly_queued_is_never_cancelled(self):
        cases = {
            "briefly queued": [job("decide", 19)],
            "another job running": [STUCK_DECIDE, job("build", 5, status="in_progress", runner="r")],
            "a gate waits": [STUCK_DECIDE, job("sign", 40, status="waiting")],
            "an owned label": [job("build-nightly-app", 40, "glaeda-trusted-next-nightly")],
            "taken by a runner": [job("decide", 40, runner="bs-1")],
        }
        for case, jobs in cases.items():
            with self.subTest(case):
                result, calls = self.run_script({7: jobs}, NEXT_RUNS=runs((7, "in_progress", "push", TIP, 1, "")))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.writes(calls), [])
                self.assertIn("no job stuck", result.stdout)

    def test_a_cancel_that_does_not_settle_is_force_cancelled(self):
        result, calls = self.run_script({7: [STUCK_DECIDE]}, STATUS="in_progress", FORCE_AFTER="2",
                                        NEXT_RUNS=runs((7, "queued", "push", TIP, 1, "")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel",
                                              "api -X POST repos/o/r/actions/runs/7/force-cancel"])
        # Bounded: FORCE_AFTER + 1 reads after each cancel, then the next tick.
        self.assertEqual(sum(call == "api repos/o/r/actions/runs/7 --jq .status" for call in calls), 6)
        self.assertIn("the next tick checks again", result.stdout)

    def test_a_dispatch_is_re_run_and_older_commits_and_promotions_are_not(self):
        # Run 3 is a dispatch on its last attempt: left queued.
        jobs = {1: [STUCK_DECIDE], 2: [STUCK_DECIDE], 3: [STUCK_DECIDE], 4: [STUCK_DECIDE], 5: [STUCK_DECIDE]}
        result, calls = self.run_script(
            jobs,
            NEXT_RUNS=runs((1, "queued", "workflow_dispatch", TIP, 1, ""), (2, "queued", "push", "0" * 40, 1, ""),
                           (3, "queued", "workflow_dispatch", TIP, 3, ""), (6, "completed", "push", TIP, 1, "")),
            MAIN_RUNS=runs((4, "queued", "workflow_dispatch", "a" * 40, 1, f"Promote nightly-next to tick:{TIP}"),
                           (5, "queued", "workflow_dispatch", "a" * 40, 1, "Nightly")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), [
            "api -X POST repos/o/r/actions/runs/1/cancel", "run rerun 1 --failed -R o/r",
            "api -X POST repos/o/r/actions/runs/2/cancel", "api -X POST repos/o/r/actions/runs/4/cancel"])
        self.assertFalse(any("runs/5/" in call or "runs/6/" in call for call in calls), calls)

    def test_a_run_the_tick_has_re_run_enough_stays_queued(self):
        result, calls = self.run_script({7: [STUCK_DECIDE]}, NEXT_RUNS=runs((7, "queued", "push", TIP, 3, "")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), [])
        self.assertIn("left queued", result.stdout)

    def test_no_unfinished_run_reads_no_jobs(self):
        result, calls = self.run_script({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("no unfinished", result.stdout)

    def test_the_tick_cancels_before_it_re_runs_a_cancelled_tip(self):
        steps = yaml.safe_load(TICK.read_text())["jobs"]["request"]["steps"]
        tooling = next(step for step in steps if step.get("with", {}).get("path") == ".tick-tooling")
        self.assertIn("scripts/ci/nightly_next_stuck_run.sh", tooling["with"]["sparse-checkout"].split())
        names = [step.get("name") for step in steps]
        check = steps[names.index("Cancel a nightly-next run stuck without a runner")]
        self.assertTrue(check["continue-on-error"])
        self.assertEqual(check["run"], 'bash .tick-tooling/scripts/ci/nightly_next_stuck_run.sh "$GITHUB_REPOSITORY"')
        self.assertLess(names.index("Wait through GitHub API rate limits in this job's gh calls"),
                        names.index("Cancel a nightly-next run stuck without a runner"))
        self.assertLess(names.index("Cancel a nightly-next run stuck without a runner"),
                        names.index("Re-run a cancelled nightly-next tip"))


if __name__ == "__main__":
    unittest.main()
