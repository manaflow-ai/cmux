#!/usr/bin/env python3
"""scripts/ci/nightly_interaction_latency.py: which interactions a nightly touched, the bench run with its budget, and
the state that carries a stale interaction until it is measured. No network, no bun: the runner is a fake.
Run: python3 -I tests/test_ci_nightly_interaction_latency.py (also runs in nightly-interaction-latency.yml)."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
spec = importlib.util.spec_from_file_location(
    "nightly_interaction_latency", os.path.join(ROOT, "scripts", "ci", "nightly_interaction_latency.py"))
nil = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nil)


def empty():
    return nil.load_state(None)


class FakeRunner:
    """Writes a suite report for each bench: rows unless the bench is in `fail`."""

    def __init__(self, fail=()):
        self.fail, self.ran = set(fail), []

    def __call__(self, cmd, cwd=None):
        bench, out = cmd[cmd.index("--only") + 1], cmd[cmd.index("--out") + 1]
        self.ran.append(bench)
        if bench in self.fail:
            report = {"rows": [], "failed": [{"bench": bench, "why": "timed out after 105 s"}]}
        else:
            report = {"rows": [{"name": f"{bench}.p95", "p95": 12.5, "target": 16}], "failed": []}
        with open(out, "w") as f:
            json.dump(report, f)
        return subprocess.CompletedProcess(cmd, 0)


class Clock:
    def __init__(self, step=0.0):
        self.t, self.step = 0.0, step

    def __call__(self):
        self.t += self.step
        return self.t


class Tests(unittest.TestCase):
    def test_every_bench_is_in_the_suite(self):
        with open(os.path.join(ROOT, "webviews", "bench", "web-ui-suite.ts")) as f:
            suite = f.read()
        for key, (bench, _words, _own) in nil.INTERACTIONS.items():
            self.assertIn(f'name: "{bench}"', suite, key)
            self.assertIn(bench, nil.TIMEOUT_S, key)

    def test_touched_by_path(self):
        hit = nil.touched(["webviews/src/sidebar/List.tsx", "README.md"])
        self.assertEqual(set(hit), {"all_chats_list", "sidebar_fling"})
        self.assertEqual(nil.touched(["docs/x.md", "cmux-tui/src/lib.rs"]), {})
        self.assertEqual(set(nil.touched(["webviews/bun.lock"])), set(nil.INTERACTIONS))
        self.assertEqual(set(nil.touched(None)), set(nil.INTERACTIONS))
        # Another bench's file touches nobody; a bench's own file touches its interaction; a helper touches all.
        self.assertEqual(nil.touched(["webviews/bench/streaming-text-frames.bench.ts"]), {})
        self.assertEqual(set(nil.touched(["webviews/bench/chat-open.bench.ts"])), {"chat_open"})
        self.assertEqual(set(nil.touched(["webviews/bench/perfRow.ts"])), set(nil.INTERACTIONS))
        self.assertEqual(nil.touched(["webviews/src/agent-session/acpmux/conversation/Markdown.test.tsx"]), {})
        self.assertIn("chat_open", nil.touched(["webviews/test/support/papercutChat.ts"]))

    def test_first_run_measures_everything(self):
        planned = nil.plan(empty(), "h1", None, None)
        self.assertEqual(len(planned["run"]), len(nil.INTERACTIONS))
        self.assertEqual(planned["run"][0]["bench"], "agent-activity-groups")  # cheapest first
        self.assertEqual(planned["run"][-1]["bench"], "composer-typing")

    def test_failed_bench_stays_stale_until_measured(self):
        with tempfile.TemporaryDirectory() as d:
            p1 = nil.plan(empty(), "h1", None, None)
            s1 = nil.report(empty(), p1, nil.run(p1, d, d, runner=FakeRunner(fail={"chat-open"}), clock=Clock()))
            self.assertTrue(s1["interactions"]["chat_open"]["stale"])
            self.assertEqual(s1["interactions"]["chat_open"]["stale_sha"], "h1")
            self.assertFalse(s1["interactions"]["sidebar_fling"]["stale"])
            self.assertEqual(s1["interactions"]["sidebar_fling"]["measured_sha"], "h1")
            # h2 touches nothing: chat_open still runs (stale), and still failing keeps its first stale moment.
            p2 = nil.plan(s1, "h2", "h1", [])
            self.assertEqual([i["key"] for i in p2["run"]], ["chat_open"])
            s2 = nil.report(s1, p2, nil.run(p2, d, d, runner=FakeRunner(fail={"chat-open"}), clock=Clock()))
            self.assertEqual(s2["interactions"]["chat_open"]["stale_sha"], "h1")
            self.assertEqual(s2["interactions"]["sidebar_fling"]["measured_sha"], "h1")  # untouched keeps its rows
            # h3 measures it.
            p3 = nil.plan(s2, "h3", "h2", [])
            s3 = nil.report(s2, p3, nil.run(p3, d, d, runner=FakeRunner(), clock=Clock()))
            self.assertFalse(s3["interactions"]["chat_open"]["stale"])
            self.assertEqual(s3["interactions"]["chat_open"]["measured_sha"], "h3")

    def test_budget_leaves_the_rest_stale(self):
        with tempfile.TemporaryDirectory() as d:
            p = nil.plan(empty(), "h1", None, None)
            runner = FakeRunner()
            got = nil.run(p, d, d, budget_s=300, runner=runner, clock=Clock(step=50))
            self.assertIn("agent-activity-groups", runner.ran)
            self.assertNotIn("composer-typing", runner.ran)
            self.assertTrue(got["composer_typing"]["why"].startswith("not run:"))
            state = nil.report(empty(), p, got)
            self.assertTrue(state["interactions"]["composer_typing"]["stale"])

    def test_missing_results_are_stale(self):
        p = nil.plan(empty(), "h1", None, None)
        state = nil.report(empty(), p, {})
        self.assertTrue(all(r["stale"] for r in state["interactions"].values()))
        self.assertIn("STALE", nil.summary(state))

    def test_trusted_artifact(self):
        good = {"workflow_run": {"head_branch": "nightly-next", "head_repository_id": 7}}
        self.assertTrue(nil.trusted(good, 7))
        self.assertFalse(nil.trusted({"workflow_run": {"head_branch": "lane/x", "head_repository_id": 7}}, 7))
        self.assertFalse(nil.trusted({"workflow_run": {"head_branch": "nightly-next", "head_repository_id": 8}}, 7))
        self.assertFalse(nil.trusted(dict(good, expired=True), 7))


if __name__ == "__main__":
    unittest.main()
