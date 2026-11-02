#!/usr/bin/env python3
"""scripts/ci/nightly_next_cancelled_tip.sh re-runs a nightly-next tip whose newest run ended cancelled."""
from __future__ import annotations

import json
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "nightly_next_cancelled_tip.sh"
TICK = ROOT / ".github" / "workflows" / "nightly-next-tick.yml"
TIP = "e22f93846f54d679fb95dea965" + "0" * 14

# git ls-remote prints the tip. gh api prints $RUNS for the runs list, the run's state ($NOW),
# nightly.yml at the tip ($WORKFLOW, base64 as the contents API has it), and the attempt's
# jobs page ($JOBS, a {"jobs": [...]} page) through the script's real --jq filter; JOBS_FAIL makes the jobs
# read fail. A check run's annotations are $NOTES (a JSON list); NOTES_FAIL makes that read fail. Re-runs (gh run rerun, POST .../jobs/N/rerun) are logged with the wrapper's retry setting.
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
         *"-X POST"*/jobs/*/rerun*) echo "attempts=${GH_BUDGET_WAIT_ATTEMPTS:-}" >> "$LOG"; [ -z "${JOB_RERUN_FAIL:-}" ] ;;
         */jobs*) [ -n "${JOBS_FAIL:-}" ] && exit 1; printf '%s' "${JOBS:-}" | jq -c "$jq_arg" ;;
         */contents/*) [ -n "${WORKFLOW:-}" ] || exit 1; printf '%s' "$WORKFLOW" | base64 ;;
         */check-runs/*/annotations*) [ -n "${NOTES_FAIL:-}" ] && exit 1; printf '%s' "${NOTES:-[]}" | jq -c "$jq_arg" ;;
         */actions/runs/[0-9]*) printf '%s' "${NOW:-completed cancelled ${ATTEMPT:-1}}" ;;
         *) printf '%s' "$RUNS" ;;
       esac ;;
  run) echo "attempts=${GH_BUDGET_WAIT_ATTEMPTS:-}" >> "$LOG"; exit 0 ;;
