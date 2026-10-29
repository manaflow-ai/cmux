#!/usr/bin/env python3
"""scripts/ci/nightly_next_stuck_run.sh cancels a nightly run stuck on a runner label that stopped serving."""
from __future__ import annotations

import datetime as dt
import json
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "nightly_next_stuck_run.sh"
TICK = ROOT / ".github" / "workflows" / "nightly-next-tick.yml"
TIP = "1f0f687b2f32a9f506e19e7f683e8362fd3da6b2"

# git is not used: nightly-next's head comes from the refs API (the fake gh below; GIT_FAIL fails that
# read, GIT_TIP answers another value). A git here fails, so a script that still reads git fails its test.
FAKE_GIT = """#!/bin/bash
echo "git is not used by the tick's scripts" >&2
exit 128
"""

# A stateful GitHub. Every call is logged. State (env, JSON):
#   NEXT_RUNS / MAIN_RUNS  the workflow runs of nightly-next and main; the listing honours
#                          `status=` and serves them PAGE (default 2) a page, as --paginate reads them;
#   JOBS                   {run id: [jobs]}; JOBS_LATER {run id: [jobs]} answers every read after the first;
#   PENDING                {run id: [deployments]};
#   STATE_LATER            {run id: status} the run's status from its second read on (before a cancel);
#   AFTER_CANCEL           the status a run reads after a cancel (default completed), with
#                          CONCLUSION (default cancelled) and ATTEMPT_AFTER_CANCEL;
#   FAIL                   a substring: any read whose path contains it fails;
#   UNREADABLE_AFTER_CANCEL  a run's read fails once it has been cancelled.
FAKE_GH = r'''#!PYTHON
import json, os, subprocess, sys, urllib.parse
TIP_SHA = "@TIP@"
from pathlib import Path

args = sys.argv[1:]
with open(os.environ["LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
state = Path(os.environ["STATE_DIR"])
env = lambda name, default: json.loads(os.environ.get(name) or default)
jq = args[args.index("--jq") + 1] if "--jq" in args else "."


def out(value):
    result = subprocess.run(["jq", "-r", jq], input=json.dumps(value), capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.exit(result.returncode)


if args[:2] == ["workflow", "run"]:
    sys.exit(1 if os.environ.get("DISPATCH_FAIL") else 0)
if args[:1] == ["run"]:
    sys.exit(0)
path = next(arg for arg in args if arg.startswith("repos/"))
if "-X" in args:  # POST: cancel, force-cancel, a job re-run
    with open(os.environ["LOG"], "a") as log:
        log.write("retries=" + os.environ.get("GH_BUDGET_WAIT_ATTEMPTS", "default") + "\n")
    if os.environ.get("CANCEL_FAIL"):
        sys.exit(1)
    if path.endswith("cancel"):
        (state / path.split("/")[5]).write_text("cancelled")
    sys.exit(0)
if os.environ.get("FAIL") and os.environ["FAIL"] in path:
    sys.exit(1)
if path.endswith("/git/ref/heads/nightly-next"):  # the refs API answers nightly-next's head
    if os.environ.get("GIT_FAIL"):
        sys.exit(1)
    out({"object": {"sha": os.environ.get("GIT_TIP") or TIP_SHA, "type": "commit"}})
runs = env("NEXT_RUNS", "[]") + env("MAIN_RUNS", "[]")
if "/workflows/nightly.yml/runs?" in path:
    query = dict(urllib.parse.parse_qsl(path.split("?", 1)[1]))
    source = env("NEXT_RUNS" if query.get("branch") == "nightly-next" else "MAIN_RUNS", "[]")
    chosen = [run for run in source if run["status"] == query.get("status", run["status"])
              and run["event"] == query.get("event", run["event"])
              and run["head_sha"] == query.get("head_sha", run["head_sha"])
              and not (state / str(run["id"])).exists()]
    chosen += [dict(run, status="completed") for run in source if (state / str(run["id"])).exists()
               and "status" not in query and run["head_sha"] == query.get("head_sha", run["head_sha"])]
    size = int(os.environ.get("PAGE", "2"))
    for start in range(0, max(len(chosen), 1), size):  # --paginate: --jq applies to each page
        page = {"workflow_runs": chosen[start:start + size]}
        result = subprocess.run(["jq", "-r", jq], input=json.dumps(page), capture_output=True, text=True)
        sys.stdout.write(result.stdout)
        if result.returncode:  # gh --jq fails on a jq error, as the real one does
            sys.exit(result.returncode)
    sys.exit(0)
parts = path.split("?")[0].split("/")
run_id = parts[5]
rest = parts[6:]
if rest == ["pending_deployments"]:
    out(env("PENDING", "{}").get(run_id, []))
if rest == ["jobs"]:
    counter = state / f"jobs-{run_id}"
    reads = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(reads + 1))
    later = env("JOBS_LATER", "{}")
    jobs = later[run_id] if reads >= 1 and run_id in later else env("JOBS", "{}").get(run_id, [])
    out({"jobs": jobs})
if rest[:1] == ["attempts"]:
    out({"jobs": []})
if not rest:
    run = next((dict(r) for r in runs if str(r["id"]) == run_id), {"id": run_id, "status": "completed", "run_attempt": 1})
    counter = state / f"run-{run_id}"
    reads = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(reads + 1))
    if (state / run_id).exists():
        if os.environ.get("UNREADABLE_AFTER_CANCEL"):
            sys.exit(1)
        after = os.environ.get("AFTER_CANCEL", "completed")
        run.update(status=after, conclusion=os.environ.get("CONCLUSION", "cancelled") if after == "completed" else None)
        if os.environ.get("NULL_STATUS_AFTER_CANCEL"):
            run["status"] = None
        run["run_attempt"] = int(os.environ.get("ATTEMPT_AFTER_CANCEL", run["run_attempt"]))
    elif reads >= 1 and run_id in env("STATE_LATER", "{}"):
        run["status"] = env("STATE_LATER", "{}")[run_id]
    out(run)
sys.exit(3)
'''


