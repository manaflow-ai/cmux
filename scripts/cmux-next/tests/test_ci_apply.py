#!/usr/bin/env python3
"""ci_apply.py: which PRs can be checked against a prebuilt base build, and the replay's arithmetic.

Runs on any host (Linux included): no app, no fleet.

    python3 -m unittest scripts/cmux-next/tests/test_ci_apply.py
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import ci_apply  # noqa: E402
import live_apply  # noqa: E402

APP = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift"
PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneView.swift"
BODY = [("-", "        return 1"), ("+", "        return 2")]


def lane(files, diffs=None, **kw):
    return ci_apply.plan_from(live_apply.classify(files, diffs or {}), **kw)


class PlanTests(unittest.TestCase):
    def test_docs_only_needs_no_app_build(self):
        self.assertEqual(lane([("M", "docs/x.md")])["lane"], "no-app")

    def test_web_only_takes_the_web_lane(self):
        p = lane([("M", "webviews/src/agent-pane/App.tsx"), ("M", "docs/x.md")])
        self.assertEqual((p["lane"], p["appliers"]), ("web", ["web"]))

    def test_daemon_rust_takes_the_daemon_lane(self):
        self.assertEqual(lane([("M", "cmux-tui/crates/cmux-tui-core/src/server/cmd_server.rs")])["lane"], "daemon")

    def test_rust_the_app_links_needs_the_full_build(self):
        p = lane([("M", "cmux-tui/crates/cmux-app-ffi/src/lib.rs")])
        self.assertEqual(p["lane"], "full")
        self.assertIn("Rust the app links (FFI)", p["fallback"])

    def test_swift_body_edit_in_the_app_module_is_patched(self):
        p = lane([("M", APP)], {APP: BODY})
        self.assertEqual(p["lane"], "swift-body")

    def test_swift_outside_the_patched_modules_needs_the_full_build(self):
        self.assertEqual(lane([("M", PANE)], {PANE: BODY})["lane"], "full")

    def test_a_stored_property_needs_the_full_build(self):
        p = lane([("M", APP)], {APP: [("+", "    var count = 0")]})
        self.assertEqual(p["lane"], "full")
        self.assertIn("stored property", p["fallback"])

    def test_web_and_daemon_take_both_appliers(self):
        p = lane([("M", "webviews/src/a.tsx"), ("M", "cmux-tui/crates/cmux-tui-core/src/a.rs")])
        self.assertEqual((p["lane"], p["appliers"]), ("web+daemon", ["web", "daemon"]))

    def test_full_ci_label_and_non_pr_events_build_clean(self):
        self.assertEqual(lane([("M", "webviews/src/a.tsx")], labels={"full-ci"})["lane"], "full")
        self.assertEqual(lane([("M", "webviews/src/a.tsx")], event="push")["lane"], "full")

    def test_package_manifest_needs_the_full_build(self):
        self.assertEqual(lane([("M", "Packages/macOS/CmuxNext/Package.swift")])["lane"], "full")

    def test_commands_start_from_the_base_tree_build(self):
        p = lane([("M", "webviews/src/a.tsx")])
        p.update(base="B", head="H")
        steps = ci_apply.commands(p)
        self.assertTrue(steps[0].startswith("cmux-ci build cmux --ref B --any-tag"))
        self.assertTrue(any("build-web-bundles.sh" in s for s in steps))


def run(name, conclusion, start, end):
    return {"name": name, "conclusion": conclusion, "startedAt": start, "completedAt": end}


class ReplayTests(unittest.TestCase):
    def head(self, oid, runs):
        return {"oid": oid, "checkSuites": {"nodes": [
            {"workflowRun": {"event": "pull_request", "workflow": {"name": wf}}, "checkRuns": {"nodes": rs}}
            for wf, rs in runs.items()]}}

    def test_dropped_app_compile_and_kept_tests(self):
        jobs = ci_apply.head_jobs(self.head("a", {"cmux-next": [
            run("cmux-next app compile (build fleet)", "SUCCESS", "2026-11-05T00:00:00Z", "2026-11-05T00:10:00Z"),
            run("cmux-next swift test", "SUCCESS", "2026-11-05T00:00:00Z", "2026-11-05T00:20:00Z")]}))
        names = {j["name"]: ci_apply.dropped(j["name"], "web", ["web"]) for j in jobs}
        self.assertEqual(names, {"cmux-next / cmux-next app compile (build fleet)": True,
                                 "cmux-next / cmux-next swift test": False})
        self.assertFalse(any(ci_apply.dropped(n, "full", []) for n in names))

    def test_a_red_compile_on_a_lane_head_is_a_miss(self):
        with tempfile.TemporaryDirectory() as d:
            prs, checks = Path(d, "prs.jsonl"), Path(d, "checks.jsonl")
            prs.write_text(json.dumps({"number": 1, "mergeCommit": None, "labels": {"nodes": []},
                                       "commits": {"nodes": [{"commit": {"oid": "a"}}]}}) + "\n")
            checks.write_text(json.dumps(self.head("a", {"cmux-next": [
                run("cmux-next app compile (build fleet)", "FAILURE", "2026-11-05T00:00:00Z", "2026-11-05T00:05:00Z"),
                run("cmux-next swift test", "SUCCESS", "2026-11-05T00:00:00Z", "2026-11-05T00:20:00Z")]})) + "\n")
            original = ci_apply.merge_diff_plan
            ci_apply.merge_diff_plan = lambda repo, pr: {"lane": "web", "appliers": ["web"], "fallback": {}, "files": {}}
            try:
                rep = ci_apply.replay(d, str(prs), str(checks))
            finally:
                ci_apply.merge_diff_plan = original
            (row,) = rep["heads"]
            self.assertEqual((row["full"], row["fast"]), ("red", "green"))
            self.assertEqual(row["dropped_failed"], ["cmux-next / cmux-next app compile (build fleet)"])
            self.assertAlmostEqual(row["dropped_min"], 5.0)
            self.assertIn("misses (full red, lane green): 1", ci_apply.summarize(rep))


if __name__ == "__main__":
    unittest.main()
