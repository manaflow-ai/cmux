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

# A stateful GitHub, as the scripts read it through gh --jq (the fake runs the script's own filter
# with jq, and fails when jq does). Every call but the refs read is logged, so the log shows the
# runs, jobs and workflow reads and the writes in order. State (env):
#   RUNS        the tip's runs on nightly-next, one "id status conclusion attempt" a line ("-" for no
#               conclusion, "null" for a JSON null), served as nightly.yml's runs API JSON;
#   RUNS_LATER  the runs from the second listing on; NOW ("status conclusion attempt") replaces the
#               newest run's from the second listing on; RUNS_FAIL fails every listing;
#   GIT_TIP_LATER  nightly-next's head from its second refs read on ("fail" fails that read);
#   JOBS        the attempt's jobs page (JSON); JOBS_FAIL fails it;
#   WORKFLOW    nightly.yml at the tip (served base64, as the contents API); unset fails the read;
#   JOB_RERUN_FAIL / DISPATCH_FAIL refuse a picker re-run / a dispatch. Writes log the wrapper's
#   retry setting (attempts=...).
FAKE_GIT = """#!/bin/bash
echo "git is not used by the tick's scripts" >&2
exit 128
"""
FAKE_GH = r"""#!PYTHON
import base64, json, os, subprocess, sys
from pathlib import Path

args = sys.argv[1:]
log = Path(os.environ["LOG"])
jq = args[args.index("--jq") + 1] if "--jq" in args else "."


def count(name):
    path = Path(str(log) + "." + name)
    n = int(path.read_text()) if path.exists() else 0
    path.write_text(str(n + 1))
    return n


def out(value):
    result = subprocess.run(["jq", "-rc", jq], input=json.dumps(value), capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.exit(result.returncode)


def token(value):
    if value == "null":
        return None
    if value == "-":
        return None
    return int(value) if value.isdigit() else value


def runs_json(text):
    runs = []
    for line in text.splitlines():
        if not line.strip():
            continue
        rid, status, conclusion, attempt = line.split()
        runs.append({"id": token(rid), "status": token(status), "conclusion": token(conclusion),
                     "run_attempt": token(attempt), "event": "push", "head_sha": "@TIP@",
                     "display_title": "Nightly"})
    return runs


path = next((arg for arg in args if arg.startswith("repos/")), "")
if path.endswith("/git/ref/heads/nightly-next"):
    tip = "@TIP@"
    if count("ref") >= 1 and os.environ.get("GIT_TIP_LATER"):
        tip = os.environ["GIT_TIP_LATER"]
    if tip == "fail":
        sys.exit(1)
    out({"object": {"sha": tip, "type": "commit"}})
with log.open("a") as stream:
    stream.write(" ".join(args) + "\n")


def retries():
    with log.open("a") as stream:
        stream.write("attempts=" + os.environ.get("GH_BUDGET_WAIT_ATTEMPTS", "") + "\n")


if args[:2] in (["run", "rerun"], ["workflow", "run"]):
    retries()
    sys.exit(1 if args[0] == "workflow" and os.environ.get("DISPATCH_FAIL") else 0)
if "-X" in args:
    retries()
    sys.exit(1 if os.environ.get("JOB_RERUN_FAIL") else 0)
if "/workflows/nightly.yml/runs?" in path:
    if os.environ.get("RUNS_FAIL"):
        sys.exit(1)
    n = count("runs")
    text = os.environ.get("RUNS_LATER") if n >= 1 and "RUNS_LATER" in os.environ else os.environ.get("RUNS", "")
    runs = runs_json(text)
    if n >= 1 and os.environ.get("NOW") and runs:
        status, conclusion, attempt = os.environ["NOW"].split()
        runs[0].update(status=token(status), conclusion=token(conclusion), run_attempt=token(attempt))
    out({"workflow_runs": runs})
if "/jobs" in path:
    if os.environ.get("JOBS_FAIL"):
        sys.exit(1)
    out(json.loads(os.environ.get("JOBS") or '{"jobs": []}'))
if "/contents/" in path:
    if not os.environ.get("WORKFLOW"):
        sys.exit(1)
    out({"content": base64.b64encode(os.environ["WORKFLOW"].encode()).decode()})
sys.exit(3)
"""


