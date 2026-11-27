#!/usr/bin/env python3
"""scripts/ci/cmux_next_dev_publish_supersede.py: which older DEV publish runs a newer one cancels (no network).

On 2026-11-09 13:30Z seven cmux NEXT DEV publish runs were open, each with its Linux jobs done and its Mac
jobs (verify, the tip DMG build) queued on glaeda-std-xcode-26.6, 1 of 57 runners online; the runner owner
cancelled four by hand. Publish and the tip feed refuse to roll back, so all but the newest were useless,
yet each held a Mac queue slot. The newest run now cancels the older ones whose Mac jobs have not started,
except the oldest of them (nearest a runner), so the channel keeps moving when the Mac wait is longer than
the handoff interval (the starvation a concurrency group caused on 2026-10-26).
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "cmux_next_dev_publish_supersede", ROOT / "scripts/ci/cmux_next_dev_publish_supersede.py")
supersede = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["cmux_next_dev_publish_supersede"] = supersede
SPEC.loader.exec_module(supersede)

REPO = "manaflow-ai/cmux"
STD = "glaeda-std-xcode-26.6"
LINUX = "blacksmith-4vcpu-ubuntu-2404"
VERIFY = "Verify signed cmux NEXT DEV"
TIP_DMG = "Build the unsigned cmux NEXT DEV tip DMG"
DELTAS = "Add deltas to the cmux NEXT DEV tip feed"
# This run: publish run 900 of source run 500.
ME, MY_SOURCE = 900, 500


def publish_run(ident, source, *, status="in_progress", created="2026-11-09T12:00:00Z", **overrides):
    title = f"cmux NEXT DEV daily · publish {source}"
    run = {"id": ident, "name": title, "display_title": title, "status": status, "conclusion": None,
           "event": "workflow_dispatch", "head_branch": "main", "path": ".github/workflows/cmux-next-dev-daily.yml",
           "created_at": created, "run_attempt": 1}
    run.update(overrides)
    return run


def job(name, status="completed", *, conclusion="success", runner="", created="2026-11-09T12:05:00Z",
        labels=(LINUX,)):
    return {"id": abs(hash((name, created))) % 10 ** 9, "name": name, "status": status,
            "conclusion": conclusion if status == "completed" else None,
            "runner_name": runner or (None if status != "completed" else "runner"),
            "labels": list(labels), "created_at": created}


def waiting(created="2026-11-09T12:05:00Z"):
    """Linux jobs done, verify and the tip DMG build queued on the std Mac label, no runner."""
    return [job("Build the signer"), job("Sign cmux NEXT DEV"), job("runner"),
            job(VERIFY, "queued", created=created, labels=(STD,)),
            job(TIP_DMG, "queued", created=created, labels=(STD,))]


class FakeApi:
    """The runs listing (filtered by its `status=` the way GitHub filters it) and each run's jobs.

    `jobs` maps a run id to its jobs, or to a list of job lists returned on successive reads; a run id missing
    from it fails its read. Every call is recorded."""

    def __init__(self, runs, jobs, *, cancel_status=202):
        self.runs, self.jobs = list(runs), dict(jobs)
        self.reads: dict[int, int] = {}
        self.calls: list[str] = []
        self.cancel_status = cancel_status

    def get(self, path):
        self.calls.append(f"GET {path}")
        if "/actions/workflows/cmux-next-dev-daily.yml/runs?" in path:
            assert "branch=main" in path and "event=workflow_dispatch" in path, path
            status = path.split("status=", 1)[1].split("&", 1)[0] if "status=" in path else None
            return {"workflow_runs": [run for run in self.runs if status is None or run["status"] == status]}
        run_id = int(path.split("/actions/runs/", 1)[1].split("/", 1)[0])
        if run_id not in self.jobs:
            raise RuntimeError(f"GET {path}: HTTP 502")
        found = self.jobs[run_id]
        if found and isinstance(found[0], list):
            index = self.reads.get(run_id, 0)
            self.reads[run_id] = index + 1
            found = found[min(index, len(found) - 1)]
        return {"jobs": found}

    def post(self, path, body):
        self.calls.append(f"POST {path}")
        return self.cancel_status

    def cancelled(self):
        return sorted(int(call.split("/actions/runs/", 1)[1].split("/", 1)[0])
                      for call in self.calls if call.startswith("POST ") and call.endswith("/cancel"))


def decide(api):
    lines = []
    result = supersede.cancel_superseded(api, REPO, ME, MY_SOURCE, log=lines.append)
    return result, lines


class CancelSupersededTests(unittest.TestCase):
    def test_the_oldest_waiting_run_is_kept_and_the_middle_ones_are_cancelled(self):
        # The 2026-11-09 picture: older publish runs all waiting for the one std Mac, and this newest one.
        runs = [publish_run(ME, MY_SOURCE, created="2026-11-09T13:20:00Z"),
                publish_run(101, 401, created="2026-11-09T12:00:00Z"),
                publish_run(102, 402, created="2026-11-09T12:20:00Z"),
                publish_run(103, 403, created="2026-11-09T12:40:00Z"),
                publish_run(104, 404, created="2026-11-09T13:00:00Z")]
        api = FakeApi(runs, {ME: waiting("2026-11-09T13:25:00Z"), 101: waiting("2026-11-09T12:05:00Z"),
                             102: waiting("2026-11-09T12:25:00Z"), 103: waiting("2026-11-09T12:45:00Z"),
                             104: waiting("2026-11-09T13:05:00Z")})
        result, lines = decide(api)
        self.assertEqual(sorted(result), [102, 103, 104])
        self.assertEqual(api.cancelled(), [102, 103, 104])
        self.assertTrue(any("keeping publish run 101" in line for line in lines), lines)
        # This run is never cancelled, nor even read.
        self.assertNotIn(ME, api.cancelled())
        self.assertFalse(any(f"/actions/runs/{ME}/" in call for call in api.calls), api.calls)

    def test_oldest_means_nearest_a_runner_by_the_mac_jobs_queue_time(self):
        # Run 102 was dispatched later but signed first: its Mac jobs queued before run 101's.
        runs = [publish_run(101, 401, created="2026-11-09T12:00:00Z"),
                publish_run(102, 402, created="2026-11-09T12:02:00Z")]
        api = FakeApi(runs, {101: waiting("2026-11-09T12:30:00Z"), 102: waiting("2026-11-09T12:10:00Z")})
        result, _ = decide(api)
        self.assertEqual(result, [101])

    def test_a_single_older_waiting_run_is_kept(self):
        api = FakeApi([publish_run(101, 401)], {101: waiting()})
        result, _ = decide(api)
        self.assertEqual(result, [])
        self.assertEqual(api.cancelled(), [])

    def test_a_run_with_a_mac_job_in_progress_is_left_alone(self):
        started = waiting()
        started[3] = job(VERIFY, "in_progress", runner="cmux15-glaeda", labels=(STD,))
        runs = [publish_run(101, 401, created="2026-11-09T11:00:00Z"), publish_run(102, 402), publish_run(103, 403)]
        api = FakeApi(runs, {101: started, 102: waiting(), 103: waiting("2026-11-09T12:06:00Z")})
        result, lines = decide(api)
        # 101 runs on a Mac: it is no candidate, so 102 is the oldest candidate and kept; 103 goes.
        self.assertEqual(result, [103])
        self.assertNotIn(101, api.cancelled())
        self.assertTrue(any("publish run 101" in line and "is running" in line for line in lines), lines)

    def test_a_mac_job_a_runner_took_counts_as_started(self):
        taken = waiting()
        taken[3] = job(VERIFY, "queued", runner="cmux15-glaeda", labels=(STD,))
        api = FakeApi([publish_run(101, 401), publish_run(102, 402), publish_run(103, 403)],
                      {101: waiting(), 102: taken, 103: waiting("2026-11-09T12:06:00Z")})
        result, _ = decide(api)
        self.assertEqual(result, [103])
        self.assertNotIn(102, api.cancelled())

    def test_a_running_linux_job_keeps_the_run(self):
        publishing = [*waiting()[:3], job(VERIFY), job("Publish cmux NEXT DEV", "in_progress", runner="bs-1"),
                      job(TIP_DMG, "queued", labels=(STD,))]
        api = FakeApi([publish_run(101, 401), publish_run(102, 402), publish_run(103, 403)],
                      {101: waiting(), 102: publishing, 103: waiting("2026-11-09T12:06:00Z")})
        result, _ = decide(api)
        self.assertEqual(result, [103])

    def test_a_run_with_a_newer_source_is_never_cancelled(self):
        # A handoff for a later source run (or the same one) is never superseded by this run.
        runs = [publish_run(101, 401), publish_run(102, 402),
                publish_run(905, 600, created="2026-11-09T11:00:00Z"),
                publish_run(906, MY_SOURCE, created="2026-11-09T11:00:00Z")]
        api = FakeApi(runs, {101: waiting(), 102: waiting("2026-11-09T12:06:00Z"),
                             905: waiting("2026-11-09T11:00:00Z"), 906: waiting("2026-11-09T11:00:00Z")})
        result, _ = decide(api)
        self.assertEqual(result, [102])
        self.assertNotIn(905, api.cancelled())
        self.assertNotIn(906, api.cancelled())
        self.assertFalse(any("/actions/runs/905/" in call or "/actions/runs/906/" in call for call in api.calls))

    def test_a_run_whose_mac_jobs_all_finished_is_left_alone(self):
        finished = [*waiting()[:3], job(VERIFY), job(TIP_DMG), job("Publish cmux NEXT DEV", "queued")]
        api = FakeApi([publish_run(101, 401), publish_run(102, 402), publish_run(103, 403)],
                      {101: finished, 102: waiting(), 103: waiting("2026-11-09T12:06:00Z")})
        result, lines = decide(api)
        self.assertEqual(result, [103])
        self.assertNotIn(101, api.cancelled())
        self.assertTrue(any("publish run 101" in line and "no Mac job" in line for line in lines), lines)

    def test_a_run_with_no_mac_job_yet_is_left_alone(self):
        # Still signing: its Mac jobs do not exist yet.
        signing = [job("Build the signer"), job("Sign cmux NEXT DEV", "queued")]
        api = FakeApi([publish_run(101, 401), publish_run(102, 402)], {101: signing, 102: waiting()})
        result, _ = decide(api)
        self.assertEqual(result, [])

    def test_queued_tip_deltas_counts_as_a_waiting_mac_job(self):
        deltas = [*waiting()[:3], job(VERIFY), job(TIP_DMG), job("Publish cmux NEXT DEV"),
                  job(DELTAS, "queued", labels=(STD,), created="2026-11-09T12:50:00Z")]
        api = FakeApi([publish_run(101, 401), publish_run(102, 402)], {101: waiting(), 102: deltas})
        result, _ = decide(api)
        self.assertEqual(result, [102])

    def test_a_mac_job_that_starts_before_the_cancel_keeps_the_run(self):
        started = waiting("2026-11-09T12:06:00Z")
        started[3] = job(VERIFY, "in_progress", runner="cmux15-glaeda", labels=(STD,))
        api = FakeApi([publish_run(101, 401), publish_run(102, 402)],
                      {101: waiting(), 102: [waiting("2026-11-09T12:06:00Z"), started]})
        result, lines = decide(api)
        self.assertEqual(result, [])
        self.assertEqual(api.cancelled(), [])
        self.assertTrue(any("now; left alone" in line for line in lines), lines)

    def test_unreadable_jobs_keep_the_run(self):
        api = FakeApi([publish_run(101, 401), publish_run(102, 402), publish_run(103, 403)],
                      {101: waiting(), 103: waiting("2026-11-09T12:06:00Z")})
        result, _ = decide(api)
        self.assertEqual(result, [103])
        self.assertNotIn(102, api.cancelled())

    def test_other_titles_branches_and_events_are_never_touched(self):
        runs = [publish_run(101, 401),
                publish_run(110, 402, name="cmux NEXT DEV daily", display_title="cmux NEXT DEV daily"),
                publish_run(111, 403, head_branch="feat-cmux-next"),
                publish_run(112, 404, event="push"),
                publish_run(113, 405, display_title="cmux NEXT DEV daily · publish 405 extra",
                            name="cmux NEXT DEV daily · publish 405 extra")]
        api = FakeApi(runs, {ident: waiting("2026-11-09T12:06:00Z") for ident in (110, 111, 112, 113)}
                      | {101: waiting()})
        result, _ = decide(api)
        self.assertEqual(result, [])

    def test_a_queued_rerun_is_listed_too(self):
        # A re-run of failed jobs puts the run back to `queued` while its Mac job waits.
        api = FakeApi([publish_run(101, 401), publish_run(102, 402, status="queued", run_attempt=2)],
                      {101: waiting(), 102: waiting("2026-11-09T12:06:00Z")})
        result, _ = decide(api)
        self.assertEqual(result, [102])

    def test_a_refused_cancel_is_reported_not_counted(self):
        api = FakeApi([publish_run(101, 401), publish_run(102, 402)],
                      {101: waiting(), 102: waiting("2026-11-09T12:06:00Z")}, cancel_status=409)
        result, lines = decide(api)
        self.assertEqual(result, [])
        self.assertTrue(any("could not cancel publish run 102" in line for line in lines), lines)


class MainTests(unittest.TestCase):
    def test_main_cancels_through_the_injected_api(self):
        api = FakeApi([publish_run(101, 401), publish_run(102, 402)],
                      {101: waiting(), 102: waiting("2026-11-09T12:06:00Z")})
        code = supersede.main(["--run-id", str(ME), "--source-run-id", str(MY_SOURCE), "--repo", REPO], env={},
                              api=api)
        self.assertEqual(code, 0)
        self.assertEqual(api.cancelled(), [102])

    def test_main_rejects_ids_that_are_not_numbers(self):
        self.assertEqual(supersede.main(["--run-id", "x", "--source-run-id", "1"], env={}, api=FakeApi([], {})), 2)
        self.assertEqual(supersede.main([], env={"GITHUB_RUN_ID": "1"}, api=FakeApi([], {})), 2)

    def test_a_listing_that_fails_cancels_nothing_and_does_not_fail_the_run(self):
        class Down(FakeApi):
            def get(self, path):
                raise RuntimeError(f"GET {path}: HTTP 403")
        api = Down([], {})
        # Captured: the warning is a workflow command, which must not annotate this guard's own run.
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = supersede.main(["--run-id", "1", "--source-run-id", "2"], env={}, api=api)
        self.assertEqual(code, 0)
        self.assertEqual(api.cancelled(), [])
        self.assertIn("nothing cancelled", out.getvalue())


if __name__ == "__main__":
    unittest.main()