def is_settle_read(call: str) -> bool:
    """The read after a cancel: the run's status, conclusion and attempt."""
    return call.startswith("api repos/o/r/actions/runs/7 --jq") and "conclusion" in call


def ago(minutes: float) -> str:
    return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(name: str, minutes: float, label: str = "blacksmith-4vcpu-ubuntu-2404", status: str = "queued",
        runner: str | None = None) -> dict:
    return {"name": name, "status": status, "runner_name": runner, "labels": [label], "created_at": ago(minutes)}


def run(run_id: int, status: str = "queued", event: str = "push", sha: str = TIP, attempt: int = 1,
        title: str = "") -> dict:
    return {"id": run_id, "status": status, "event": event, "head_sha": sha, "run_attempt": attempt,
            "display_title": title}


STUCK_DECIDE = job("decide", 34)


class StuckRun(unittest.TestCase):
    def run_script(self, jobs: dict, next_runs=(), main_runs=(), **env) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bin_dir = Path(tmp.name) / "bin"
        bin_dir.mkdir()
        state = Path(tmp.name) / "state"
        state.mkdir()
        for name, body in (("git", FAKE_GIT), ("gh", FAKE_GH.replace("#!PYTHON", f"#!{sys.executable}").replace("@TIP@", TIP)),
                           ("python3", f'#!/bin/bash\nexec "{sys.executable}" "$@"\n')):
            path = bin_dir / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC)
        log = Path(tmp.name) / "log"
        encoded = {key: value if isinstance(value, str) else json.dumps(
            {str(k): v for k, v in value.items()} if isinstance(value, dict) else value) for key, value in env.items()}
        result = subprocess.run(
            ["bash", str(SCRIPT), "o/r"], capture_output=True, text=True, timeout=60,
            env={"PATH": f"{bin_dir}:/usr/bin:/bin", "LOG": str(log), "STATE_DIR": str(state), "SETTLE_SECONDS": "0",
                 "JOBS": json.dumps({str(k): v for k, v in jobs.items()}), "NEXT_RUNS": json.dumps(list(next_runs)),
                 "MAIN_RUNS": json.dumps(list(main_runs)), **encoded})
        calls = log.read_text().splitlines() if log.exists() else []
        return result, calls

    def writes(self, calls: list[str]) -> list[str]:
        return [call for call in calls
                if "-X POST" in call or call.startswith("run rerun") or call.startswith("workflow run")]

    def test_the_tips_run_stuck_on_a_dead_label_is_cancelled_for_the_next_step_to_re_run(self):
        # Run 40771197361: decide waited 34 min on blacksmith-4vcpu-ubuntu-2404, two jobs queued beside it.
        jobs = {40771197361: [STUCK_DECIDE, job("signer-build", 34, "blacksmith-8vcpu-ubuntu-2404"),
                              job("probe", 34, status="completed")]}
        result, calls = self.run_script(jobs, next_runs=[run(40771197361)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/40771197361/cancel"])
        self.assertIn("decide has waited 34 min with no runner on blacksmith-4vcpu-ubuntu-2404", result.stdout)
        self.assertIn("the next step (nightly_next_cancelled_tip.sh) builds the tip again", result.stdout)

    def test_a_run_that_is_running_waiting_or_briefly_queued_is_never_cancelled(self):
        cases = {
            "briefly queued": [job("decide", 19)],
            "another job running": [STUCK_DECIDE, job("build", 5, status="in_progress", runner="r")],
            "a gate waits": [STUCK_DECIDE, job("sign", 40, status="waiting")],
            "a job pending on a concurrency group": [STUCK_DECIDE, job("publish", 40, status="pending")],
            "an owned label": [job("build-nightly-app", 40, "glaeda-trusted-next-nightly")],
            "taken by a runner": [job("decide", 40, runner="bs-1")],
        }
        for case, jobs in cases.items():
            with self.subTest(case):
                result, calls = self.run_script({7: jobs}, next_runs=[run(7, "in_progress")])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.writes(calls), [])
                self.assertIn("no job stuck", result.stdout)

    def test_a_run_waiting_on_a_gate_is_never_cancelled_whatever_its_jobs_show(self):
        # The run's own state and its deployments decide first: a run that is waiting on an
        # environment or a concurrency group shows queued jobs with no runner, and is not stuck.
        cases = {
            "the run is waiting (an environment gate)": dict(STATE_LATER={7: "waiting"}),
            "the run is pending (a concurrency group)": dict(STATE_LATER={7: "pending"}),
            "a deployment waits for approval": dict(PENDING={7: [{"environment": {"name": "release"}}]}),
        }
        for case, env in cases.items():
            with self.subTest(case):
                # The listing saw it queued; its own read says otherwise.
                result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)], **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.writes(calls), [], case)
        # A run listed as waiting is never even read.
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7, "waiting"), run(8, "pending")])
        self.assertEqual(self.writes(calls), [])
        self.assertFalse(any("runs/7" in call or "runs/8" in call for call in calls), calls)

    def test_a_run_that_changes_between_the_reads_and_the_cancel_is_left_alone(self):
        # The last read right before the cancel sees a runner take decide, or the run enter a gate.
        for case, env in {
            "a runner took the job": dict(JOBS_LATER={7: [job("decide", 34, runner="bs-1")]}),
            "a gate job appeared": dict(JOBS_LATER={7: [STUCK_DECIDE, job("sign", 1, status="waiting")]}),
        }.items():
            with self.subTest(case):
                result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)], **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.writes(calls), [])
                self.assertIn("changed since it was read", result.stdout)
        # The second read is the one right before the cancel.
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)])
        reads = [i for i, call in enumerate(calls) if call.startswith("api --paginate repos/o/r/actions/runs/7/jobs")]
        cancel = calls.index("api -X POST repos/o/r/actions/runs/7/cancel")
        self.assertEqual(len(reads), 2)
        self.assertEqual(reads[-1], cancel - 1, calls)

    def test_a_failed_read_cancels_nothing(self):
        for case, env in {
            "the tip": dict(GIT_FAIL="1"),
            "an unreadable tip line": dict(GIT_TIP="error: not a sha"),
            "the run list": dict(FAIL="workflows/nightly.yml/runs"),
            "the run": dict(FAIL="actions/runs/7"),
            "the deployments": dict(FAIL="pending_deployments"),
            "the jobs": dict(FAIL="/jobs"),
        }.items():
            with self.subTest(case):
                result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)], **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.writes(calls), [], case)

    def test_an_unexpected_shape_cancels_nothing(self):
        # Valid JSON of the wrong shape is unread, not "nothing there": pending deployments that are
        # null or an object, a job with no labels, null labels, empty labels or no status, and a run
        # with no jobs at all.
        stuck = dict(STUCK_DECIDE)
        cases = {
            "deployments null": ({7: [stuck]}, dict(PENDING={7: None})),
            "deployments an object": ({7: [stuck]}, dict(PENDING={7: {}})),
            "no labels": ({7: [{k: v for k, v in stuck.items() if k != "labels"}]}, {}),
            "null labels": ({7: [dict(stuck, labels=None)]}, {}),
            "empty labels": ({7: [dict(stuck, labels=[])]}, {}),
            "a non-string label": ({7: [dict(stuck, labels=[3])]}, {}),
            "no status": ({7: [{k: v for k, v in stuck.items() if k != "status"}]}, {}),
            "no created_at": ({7: [{k: v for k, v in stuck.items() if k != "created_at"}]}, {}),
            "no jobs": ({7: []}, {}),
        }
        for case, (jobs, env) in cases.items():
            with self.subTest(case):
                result, calls = self.run_script(jobs, next_runs=[run(7)], **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.writes(calls), [], case)
                self.assertIn("could not be read; left alone", result.stdout)

    def test_a_finished_job_with_no_labels_is_a_normal_shape(self):
        # A skipped job comes back with labels []: the run is still judged, and cancelled when stuck.
        skipped = dict(job("probe", 34, status="completed"), labels=[])
        result, calls = self.run_script({7: [STUCK_DECIDE, skipped]}, next_runs=[run(7)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel"])

    def test_a_run_listing_of_an_unexpected_shape_cancels_nothing(self):
        # jq renders a null as the word "null": each field's JSON type is checked before it is
        # formatted, so a null event, sha, id or attempt fails the listing instead of reading as text.
        for bad in (dict(run(7), event=None), dict(run(7), head_sha=None), dict(run(7), id=None),
                    dict(run(7), run_attempt=None), dict(run(7), event=3), dict(run(7), id="7")):
            with self.subTest(bad=bad):
                result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[bad])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.writes(calls), [])
                self.assertFalse(any("/jobs" in call for call in calls), calls)
                self.assertRegex(result.stdout, "could not be listed|unexpected shape")
        # The same for a promotion on main.
        bad = run(4, event="workflow_dispatch", sha="a" * 40, title=f"Promote nightly-next to tick:{TIP}")
        result, calls = self.run_script({4: [STUCK_DECIDE]}, main_runs=[dict(bad, head_sha=None)])
        self.assertEqual(self.writes(calls), [])
        # A run read on its own with a null status is unread too.
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)], STATE_LATER={7: None})
        self.assertEqual(self.writes(calls), [])

    def test_a_cancel_that_does_not_settle_is_force_cancelled(self):
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)], AFTER_CANCEL="in_progress",
                                        FORCE_AFTER="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel",
                                              "api -X POST repos/o/r/actions/runs/7/force-cancel"])
        # Bounded: FORCE_AFTER + 1 reads after each cancel, then the next tick.
        self.assertEqual(sum(is_settle_read(call) for call in calls), 6)
        self.assertIn("the next tick checks again", result.stdout)

    def test_an_unreadable_status_after_the_cancel_never_force_cancels(self):
        # settled() fails closed: a read error is neither "finished" nor "still running", so a run
        # that cannot be read after the cancel is never force-cancelled, and nothing is re-run.
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7, attempt=3)], AFTER_CANCEL="in_progress",
                                        FORCE_AFTER="1", UNREADABLE_AFTER_CANCEL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel"])
        self.assertEqual(sum(is_settle_read(call) for call in calls), 1)
        self.assertNotIn("api -X POST repos/o/r/actions/runs/7/force-cancel", self.writes(calls))
        self.assertIn("has not been seen finished", result.stdout)

    def test_a_run_of_an_unexpected_shape_after_the_cancel_is_never_force_cancelled(self):
        # A null status reads as unknown, not as "still running": no force-cancel.
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)], NULL_STATUS_AFTER_CANCEL="1",
                                        FORCE_AFTER="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel"])
        self.assertEqual(sum(is_settle_read(call) for call in calls), 1)

    def test_a_run_that_finished_on_its_own_before_the_cancel_gets_nothing_more(self):
        # Between the last stuck read and the cancel, the run succeeded, failed, or a new attempt
        # started: it is not reported as cancelled, and nothing more is done.
        for case, env in {
            "succeeded": dict(CONCLUSION="success"),
            "failed": dict(CONCLUSION="failure"),
            "a new attempt": dict(AFTER_CANCEL="queued", ATTEMPT_AFTER_CANCEL="4"),
        }.items():
            for event in ("push", "workflow_dispatch"):
                with self.subTest(case, event=event):
                    result, calls = self.run_script({7: [STUCK_DECIDE]},
                                                    next_runs=[run(7, event=event, attempt=3)], **env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel"], case)
                    self.assertIn("finished on its own", result.stdout)
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7, event="workflow_dispatch")],
                                        CONCLUSION="success")
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel"])

    def test_every_run_of_the_tip_is_handed_to_the_cancelled_tip_step(self):
        # The tip's push or dispatch, below the cap or at it: cancelled here, built again by the next
        # step from GitHub's record (the newest run of the tip ended cancelled), which survives this
        # tick. Nothing is re-run or dispatched here, so no write can strand or double the tip.
        for event in ("push", "workflow_dispatch"):
            for attempt in (1, 3):
                with self.subTest(event=event, attempt=attempt):
                    result, calls = self.run_script({7: [STUCK_DECIDE]},
                                                    next_runs=[run(7, event=event, attempt=attempt)])
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel"])
                    self.assertIn("builds the tip again", result.stdout)

    def test_the_cancel_writes_go_out_with_no_wrapper_retries(self):
        # gh_budget_wait.sh could hold a cancel through a rate limit for up to an hour after the last
        # stuck read: both writes are sent once, and a refused one leaves the run for the next tick.
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)], AFTER_CANCEL="in_progress",
                                        FORCE_AFTER="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        posts = [i for i, call in enumerate(calls) if "-X POST" in call]
        self.assertEqual(len(posts), 2, calls)
        for i in posts:
            self.assertEqual(calls[i + 1], "retries=1", calls)
        # The force-cancel follows a read that showed the same attempt unfinished.
        force = calls.index("api -X POST repos/o/r/actions/runs/7/force-cancel")
        self.assertTrue(is_settle_read(calls[force - 1]), calls)
        result, calls = self.run_script({7: [STUCK_DECIDE]}, next_runs=[run(7)], CANCEL_FAIL="1")
        self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel"])
        self.assertFalse(any(is_settle_read(call) for call in calls), calls)
        self.assertIn("the cancel was refused", result.stdout)

    def test_a_dispatch_and_older_commits_and_promotions_are_cancelled_and_never_re_run_here(self):
        jobs = {1: [STUCK_DECIDE], 2: [STUCK_DECIDE], 4: [STUCK_DECIDE], 5: [STUCK_DECIDE]}
        result, calls = self.run_script(
            jobs,
            next_runs=[run(1, event="workflow_dispatch"), run(2, sha="0" * 40), run(6, "completed")],
            main_runs=[run(4, event="workflow_dispatch", sha="a" * 40, title=f"Promote nightly-next to tick:{TIP}"),
                       run(5, event="workflow_dispatch", sha="a" * 40, title="Nightly")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(calls), [
            "api -X POST repos/o/r/actions/runs/1/cancel", "api -X POST repos/o/r/actions/runs/2/cancel",
            "api -X POST repos/o/r/actions/runs/4/cancel"])
        self.assertFalse(any("runs/5" in call or "runs/6" in call for call in calls), calls)

    def test_an_older_commits_run_is_never_re_run(self):
        # A dispatch or push of an older commit, stuck, is cancelled (the tip builds) and never
        # re-run or replaced, below the attempt cap and at it.
        for event in ("push", "workflow_dispatch"):
            for attempt in (1, 3):
                with self.subTest(event=event, attempt=attempt):
                    result, calls = self.run_script(
                        {7: [STUCK_DECIDE]}, next_runs=[run(7, event=event, sha="0" * 40, attempt=attempt)])
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.writes(calls), ["api -X POST repos/o/r/actions/runs/7/cancel"])
                    self.assertFalse(any("/attempts/" in call or "contents/" in call for call in calls), calls)
                    self.assertIn("not re-run", result.stdout)

    def test_every_page_of_unfinished_runs_is_read(self):
        # Thirty and more newer runs never hide a stuck one: the listing asks only for unfinished
        # runs and reads every page.
        runs = [run(100 + i, "in_progress", sha="0" * 40) for i in range(40)] + [run(7)]
        jobs = {100 + i: [job("build", 1, status="in_progress", runner="r")] for i in range(40)}
        jobs[7] = [STUCK_DECIDE]
        result, calls = self.run_script(jobs, next_runs=runs, PAGE="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("api -X POST repos/o/r/actions/runs/7/cancel", self.writes(calls))
        listings = [call for call in calls if "/workflows/nightly.yml/runs?" in call]
        self.assertTrue(listings)
        for call in listings:
            self.assertIn("--paginate", call)
            self.assertIn("per_page=100", call)
            self.assertRegex(call, r"status=(queued|in_progress)")

    def test_no_unfinished_run_reads_no_jobs(self):
        result, calls = self.run_script({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("/jobs" in call for call in calls), calls)
        self.assertIn("no unfinished", result.stdout)

    def test_the_tick_cancels_before_it_re_runs_a_cancelled_tip(self):
        steps = yaml.safe_load(TICK.read_text())["jobs"]["request"]["steps"]
        tooling = next(step for step in steps if step.get("with", {}).get("path") == ".tick-tooling")
        sparse = tooling["with"]["sparse-checkout"].split()
        for name in ("nightly_next_stuck_run.sh", "nightly_next_cancelled_tip.sh", "nightly_next_rerun.sh"):
            self.assertIn(f"scripts/ci/{name}", sparse)
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