def page(*jobs: dict) -> str:
    return json.dumps({"jobs": list(jobs)})


def unserved(name="build-nightly-app", label="blacksmith-6vcpu-macos-26", conclusion="cancelled"):
    return {"id": 7, "name": name, "status": "completed", "conclusion": conclusion, "runner_name": None,
            "labels": [label], "created_at": "2026-10-27T10:00:40Z", "started_at": "2026-10-27T10:01:00Z"}


PICKER = {"id": 901, "name": "pick-nightly-build-runner", "status": "completed", "conclusion": "success",
          "runner_name": "gh", "labels": ["ubuntu-latest"], "created_at": "2026-10-27T10:00:20Z",
          "started_at": "2026-10-27T10:00:30Z"}


# A runs-on that takes the picker's label, as nightly.yml's build jobs do.
PICKED = "${{ needs.pick-nightly-build-runner.outputs.blacksmith || 'blacksmith-6vcpu-macos-26' }}"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"


def workflow(overwrite: bool = True) -> str:
    upload = {"uses": "actions/upload-artifact@v7", "with": {"name": "cmux-next-source-archive",
                                                            **({"overwrite": True} if overwrite else {})}}
    return json.dumps({"jobs": {
        "pick-nightly-build-runner": {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]},
        "build-nightly-app": {"needs": "pick-nightly-build-runner", "runs-on": PICKED, "steps": [{"run": "true"}]},
        "build-nightly-ghostty-cli-helper": {"needs": "pick-nightly-build-runner", "runs-on": PICKED, "steps": [upload]},
        "decide": {"runs-on": "${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}", "steps": [{"run": "true"}]},
        "publish-nightly": {"needs": "build-nightly-app", "runs-on": "${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
                            "steps": [{"run": "true"}]},
    }})


