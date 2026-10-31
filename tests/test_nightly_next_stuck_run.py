#!/usr/bin/env python3
"""scripts/ci/nightly_next_stuck_run.py cancels a nightly run stuck on a runner label that stopped serving."""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sys
import unittest
import zlib
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("nightly_next_stuck_run", ROOT / "scripts/ci/nightly_next_stuck_run.py")
stuck = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = stuck  # dataclasses resolve the module's string annotations through it
SPEC.loader.exec_module(stuck)
TICK = ROOT / ".github/workflows/nightly-next-tick.yml"
CI_GUARDS = ROOT / ".github/workflows/ci-guards.yml"

NOW = dt.datetime(2026, 10, 29, 6, 0, tzinfo=dt.timezone.utc)
TIP = "1f0f687b2f32a9f506e19e7f683e8362fd3da6b2"
OLD = "0" * 40


def ago(minutes: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(name: str, minutes: float = 34, label: str = "blacksmith-4vcpu-ubuntu-2404", status: str = "queued",
        runner: str | None = None, conclusion: str | None = None, job_id: int = 0) -> dict:
    return {"id": job_id or zlib.crc32(name.encode()) + 1, "name": name, "status": status, "conclusion": conclusion,
            "runner_name": runner, "labels": [label], "created_at": ago(minutes),
            "completed_at": ago(minutes) if status == "completed" else None}


def done(name: str) -> dict:
    return job(name, status="completed", conclusion="success", runner="r")


def run(run_id: int, status: str = "queued", event: str = "push", sha: str = TIP, attempt: int = 1,
        title: str = "Nightly", branch: str = "nightly-next") -> dict:
    return {"id": run_id, "event": event, "status": status, "conclusion": None, "run_attempt": attempt,
            "head_sha": sha, "display_title": title, "head_branch": branch}


STUCK = [job("decide"), job("signer-build", label="blacksmith-8vcpu-ubuntu-2404"), done("probe")]


class FakeGh:
    """gh, in process. `runs` are the listed runs (branch by event and head; promotions on main);
    `jobs[id]` a job list, or a list of job lists served one per read; `after_cancel[id]` the run
    states served after a cancel, one per read (the last repeats); `fail` substrings fail a read."""

    def __init__(self, runs=(), jobs=None, pending=None, after_cancel=None, fail=(), tip=TIP, page=100,
                 run_reads=None, shape=None, refuse=()):
        self.runs = {item["id"]: dict(item) for item in runs}
        self.jobs = jobs or {}
        self.pending = pending or {}
        self.after_cancel = after_cancel or {}
        self.run_reads = run_reads or {}
        self.fail, self.tip, self.page, self.shape, self.refuse = fail, tip, page, shape or {}, refuse
        self.calls: list[tuple[str, bool]] = []
        self.cancelled: dict[int, int] = {}
        self.reads: dict[str, int] = {}

    def writes(self) -> list[str]:
        return [path for path, write in self.calls if write]

    def __call__(self, args, write):
        path = args[-1]
        self.calls.append((path, write))
        if write:
            if any(part in path for part in self.refuse):
                raise stuck.Unreadable("refused")
            self.cancelled[int(path.split("/")[-2])] = 0
            return ""
        if any(part in path for part in self.fail):
            raise stuck.Unreadable("read failed")
        for part, body in self.shape.items():
            if part in path:
                return json.dumps(body)
        rel = path.split("repos/o/r/", 1)[1]
        if rel == "git/ref/heads/nightly-next":
            index = self.reads.get("tip", 0)
            self.reads["tip"] = index + 1
            tip = self.tip[min(index, len(self.tip) - 1)] if isinstance(self.tip, list) else self.tip
            return json.dumps({"object": {"sha": tip, "type": "commit"}})
        if rel.startswith("actions/workflows/nightly.yml/runs?"):
            query = dict(part.split("=", 1) for part in rel.split("?", 1)[1].split("&"))
            chosen = [item for item in self.runs.values() if item["status"] == query["status"]
                      and (item["display_title"].startswith("Promote") == (query["branch"] == "main"))
                      and item["event"] == query.get("event", item["event"])]
            page = int(query["page"])
            size = min(int(query["per_page"]), self.page)
            return json.dumps({"total_count": len(chosen), "workflow_runs": chosen[(page - 1) * size:page * size]})
        parts = rel.split("?")[0].split("/")
        run_id = int(parts[2])
        rest = parts[3:]
        if rest == ["pending_deployments"]:
            return json.dumps(self.pending.get(run_id, []))
        if rest == ["jobs"]:
            served = self.jobs.get(run_id, [])
            if served and isinstance(served[0], list):
                n = self.reads.get(f"jobs{run_id}", 0)
                self.reads[f"jobs{run_id}"] = n + 1
                served = served[min(n, len(served) - 1)]
            return json.dumps({"total_count": len(served), "jobs": served})
        if not rest:
            if run_id in self.cancelled:
                states = self.after_cancel.get(run_id, [dict(self.runs[run_id], status="completed", conclusion="cancelled")])
                n = self.cancelled[run_id]
                self.cancelled[run_id] = n + 1
                return json.dumps(states[min(n, len(states) - 1)])
            states = self.run_reads.get(run_id)
            if states:
                n = self.reads.get(f"run{run_id}", 0)
                self.reads[f"run{run_id}"] = n + 1
                return json.dumps(states[min(n, len(states) - 1)])
            return json.dumps(self.runs[run_id])
        raise AssertionError(f"unexpected read {path}")


def tick(gh: FakeGh) -> list[str]:
    lines: list[str] = []
    stuck.tick(stuck.Api("o/r", gh), log=lines.append, sleep=lambda _s: None, now=lambda: NOW)
    return lines


class StuckRun(unittest.TestCase):
    def cancels(self, gh: FakeGh) -> list[int]:
        return [int(path.split("/")[-2]) for path in gh.writes() if path.endswith("/cancel")]

    def test_the_tips_run_stuck_on_a_dead_label_is_cancelled_for_the_next_step_to_re_run(self):
        # Run 40771197361: decide waited 34 min on blacksmith-4vcpu-ubuntu-2404, a job queued beside it.
        gh = FakeGh(runs=[run(40771197361)], jobs={40771197361: STUCK})
        out = "\n".join(tick(gh))
        self.assertEqual(gh.writes(), ["repos/o/r/actions/runs/40771197361/cancel"])
        self.assertIn("decide was created 34 min ago and is queued with no runner on blacksmith-4vcpu-ubuntu-2404", out)
        self.assertIn("(nightly_next_cancelled_tip.sh) re-runs the tip", out)

    def test_a_run_that_is_running_waiting_or_briefly_queued_is_never_cancelled(self):
        cases = {
            "briefly queued": [job("decide", 19)],
            "another job running": [job("decide"), job("build", 5, status="in_progress", runner="r")],
            "a gate job waits": [job("decide"), job("sign", status="waiting")],
            "a job pending on a concurrency group": [job("decide"), job("publish", status="pending")],
            "an owned label": [job("build-nightly-app", label="glaeda-trusted-next-nightly")],
            "taken by a runner": [job("decide", runner="bs-1")],
        }
        for case, jobs in cases.items():
            with self.subTest(case):
                gh = FakeGh(runs=[run(7, "in_progress")], jobs={7: jobs})
                tick(gh)
                self.assertEqual(gh.writes(), [])

    def test_a_newly_unblocked_job_does_not_inherit_its_dependency_build_time(self):
        for minutes, cancel in ((1, False), (19, False), (20, True), (30, True)):
            with self.subTest(minutes_since_build=minutes):
                build = dict(done("build-nightly-app"), created_at=ago(70), completed_at=ago(minutes))
                gh = FakeGh(runs=[run(7)], jobs={7: [job("sign", minutes=70), build]})
                tick(gh)
                self.assertEqual(bool(gh.writes()), cancel)
        gh = FakeGh(runs=[run(7)], jobs={7: [job("sign"), dict(done("build"), completed_at=None)]})
        tick(gh)
        self.assertEqual(gh.writes(), [], "an unknown dependency completion time is not proof of a stall")

    def test_a_queued_owned_build_protects_its_downstream_jobs_before_each_cancel(self):
        mixed = [job("build-nightly-app", label="glaeda-trusted-next-nightly"), job("signer")]
        for case, reads, expected in (
            ("discovery", [mixed], []),
            ("before cancel", [STUCK, mixed], []),
            ("before force-cancel", [STUCK, STUCK, mixed], ["repos/o/r/actions/runs/7/cancel"]),
        ):
            with self.subTest(case):
                gh = FakeGh(runs=[run(7)], jobs={7: reads}, after_cancel={7: [run(7)]})
                tick(gh)
                self.assertEqual(gh.writes(), expected,
                                 "a queued owned build must stay under owned-pool recovery")

    def test_a_new_tip_revalidates_dispatch_and_attempt_cap_before_cancel(self):
        for current in (run(7, attempt=3), run(7, event="workflow_dispatch")):
            with self.subTest(run=current):
                gh = FakeGh(runs=[current], jobs={7: STUCK}, tip=[OLD, TIP])
                tick(gh)
                self.assertEqual(gh.writes(), [])
        gh = FakeGh(runs=[run(7, attempt=3)], jobs={7: STUCK}, tip=[OLD, OLD, TIP],
                    after_cancel={7: [run(7, attempt=3)]})
        tick(gh)
        self.assertEqual(gh.writes(), ["repos/o/r/actions/runs/7/cancel"],
                         "a newly current tip with no recovery path must not be force-cancelled")

    def test_a_runner_starting_during_the_final_tip_read_blocks_cancel(self):
        started = [job("decide", runner="bs-1")]
        class StartsOnTip(FakeGh):
            def __call__(self, args, write):
                if not write and args[-1].endswith("git/ref/heads/nightly-next"):
                    self.jobs[7] = [started]
                return super().__call__(args, write)

        gh = StartsOnTip(runs=[run(7)], jobs={7: [STUCK, STUCK]})
        tick(gh)
        self.assertEqual(gh.writes(), [], "a runner assigned during final validation must be observed")

    def test_only_a_main_promotion_with_an_active_replacement_path_is_cancelled(self):
        title = f"Promote nightly-next to tick:{TIP}"
        for train, branch in (("on", "main"), ("off", "nightly-next")):
            with self.subTest(train=train, branch=branch), mock.patch.dict(stuck.os.environ, {"NIGHTLY_NEXT_TRAIN": train}):
                gh = FakeGh(runs=[run(7, event="workflow_dispatch", title=title, branch=branch)], jobs={7: STUCK})
                tick(gh)
                self.assertEqual(gh.writes(), [])

    def test_a_gated_run_is_never_cancelled_whatever_its_jobs_show(self):
        for case, extra in {
            "the run is waiting (an environment)": dict(run_reads={7: [run(7, "waiting")]}),
            "the run is pending (a concurrency group)": dict(run_reads={7: [run(7, "pending")]}),
            "the run is requested": dict(run_reads={7: [run(7, "requested")]}),
            "a deployment waits for approval": dict(pending={7: [{"environment": {"name": "release"}}]}),
        }.items():
            with self.subTest(case):
                gh = FakeGh(runs=[run(7)], jobs={7: STUCK}, **extra)
                tick(gh)
                self.assertEqual(gh.writes(), [])

    def test_a_run_that_changes_between_the_reads_and_the_cancel_is_left_alone(self):
        for case, second in {
            "a runner took the job": [job("decide", runner="bs-1")],
            "a gate job appeared": [job("decide"), job("sign", status="waiting")],
        }.items():
            with self.subTest(case):
                gh = FakeGh(runs=[run(7)], jobs={7: [STUCK, second]})
                out = "\n".join(tick(gh))
                self.assertEqual(gh.writes(), [])
                self.assertIn("changed since it was read", out)
        gh = FakeGh(runs=[run(7)], jobs={7: STUCK}, run_reads={7: [run(7), run(7, attempt=2)]})
        tick(gh)
        self.assertEqual(gh.writes(), [], "a new attempt between the reads")

    def test_only_a_run_an_existing_path_builds_again_is_cancelled(self):
        gh = FakeGh(runs=[run(1), run(2, sha=OLD), run(3, event="workflow_dispatch", sha=OLD),
                          run(4, event="workflow_dispatch", sha=OLD, title=f"Promote nightly-next to tick:{TIP}", branch="main"),
                          run(5, event="workflow_dispatch"), run(6, attempt=3)],
                    jobs={i: STUCK for i in range(1, 7)})
        out = "\n".join(tick(gh))
        self.assertEqual(self.cancels(gh), [1, 2, 3, 4])
        self.assertIn("an older commit's run; the tip builds", out)
        self.assertIn("the tick's promotion request asks again", out)
        # The tip's dispatch and the tip's push run at the cap: nothing here builds them again.
        self.assertRegex(out, r"run 5 is stuck .* the tip's workflow_dispatch run on attempt 1")
        self.assertRegex(out, r"run 6 is stuck .* the tip's push run on attempt 3")

    def test_a_failed_read_cancels_nothing(self):
        for part in ("git/ref/heads/nightly-next", "workflows/nightly.yml/runs", "pending_deployments", "/jobs"):
            with self.subTest(part):
                gh = FakeGh(runs=[run(7)], jobs={7: STUCK}, fail=(part,))
                tick(gh)
                self.assertEqual(gh.writes(), [])
        gh = FakeGh(runs=[run(7)], jobs={7: STUCK}, run_reads={7: [None]})  # the run's own read: JSON null
        tick(gh)
        self.assertEqual(gh.writes(), [])

    def test_every_shape_the_reader_does_not_expect_is_unreadable(self):
        good_run, good_job = run(7), job("decide")
        bad_runs = {"id": [None, "7", True, 0], "event": [None, 3], "status": [None, "stuck", 3],
                    "conclusion": [3, {}, "weird"], "run_attempt": [None, "1", True, 0],
                    "head_sha": [None, "abc", TIP.upper()], "head_branch": [None, 3], "display_title": [None, 3]}
        bad_jobs = {"id": [None, "7", True], "name": [None, 3], "status": [None, "stuck"],
                    "conclusion": [3, {}, "weird"], "runner_name": [{}, [], 3],
                    "labels": [None, {}, [3], "x"], "created_at": [None, "yesterday", 3, "2026-02-30T00:00:00Z"]}
        for kind, good, cases in (("run", good_run, bad_runs), ("job", good_job, bad_jobs)):
            parse = stuck.Run.parse if kind == "run" else stuck.Job.parse
            parse(good)
            for key, values in cases.items():
                with self.subTest(kind=kind, missing=key):
                    with self.assertRaises(stuck.Unreadable):
                        parse({k: v for k, v in good.items() if k != key})
                for value in values:
                    with self.subTest(kind=kind, key=key, value=value):
                        with self.assertRaises(stuck.Unreadable):
                            parse(dict(good, **{key: value}))
        # Status and conclusion go together (round 9 of #27095): a completed object has a conclusion,
        # an unfinished one has none.
        for kind, good in (("run", good_run), ("job", good_job)):
            parse = stuck.Run.parse if kind == "run" else stuck.Job.parse
            with self.subTest(kind=kind, pair="completed without a conclusion"):
                with self.assertRaises(stuck.Unreadable):
                    parse(dict(good, status="completed", conclusion=None))
            with self.subTest(kind=kind, pair="queued with a conclusion"):
                with self.assertRaises(stuck.Unreadable):
                    parse(dict(good, status="queued", conclusion="success"))
        with self.assertRaises(stuck.Unreadable):
            stuck.Job.parse(dict(good_job, labels=[]))  # a queued job is judged by its label
        stuck.Job.parse(dict(good_job, status="completed", conclusion="skipped", labels=[]))  # a skipped job

    def test_a_malformed_answer_in_the_tick_cancels_nothing(self):
        for case, extra in {
            "a completed job with no conclusion": dict(jobs={7: [job("decide"), dict(done("probe"), conclusion=None)]}),
            "a job without runner_name": dict(jobs={7: [{k: v for k, v in job("decide").items() if k != "runner_name"}]}),
            "a runner_name object": dict(jobs={7: [job("decide"), dict(done("probe"), runner_name={})]}),
            "jobs an object": dict(shape={"/jobs": {"total_count": 1, "jobs": {"a": job("decide")}}}),
            "deployments null": dict(pending={7: None}, jobs={7: STUCK}),
            "deployments an object": dict(pending={7: {}}, jobs={7: STUCK}),
            "runs an object": dict(shape={"workflows/nightly.yml/runs": {"total_count": 1, "workflow_runs": {"7": run(7)}}}),
            "a listed run with event null": dict(runs=[dict(run(7), event=None)], jobs={7: STUCK}),
            "no jobs at all": dict(jobs={7: []}),
        }.items():
            with self.subTest(case):
                kwargs = {"runs": [run(7)], "jobs": {7: STUCK}, **extra}
                gh = FakeGh(**kwargs)
                tick(gh)
                self.assertEqual(gh.writes(), [], case)

    def test_every_page_is_read_and_the_count_must_add_up(self):
        # 130 newer runs of an older commit, all running, never hide a stuck one; listings page by 100.
        runs = [run(100 + i, "in_progress", sha=OLD) for i in range(130)] + [run(7)]
        jobs = {100 + i: [job("build", 3, status="in_progress", runner="r")] for i in range(130)}
        jobs[7] = STUCK
        gh = FakeGh(runs=runs, jobs=jobs, page=50)
        tick(gh)
        self.assertEqual(self.cancels(gh), [7])
        listed = [path for path, _ in gh.calls if "workflows/nightly.yml/runs" in path]
        self.assertTrue(any("page=3" in path for path in listed), listed)
        # A total_count the pages do not reach, or reach only by serving a run twice (the list moved
        # between page reads), is an unread listing.
        gh = FakeGh(runs=[run(7)], jobs={7: STUCK},
                    shape={"status=queued": {"total_count": 2, "workflow_runs": [run(7)]}})
        tick(gh)
        self.assertEqual(gh.writes(), [])

    def test_the_cancel_goes_out_once_with_no_wrapper_retries(self):
        seen = {}

        def fake_run(command, **kwargs):
            seen[" ".join(command)] = kwargs["env"].get("GH_BUDGET_WAIT_ATTEMPTS")
            return mock.Mock(returncode=0, stdout="{}", stderr="")

        with mock.patch.object(stuck.subprocess, "run", fake_run), mock.patch.dict(stuck.os.environ, {}, clear=False):
            stuck.os.environ.pop("GH_BUDGET_WAIT_ATTEMPTS", None)
            stuck.gh_cli(["api", "-X", "POST", "repos/o/r/actions/runs/7/cancel"], True)
            stuck.gh_cli(["api", "repos/o/r/actions/runs/7"], False)
        self.assertEqual(seen["gh api -X POST repos/o/r/actions/runs/7/cancel"], "1")
        self.assertIsNone(seen["gh api repos/o/r/actions/runs/7"])
        # A refused cancel leaves the run for the next tick, with no settle reads and no force-cancel.
        gh = FakeGh(runs=[run(7)], jobs={7: STUCK}, refuse=("/cancel",))
        out = "\n".join(tick(gh))
        self.assertEqual(gh.writes(), ["repos/o/r/actions/runs/7/cancel"])
        self.assertIn("the cancel was refused", out)

    def test_a_force_cancel_follows_only_a_run_still_stuck_on_the_same_attempt(self):
        still = run(7, "in_progress")
        gh = FakeGh(runs=[run(7)], jobs={7: STUCK}, after_cancel={7: [still]})
        tick(gh)
        self.assertEqual(gh.writes(), ["repos/o/r/actions/runs/7/cancel", "repos/o/r/actions/runs/7/force-cancel"])
        reads = [path for path, write in gh.calls if path == "repos/o/r/actions/runs/7" and not write]
        self.assertLessEqual(len(reads), 2 + 2 * (stuck.FORCE_AFTER + 1) + 1, "the settle wait is bounded")
        # Moved to a gate state after the cancel (round 9 of #27095), a new attempt, or unreadable:
        # no force-cancel.
        for case, states in {
            "waiting": [run(7, "waiting")], "pending": [run(7, "pending")], "requested": [run(7, "requested")],
            "a new attempt": [run(7, attempt=2)], "unreadable": [None],
        }.items():
            with self.subTest(case):
                gh = FakeGh(runs=[run(7)], jobs={7: STUCK}, after_cancel={7: states})
                out = "\n".join(tick(gh))
                self.assertEqual(gh.writes(), ["repos/o/r/actions/runs/7/cancel"], case)
                self.assertIn("has not been seen finished", out)
        # Still running after the reads, but a fresh stuck read no longer says stuck: no force-cancel.
        gh = FakeGh(runs=[run(7)], jobs={7: [STUCK, STUCK, [job("decide", runner="bs-1")]]},
                    after_cancel={7: [still]})
        tick(gh)
        self.assertEqual(gh.writes(), ["repos/o/r/actions/runs/7/cancel"])

    def test_a_run_that_finished_on_its_own_is_reported_as_such(self):
        gh = FakeGh(runs=[run(7)], jobs={7: STUCK},
                    after_cancel={7: [dict(run(7), status="completed", conclusion="success")]})
        out = "\n".join(tick(gh))
        self.assertEqual(gh.writes(), ["repos/o/r/actions/runs/7/cancel"])
        self.assertIn("finished on its own", out)

    def test_no_unfinished_run_reads_no_jobs(self):
        gh = FakeGh()
        out = "\n".join(tick(gh))
        self.assertFalse(any("/jobs" in path for path, _ in gh.calls))
        self.assertIn("no unfinished", out)

    def test_the_tick_cancels_before_it_re_runs_a_cancelled_tip_in_its_serialized_group(self):
        job_spec = yaml.safe_load(TICK.read_text())["jobs"]["request"]
        steps = job_spec["steps"]
        tooling = next(step for step in steps if step.get("with", {}).get("path") == ".tick-tooling")
        self.assertIn("scripts/ci/nightly_next_stuck_run.py", tooling["with"]["sparse-checkout"].split())
        names = [step.get("name") for step in steps]
        step = steps[names.index("Cancel a nightly-next run stuck without a runner")]
        self.assertTrue(step["continue-on-error"])
        self.assertLessEqual(step["timeout-minutes"], 5)
        self.assertEqual(step["env"]["NIGHTLY_NEXT_TRAIN"], "${{ vars.NIGHTLY_NEXT_TRAIN }}")
        self.assertEqual(step["run"], 'python3 .tick-tooling/scripts/ci/nightly_next_stuck_run.py "$GITHUB_REPOSITORY"')
        # Only in the shared tick group (no sha input), which runs one tick at a time.
        self.assertEqual(step.get("if"), "inputs.sha == ''")
        self.assertIn("|| 'nightly-next-tick' }}", job_spec["concurrency"]["group"])
        self.assertFalse(job_spec["concurrency"]["cancel-in-progress"])
        self.assertLess(names.index("Wait through GitHub API rate limits in this job's gh calls"),
                        names.index("Cancel a nightly-next run stuck without a runner"))
        self.assertLess(names.index("Cancel a nightly-next run stuck without a runner"),
                        names.index("Re-run a cancelled nightly-next tip"))
        self.assertIn("python3 tests/test_nightly_next_stuck_run.py", CI_GUARDS.read_text())


if __name__ == "__main__":
    unittest.main()
