#!/usr/bin/env python3
"""scripts/ci/cmux_machine_channel_twin.py: a push takes an earlier same-tree-key push's build (TWIN_BUILD)."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("twin", ROOT / "scripts/ci/cmux_machine_channel_twin.py")
twin = importlib.util.module_from_spec(spec)
sys.modules["twin"] = twin
spec.loader.exec_module(twin)

X86, ARM = "x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"
PREFIX = "machine-channel-"
SHA, P1, P2, P3 = "s" * 40, "a" * 40, "b" * 40, "c" * 40
PARENTS = {SHA: [P1, P2, P3]}


def job(target, status="completed", conclusion="success", lane=True):
    lane_part = " x86_64 lane 2" if lane else ""
    return {"name": f"build-machine-channel{lane_part} / build {target}", "status": status, "conclusion": conclusion}


class Fake:
    def __init__(self, runs=(), jobs=None, artifacts=None):
        self.runs, self.jobs, self.artifacts = list(runs), jobs or {}, artifacts or {}
        self.calls = []

    def __call__(self, path):
        self.calls.append(path)
        if path.startswith("actions/workflows/"):
            assert "branch=feat-cmux-next" in path and "event=push" in path, path
            return {"workflow_runs": self.runs}
        run = int(path.split("/")[2])
        if path.startswith(f"actions/runs/{run}/artifacts"):
            a = self.artifacts.get(run, [])
            a = a(len(self.calls)) if callable(a) else a
            return {"artifacts": [{"name": n} for n in a]}
        return {"jobs": self.jobs.get(run, [])}


def find(api, keys):
    return twin.find(api, SHA, key=lambda r: keys.get(r, ""), parents=lambda r: PARENTS.get(r, []))


class Find(unittest.TestCase):
    def test_takes_the_newest_same_key_ancestors_live_build(self):
        api = Fake(runs=[{"id": 10, "head_sha": P2}, {"id": 11, "head_sha": P1}],
                   jobs={11: [job(X86, status="in_progress", conclusion=None)], 10: [job(X86)]})
        self.assertEqual(find(api, {SHA: "k", P1: "k", P2: "k", P3: "k"}), 11)

    def test_passes_over_a_run_that_built_nothing(self):
        # P1's run took a twin or a PR head (no build job): P2's build is the one.
        api = Fake(runs=[{"id": 10, "head_sha": P2}, {"id": 11, "head_sha": P1}],
                   jobs={11: [{"name": "plan", "status": "completed", "conclusion": "success"}],
                         10: [job(X86, lane=False)]})
        self.assertEqual(find(api, {SHA: "k", P1: "k", P2: "k"}), 10)

    def test_a_failed_or_cancelled_build_is_not_taken(self):
        api = Fake(runs=[{"id": 11, "head_sha": P1}], jobs={11: [job(X86, conclusion="failure")]})
        self.assertIsNone(find(api, {SHA: "k", P1: "k"}))
        api = Fake(runs=[{"id": 11, "head_sha": P1}], jobs={11: [job(X86, conclusion="cancelled")]})
        self.assertIsNone(find(api, {SHA: "k", P1: "k"}))

    def test_stops_at_the_first_other_key(self):
        # P2 has another key: P3's build (same key as SHA again) is not this tree's.
        api = Fake(runs=[{"id": 13, "head_sha": P3}], jobs={13: [job(X86)]})
        self.assertIsNone(find(api, {SHA: "k", P1: "k", P2: "other", P3: "k"}))

    def test_a_merge_that_moved_an_input_builds_with_no_api_call(self):
        api = Fake()
        self.assertIsNone(find(api, {SHA: "k", P1: "other"}))
        self.assertEqual(api.calls, [])
        self.assertIsNone(find(api, {P1: "k"}))  # no key for SHA
        self.assertEqual(api.calls, [])

    def test_job_reads_are_bounded(self):
        runs = [{"id": i, "head_sha": P1} for i in range(20)]
        api = Fake(runs=runs, jobs={i: [] for i in range(20)})
        self.assertIsNone(find(api, {SHA: "k", P1: "k"}))
        self.assertEqual(sum("/jobs" in c for c in api.calls), twin.MAX_JOB_READS)

    def test_the_build_job_names(self):
        self.assertTrue(twin.build_job(X86).match(f"build-machine-channel x86_64 lane 3 / build {X86}"))
        self.assertTrue(twin.build_job(X86).match(f"build-machine-channel / build {X86}"))
        self.assertFalse(twin.build_job(X86).match(f"build-machine-channel / build {ARM}"))
        self.assertFalse(twin.build_job(X86).match(f"build-linux / build {X86}"))


def run_wait(api, targets, wait_s=1500):
    clock = [0.0]
    return twin.wait(api, 7, targets, PREFIX, wait_s, sleep=lambda s: clock.__setitem__(0, clock[0] + s),
                     now=lambda: clock[0])


class Wait(unittest.TestCase):
    def test_returns_once_every_artifact_is_there(self):
        names = [f"{PREFIX}cmux-tui-{X86}", f"{PREFIX}cmux-tui-{ARM}"]
        api = Fake(jobs={7: [job(X86, "in_progress", None), job(ARM, "in_progress", None)]},
                   artifacts={7: lambda n: names if n > 4 else names[:1]})
        self.assertEqual(run_wait(api, [X86, ARM]), 7)

    def test_x86_64_alone_needs_its_artifact_only(self):
        api = Fake(artifacts={7: [f"{PREFIX}cmux-tui-{X86}"]})
        self.assertEqual(run_wait(api, [X86]), 7)

    def test_a_build_that_ended_without_its_artifact_is_a_miss(self):
        api = Fake(jobs={7: [job(X86, conclusion="failure")]}, artifacts={7: []})
        self.assertIsNone(run_wait(api, [X86]))

    def test_an_artifact_trailing_the_jobs_end_is_taken(self):
        name = f"{PREFIX}cmux-tui-{X86}"
        api = Fake(jobs={7: [job(X86)]}, artifacts={7: lambda n: [name] if n > 1 else []})
        self.assertEqual(run_wait(api, [X86]), 7)

    def test_the_wait_is_bounded(self):
        api = Fake(jobs={7: [job(X86, "queued", None)]}, artifacts={7: []})
        self.assertIsNone(run_wait(api, [X86], wait_s=300))
        self.assertLessEqual(sum("/artifacts" in c for c in api.calls), 7)


class Workflow(unittest.TestCase):
    def test_the_twin_is_wired_to_the_waiters_and_the_points(self):
        text = (ROOT / ".github/workflows/cmux-machine-channel.yml").read_text()
        jobs = yaml.safe_load(text)["jobs"]
        self.assertIn("twin_run", jobs["plan"]["outputs"])
        self.assertIn("cmux_machine_channel_twin.py find", text)
        for waiter, point in (("twin-x86_64", "point-x86_64"), ("twin-linux", "point-linux")):
            w = jobs[waiter]
            self.assertIn("needs.plan.outputs.twin_run != ''", w["if"])
            self.assertIn("needs.plan.outputs.twin_run", w["concurrency"]["group"])
            self.assertFalse(w["concurrency"]["cancel-in-progress"])
            self.assertEqual(w["permissions"], {"contents": "read", "actions": "read"})
            p = jobs[point]
            self.assertIn(waiter, p["needs"])
            self.assertIn(f"needs.{waiter}.outputs.from_run != ''", p["if"])
            dl = [s for s in p["steps"] if "download-artifact" in str(s.get("uses", ""))]
            self.assertTrue(dl and all(f"needs.{waiter}.outputs.from_run" in str(s["with"]["run-id"]) for s in dl))
        self.assertIn("--target aarch64-unknown-linux-musl", str(jobs["twin-linux"]["steps"]))
        self.assertNotIn("aarch64", str(jobs["twin-x86_64"]["steps"]))
        self.assertIn("needs.plan.outputs.twin_run != ''", jobs["machine-channel-journey-baseline"]["if"])


if __name__ == "__main__":
    unittest.main()