class CancelledTip(unittest.TestCase):
    def run_script(self, runs: str, **env: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bin_dir = Path(tmp.name) / "bin"
        bin_dir.mkdir()
        # The script's python3 is this test's, which has PyYAML.
        for name, body in (("git", FAKE_GIT), ("gh", FAKE_GH.replace("#!PYTHON", f"#!{sys.executable}").replace("@TIP@", TIP)), ("python3", f'#!/bin/bash\nexec "{sys.executable}" "$@"\n')):
            path = bin_dir / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC)
        log = Path(tmp.name) / "log"
        result = subprocess.run(["bash", str(SCRIPT), "o/r"], capture_output=True, text=True, timeout=30,
                                env={"PATH": f"{bin_dir}:/usr/bin:/bin", "LOG": str(log), "RUNS": runs, **env})
        calls = log.read_text().splitlines() if log.exists() else []
        return result, calls

    def test_a_cancelled_tip_run_is_re_run(self):
        result, calls = self.run_script("40340830337 completed cancelled 1\n",
                                        JOBS=page(PICKER, {**unserved(), "runner_name": "bs"}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"head_sha={TIP}", calls[0])
        self.assertIn("runs/40340830337/attempts/1/jobs", calls[1])
        # The last read before the write is the tip's runs again (nightly_next_tip_owed.sh).
        self.assertIn(f"head_sha={TIP}", calls[2])
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
                self.assertIn(f"contents/.github/workflows/nightly.yml?ref={TIP}", calls[2])
                self.assertIn(f"head_sha={TIP}", calls[3])
                self.assertEqual(calls[4:], ["api -X POST repos/o/r/actions/jobs/901/rerun", "attempts=1"])
                self.assertFalse(any(call.startswith("run rerun") for call in calls), calls)
                self.assertIn(f"build-nightly-app never served on {label}", result.stdout)
                self.assertIn("chooses fresh", result.stdout)

    def test_a_dead_label_whose_picker_re_run_is_unsafe_re_runs_its_failed_jobs(self):
        # A succeeded helper uploading without overwrite would build and upload again: never a whole re-run.
        helper = {**unserved("build-nightly-ghostty-cli-helper"), "id": 8, "conclusion": "success", "runner_name": "bs"}
        cases = {
            "upload without overwrite": dict(JOBS=page(PICKER, unserved(), helper), WORKFLOW=workflow(overwrite=False)),
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

    def test_an_unreadable_or_malformed_read_sends_nothing(self):
        # Fail closed: a jobs read that fails or comes back malformed, an unreadable nightly.yml, or
        # a picker check that cannot decide sends no write at all, not even the re-run of failed
        # jobs. The tip stays owed (its run still ended cancelled), so the next tick tries again.
        job = unserved()
        cases = {
            "jobs read fails": dict(JOBS_FAIL="1"),
            "jobs not a list": dict(JOBS=json.dumps({"jobs": {"a": job}})),
            "a job without labels": dict(JOBS=page(PICKER, {k: v for k, v in job.items() if k != "labels"})),
            "a job with null conclusion type wrong": dict(JOBS=page(PICKER, dict(job, conclusion=3))),
            "a runner_name object": dict(JOBS=page(PICKER, dict(job, runner_name={}))),
            "a runner_name list": dict(JOBS=page(PICKER, dict(job, runner_name=[]))),
            "no jobs": dict(JOBS=page()),
            "nightly.yml unreadable": dict(JOBS=page(PICKER, job)),
            "nightly.yml not YAML": dict(JOBS=page(PICKER, job), WORKFLOW=": : ["),
        }
        for case, env in cases.items():
            with self.subTest(case):
                result, calls = self.run_script("40340830337 completed cancelled 1\n", **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call.startswith(("run rerun", "workflow run")) or "-X POST" in call
                                     for call in calls), calls)
                self.assertIn("nothing re-run this tick", result.stdout)

    def test_the_jobs_filter_keeps_only_unserved_jobs(self):
        # A served job and a successful one are skipped: those re-run their failed jobs.
        served = {**unserved("helper"), "runner_name": "bs-1"}
        sign = {**unserved("sign", label="glaeda-side-std-xcode-26.6", conclusion="success"), "runner_name": ""}
        result, calls = self.run_script("40340830337 completed cancelled 1\n",
                                        JOBS=page(PICKER, served, sign), WORKFLOW=workflow())
        self.assertEqual(calls[-2:], ["run rerun 40340830337 --failed -R o/r", "attempts=1"])
        self.assertFalse(any("contents/" in call for call in calls), calls)
        verify = unserved("verify", label="glaeda-side-std-xcode-26.6", conclusion="failure")
        result, _ = self.run_script("40340830337 completed cancelled 1\n",
                                    JOBS=page(PICKER, served, verify), WORKFLOW=workflow())
        # Unserved, but nightly.yml has no verify job under the picker: its failed jobs are re-run.
        self.assertIn("verify was never served on glaeda-side-std-xcode-26.6", result.stdout)

    def test_a_linux_job_that_takes_the_pick_re_runs_the_picker(self):
        # A label that stopped serving is a dead label whatever its OS: a Linux job under the picker
        # that takes the pick's label is picked fresh too.
        linux = unserved("build-nightly-app", label="blacksmith-16vcpu-ubuntu-2404")
        result, calls = self.run_script("40340830337 completed cancelled 1\n", JOBS=page(PICKER, linux),
                                        WORKFLOW=workflow())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-2:], ["api -X POST repos/o/r/actions/jobs/901/rerun", "attempts=1"])
        self.assertIn("never served on blacksmith-16vcpu-ubuntu-2404", result.stdout)

    def test_a_job_whose_runner_is_not_the_picks_re_runs_its_failed_jobs(self):
        # decide and publish-nightly take their runner from the runner variables, not the pick: a
        # fresh pick would rebuild the app and still leave them where they were, so their failed
        # jobs are re-run, which evaluates their runs-on again.
        build = {**unserved("build-nightly-app"), "id": 8, "conclusion": "success", "runner_name": "bs"}
        for jobs in (page(PICKER, unserved("decide", label="blacksmith-4vcpu-ubuntu-2404")),
                     page(PICKER, build, unserved("publish-nightly", label="blacksmith-4vcpu-ubuntu-2404"))):
            with self.subTest(jobs=jobs):
                result, calls = self.run_script("40340830337 completed cancelled 1\n", JOBS=jobs, WORKFLOW=workflow())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls[-2:], ["run rerun 40340830337 --failed -R o/r", "attempts=1"])
                self.assertFalse(any("-X POST" in call for call in calls), calls)
                self.assertIn("takes its runner from a picker job's outputs", result.stdout)

    def test_the_picker_is_read_from_the_workflow_not_a_fixed_name(self):
        # Rename the picker (main's nightly.yml calls it pick-nightly-app-runner): the repick follows.
        renamed = workflow().replace("pick-nightly-build-runner", "pick-nightly-app-runner")
        picker = {**PICKER, "name": "pick-nightly-app-runner"}
        result, calls = self.run_script("40340830337 completed cancelled 1\n", JOBS=page(picker, unserved()),
                                        WORKFLOW=renamed)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-2:], ["api -X POST repos/o/r/actions/jobs/901/rerun", "attempts=1"])
        self.assertIn("re-ran its runner picker (job 901)", result.stdout)

    def test_the_real_nightly_workflow_names_a_picker_for_its_app_build(self):
        # The repick reads nightly.yml for the job whose outputs the build's runs-on reads; if a rename
        # or a rewrite ever leaves no such job, this fails instead of the repick going quiet.
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import nightly_repick  # noqa: PLC0415

        text = NIGHTLY.read_text()
        jobs = nightly_repick.workflow_jobs(text)
        pickers, why = nightly_repick.pickers_of(text, ["build-nightly-app"])
        self.assertTrue(pickers, why)
        for picker in pickers:
            self.assertIn(picker, jobs)
            self.assertIn("outputs", jobs[picker], f"{picker} has no outputs")
            self.assertTrue(picker.startswith("pick-"), picker)
        self.assertIn(pickers[0], str(jobs["build-nightly-app"].get("needs")))

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

    def test_a_tip_cancelled_at_the_attempt_cap_gets_a_fresh_run(self):
        # The tip's newest run (push or dispatch) ended cancelled on its last attempt: a fresh
        # nightly.yml run of the tip is dispatched, sent once with no wrapper retries.
        result, calls = self.run_script("40340830337 completed cancelled 3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-2:], ["workflow run nightly.yml -R o/r --ref nightly-next", "attempts=1"])
        self.assertIn("dispatched a fresh nightly.yml run", result.stdout)
        listing = calls[0]
        self.assertIn(f"head_sha={TIP}", listing)
        self.assertIn("--paginate", listing)
        self.assertNotIn("event=push", listing, "a dispatch of the tip must count too")

    def test_a_refused_fresh_run_is_owed_until_a_replacement_exists(self):
        # The obligation is GitHub's own record, which the refused dispatch leaves as it was: the
        # next tick reads the same cancelled run and dispatches again, and once a replacement run of
        # the tip exists (any state), nothing more is sent.
        result, calls = self.run_script("40340830337 completed cancelled 3\n", DISPATCH_FAIL="1")
        self.assertNotEqual(result.returncode, 0, "a refused dispatch must fail the step, not pass quietly")
        result, calls = self.run_script("40340830337 completed cancelled 3\n")
        self.assertEqual(calls[-2:], ["workflow run nightly.yml -R o/r --ref nightly-next", "attempts=1"])
        for state in ("queued", "waiting", "pending", "requested", "in_progress"):
            with self.subTest(state=state):
                result, calls = self.run_script(f"40340830400 {state} - 1\n40340830337 completed cancelled 3\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call.startswith("workflow run") for call in calls), calls)
        # A replacement that finished (it ran) is the newest run: not cancelled, nothing owed.
        result, calls = self.run_script("40340830400 completed success 1\n40340830337 completed cancelled 3\n")
        self.assertFalse(any(call.startswith("workflow run") for call in calls), calls)

    def test_a_fresh_run_is_never_doubled_or_sent_on_an_unread_list(self):
        # A replacement that appears between the first read and the dispatch, or a list that cannot
        # be read, sends nothing.
        result, calls = self.run_script("40340830337 completed cancelled 3\n",
                                        RUNS_LATER="40340830400 queued - 1\n40340830337 completed cancelled 3\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call.startswith("workflow run") for call in calls), calls)
        self.assertIn("carries the tip", result.stdout)
        # An older run of the tip that started another attempt carries it too, though it is not the
        # newest (review of db7f0edd: "20 completed cancelled 3" with "10 in_progress - 2").
        result, calls = self.run_script("40340830337 completed cancelled 3\n",
                                        RUNS_LATER="40340830337 completed cancelled 3\n40340830300 in_progress - 2\n")
        self.assertFalse(any(call.startswith("workflow run") for call in calls), calls)
        self.assertIn("run 40340830300 carries the tip", result.stdout)
        # The same last read guards the re-run below the cap.
        result, calls = self.run_script("40340830337 completed cancelled 1\n", JOBS=page(PICKER, unserved()),
                                        WORKFLOW=workflow(),
                                        RUNS_LATER="40340830400 queued - 1\n40340830337 completed cancelled 1\n")
        self.assertFalse(any(call.startswith("run rerun") or "-X POST" in call for call in calls), calls)
        self.assertIn("carries the tip", result.stdout)
        result, calls = self.run_script("40340830337 completed cancelled 3\n", RUNS_FAIL="1")
        self.assertFalse(any(call.startswith("workflow run") or call.startswith("run rerun") for call in calls), calls)

    def test_nothing_is_built_once_nightly_next_has_moved(self):
        # The branch moved (or could not be read) between the first read and the write: a re-run of
        # the old commit, or a dispatch that would build some other commit, is never sent.
        for later in ("f" * 40, "fail"):
            for runs in ("40340830337 completed cancelled 1\n", "40340830337 completed cancelled 3\n"):
                with self.subTest(later=later, runs=runs):
                    result, calls = self.run_script(runs, GIT_TIP_LATER=later, JOBS=page(PICKER, unserved()),
                                                    WORKFLOW=workflow())
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(any(call.startswith(("run rerun", "workflow run")) or "-X POST" in call
                                         for call in calls), calls)
                    self.assertRegex(result.stdout, "moved|could not be read")

    def test_runs_of_an_unexpected_shape_send_nothing(self):
        for runs in ("null completed cancelled 1\n", "40340830337 completed cancelled null\n",
                     "40340830337 null - 1\n"):
            with self.subTest(runs=runs):
                result, calls = self.run_script(runs)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call.startswith(("run rerun", "workflow run")) or "-X POST" in call
                                     for call in calls), calls)

    def test_no_run_yet_is_left_alone(self):
        result, calls = self.run_script("")
        self.assertEqual((result.returncode, len(calls)), (0, 1))

    def test_the_tick_runs_it_from_its_own_tooling_before_the_promotion(self):
        steps = yaml.safe_load(TICK.read_text())["jobs"]["request"]["steps"]
        tooling = next(step for step in steps if step.get("with", {}).get("path") == ".tick-tooling")
        sparse = tooling["with"]["sparse-checkout"].split()
        self.assertIn("scripts/ci/nightly_next_cancelled_tip.sh", sparse)
        self.assertIn("scripts/ci/nightly_next_rerun.sh", sparse)
        # nightly_repick.py and every scripts/ci module it imports.
        for name in ("nightly_repick.py", "owned_pool_rescue.py", "owned_pool_sources.py", "pr_runner_pool.py",
                     "simple_pool_picker.py", "ui_tests_dispatch.py"):
            self.assertIn(f"scripts/ci/{name}", sparse)
        names = [step.get("name") for step in steps]
        check = steps[names.index("Re-run a cancelled nightly-next tip")]
        self.assertTrue(check["continue-on-error"])
        self.assertNotIn("if", check)  # every train mode, "off" included: the promotion still runs then
        self.assertEqual(check["run"], 'bash .tick-tooling/scripts/ci/nightly_next_cancelled_tip.sh "$GITHUB_REPOSITORY"')
        self.assertLess(names.index("Wait through GitHub API rate limits in this job's gh calls"),
                        names.index("Re-run a cancelled nightly-next tip"))


if __name__ == "__main__":
    unittest.main()