esac
"""


def page(*jobs: dict) -> str:
    return json.dumps({"jobs": list(jobs)})


def unserved(name="build-nightly-app", label="blacksmith-6vcpu-macos-26", conclusion="cancelled"):
    return {"id": 7, "name": name, "status": "completed", "conclusion": conclusion, "runner_name": None,
            "labels": [label], "started_at": "2026-10-27T10:01:00Z"}


PICKER = {"id": 901, "name": "pick-nightly-build-runner", "status": "completed", "conclusion": "success",
          "runner_name": "gh", "labels": ["ubuntu-latest"], "started_at": "2026-10-27T10:00:30Z"}


def workflow(overwrite: bool = True) -> str:
    upload = {"uses": "actions/upload-artifact@v7", "with": {"name": "cmux-next-source-archive",
                                                            **({"overwrite": True} if overwrite else {})}}
    return json.dumps({"jobs": {
        "pick-nightly-build-runner": {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]},
        "build-nightly-app": {"needs": "pick-nightly-build-runner", "runs-on": "x", "steps": [{"run": "true"}]},
        "build-nightly-ghostty-cli-helper": {"needs": "pick-nightly-build-runner", "runs-on": "x", "steps": [upload]},
    }})


class CancelledTip(unittest.TestCase):
    def run_script(self, runs: str, **env: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bin_dir = Path(tmp.name) / "bin"
        bin_dir.mkdir()
        # The script's python3 is this test's, which has PyYAML.
        for name, body in (("git", FAKE_GIT), ("gh", FAKE_GH), ("python3", f'#!/bin/bash\nexec "{sys.executable}" "$@"\n')):
            path = bin_dir / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC)
        log = Path(tmp.name) / "log"
        result = subprocess.run(["bash", str(SCRIPT), "o/r"], capture_output=True, text=True, timeout=180,
                                env={"PATH": f"{bin_dir}:/usr/bin:/bin", "LOG": str(log), "RUNS": runs, **env})
        calls = log.read_text().splitlines() if log.exists() else []
        return result, calls

    def test_a_cancelled_tip_run_is_re_run(self):
        result, calls = self.run_script("40340830337 completed cancelled 1\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"head_sha={TIP}", calls[0])
        self.assertIn("runs/40340830337/attempts/1/jobs", calls[1])
        self.assertIn("runs/40340830337 --jq", calls[2])
        self.assertEqual(calls[3:], ["run rerun 40340830337 --failed -R o/r", "attempts=1"])
        self.assertIn("re-ran its failed and cancelled jobs", result.stdout)

    def test_a_run_that_changed_since_the_read_is_not_re_run(self):
        # A rescue re-ran it (or it finished) while the reads waited out a rate limit.
        for now in ("in_progress - 2", "completed success 1", "completed cancelled 2"):
            with self.subTest(now=now):
                result, calls = self.run_script("40340830337 completed cancelled 1\n", NOW=now,
                                                JOBS=page(PICKER, unserved()), WORKFLOW=workflow())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call.startswith("run rerun") or "-X POST" in call for call in calls), calls)
                self.assertIn("not re-run", result.stdout)

    def test_a_tip_cancelled_on_a_dead_picked_label_re_runs_its_picker(self):
        # The failed-jobs re-run keeps the earlier pick; a label that never served the job gets a fresh pick.
        for label in ("blacksmith-6vcpu-macos-26", "glaeda-side-std-xcode-26.6"):
            with self.subTest(label=label):
                result, calls = self.run_script("40340830337 completed cancelled 2\n", ATTEMPT="2",
                                                JOBS=page(PICKER, unserved(label=label)), WORKFLOW=workflow())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("runs/40340830337/attempts/2/jobs", calls[1])
                # nightly_compile_red.py reads attempt 1 too: attempt 2 never ran the build.
                self.assertIn("runs/40340830337/attempts/1/jobs", calls[2])
                self.assertIn(f"contents/.github/workflows/nightly.yml?ref={TIP}", calls[3])
                self.assertIn("runs/40340830337 --jq", calls[4])
                self.assertEqual(calls[5:], ["api -X POST repos/o/r/actions/jobs/901/rerun", "attempts=1"])
                self.assertFalse(any(call.startswith("run rerun") for call in calls), calls)
                self.assertIn(f"build-nightly-app never served on {label}", result.stdout)
                self.assertIn("chooses fresh", result.stdout)

    def test_a_dead_label_whose_picker_re_run_is_unsafe_re_runs_its_failed_jobs(self):
        # A succeeded helper uploading without overwrite would build and upload again: never a whole re-run.
        helper = {**unserved("build-nightly-ghostty-cli-helper"), "id": 8, "conclusion": "success", "runner_name": "bs"}
        cases = {
            "upload without overwrite": dict(JOBS=page(PICKER, unserved(), helper), WORKFLOW=workflow(overwrite=False)),
            "unreadable workflow": dict(JOBS=page(PICKER, unserved())),
            "no picker job": dict(JOBS=page(unserved()), WORKFLOW=workflow()),
        }
        for case, env in cases.items():
            with self.subTest(case):
                result, calls = self.run_script("40340830337 completed cancelled 1\n", **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls[-2:], ["run rerun 40340830337 --failed -R o/r", "attempts=1"])
                self.assertFalse(any("-X POST" in call or call == "run rerun 40340830337 -R o/r" for call in calls))
                self.assertIn("the picker is not re-run", result.stdout)

    def test_a_refused_picker_re_run_re_runs_the_failed_jobs(self):
        result, calls = self.run_script("40340830337 completed cancelled 1\n", JOB_RERUN_FAIL="1",
                                        JOBS=page(PICKER, unserved()), WORKFLOW=workflow())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-4:], ["api -X POST repos/o/r/actions/jobs/901/rerun", "attempts=1",
                                      "run rerun 40340830337 --failed -R o/r", "attempts=1"])
        self.assertIn("was refused", result.stdout)

    def test_an_unreadable_attempt_re_runs_its_failed_jobs(self):
        result, calls = self.run_script("40340830337 completed cancelled 1\n", JOBS_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-2:], ["run rerun 40340830337 --failed -R o/r", "attempts=1"])
        self.assertIn("could not read", result.stdout)

    def test_the_jobs_filter_keeps_only_unserved_picked_macos_jobs(self):
        # A served job, a Linux one, and a successful one are skipped: those re-run their failed jobs.
        served = {**unserved("helper"), "runner_name": "bs-1"}
        linux = {**unserved("linux", label="blacksmith-4vcpu-ubuntu-2404"), "runner_name": ""}
        sign = {**unserved("sign", label="glaeda-side-std-xcode-26.6", conclusion="success"), "runner_name": ""}
        result, calls = self.run_script("40340830337 completed cancelled 1\n",
                                        JOBS=page(PICKER, served, linux, sign), WORKFLOW=workflow())
        self.assertEqual(calls[-2:], ["run rerun 40340830337 --failed -R o/r", "attempts=1"])
        self.assertFalse(any("contents/" in call for call in calls), calls)
        verify = unserved("verify", label="glaeda-side-std-xcode-26.6", conclusion="failure")
        result, _ = self.run_script("40340830337 completed cancelled 1\n",
                                    JOBS=page(PICKER, served, verify), WORKFLOW=workflow())
        # Unserved, but nightly.yml has no verify job under the picker: its failed jobs are re-run.
        self.assertIn("verify was never served on glaeda-side-std-xcode-26.6", result.stdout)

    def compile_red_build(self, exit_line="Process completed with exit code 65."):
        build = {"id": 7, "name": "build-nightly-app", "status": "completed", "conclusion": "failure",
                 "runner_name": "cmux13s-mac-mini-glaeda-2", "labels": ["glaeda-std-xcode-26.6"],
                 "steps": [{"name": "Set up job", "conclusion": "success"},
                           {"name": "Build nightly app (Release)", "conclusion": "failure"}]}
        notes = [{"path": ".github", "start_line": 39700, "annotation_level": "failure", "message": exit_line},
                 {"path": "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Remote/JoinConsent+App.swift",
                  "start_line": 222, "annotation_level": "failure",
                  "message": "'async' call in a function that does not support concurrency"}]
        return page(PICKER, build), json.dumps(notes)

    def test_a_tip_whose_build_failed_to_compile_is_not_re_run(self):
        # Run 40989498281 (00c873b5, 2026-10-30): a re-run compiles the same broken source.
        jobs, notes = self.compile_red_build()
        result, calls = self.run_script("40989498281 completed cancelled 1\n", JOBS=jobs, NOTES=notes)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call.startswith("run rerun") or "-X POST" in call for call in calls), calls)
        self.assertIn("check-runs/7/annotations", " ".join(calls))
        self.assertIn("is not re-run: attempt 1's build-nightly-app failed to compile", result.stdout)
        self.assertIn("JoinConsent+App.swift:222", result.stdout)

    def test_an_attempt_without_the_build_reads_the_one_before(self):
        # Attempt 2 kept no build job of its own (a signing-only re-run): attempt 1's compile error decides.
        jobs, notes = self.compile_red_build()
        result, calls = self.run_script("40989498281 completed cancelled 2\n", ATTEMPT="2", JOBS=jobs, NOTES=notes)
        self.assertEqual(result.returncode, 0, result.stderr)
        # The attempt-2 jobs fake returns the same page, so this checks the build is read and judged.
        self.assertFalse(any(call.startswith("run rerun") for call in calls), calls)
        self.assertIn("failed to compile", result.stdout)

    def test_a_build_that_failed_otherwise_is_still_re_run(self):
        for env in ({"NOTES": self.compile_red_build("Process completed with exit code 137.")[1]},
                    {"NOTES_FAIL": "1"}):
            with self.subTest(env=list(env)):
                jobs, _ = self.compile_red_build()
                result, calls = self.run_script("40989498281 completed cancelled 1\n", JOBS=jobs, **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls[-2:], ["run rerun 40989498281 --failed -R o/r", "attempts=1"])
                self.assertNotIn("failed to compile", result.stdout)

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
        sparse = tooling["with"]["sparse-checkout"].split()
        self.assertIn("scripts/ci/nightly_next_cancelled_tip.sh", sparse)
        # nightly_repick.py and every scripts/ci module it imports.
        for name in ("nightly_repick.py", "nightly_compile_red.py", "owned_pool_rescue.py", "owned_pool_sources.py", "pr_runner_pool.py",
                     "simple_pool_picker.py", "ui_tests_dispatch.py"):
            self.assertIn(f"scripts/ci/{name}", sparse)
        names = [step.get("name") for step in steps]
        check = steps[names.index("Re-run a cancelled nightly-next tip")]
        self.assertTrue(check["continue-on-error"])
        # Automatic/empty-SHA ticks recover the current nightly tip in every train mode.
        # Explicit-SHA ticks must reach promotion without waiting for an older tip's API reads.
        self.assertEqual(check["if"], "inputs.sha == ''")
        self.assertEqual(check["run"], 'bash .tick-tooling/scripts/ci/nightly_next_cancelled_tip.sh "$GITHUB_REPOSITORY"')
        self.assertLess(names.index("Wait through GitHub API rate limits in this job's gh calls"),
                        names.index("Re-run a cancelled nightly-next tip"))


if __name__ == "__main__":
    unittest.main()
