#!/usr/bin/env python3
"""render-done-checks.py (p03-rendering-005) against a fixture tree: each query's count, its annotations, the
ghostty-next pin check, the --frameclients and --invalidate listings, and the bench JSON readers."""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/render-done-checks.py"
SPEC = importlib.util.spec_from_file_location("render_done_checks", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RDC = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RDC  # dataclasses resolve string annotations through it
SPEC.loader.exec_module(RDC)

SOURCES = "Packages/macOS/CmuxNext/Sources"
GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                          env=GIT_ENV).stdout.strip()


@unittest.skipUnless(shutil.which("rg"), "needs ripgrep")
class FixtureTree(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / SOURCES).mkdir(parents=True)
        self.tree = RDC.Tree(self.root, shutil.which("rg"))

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text).lstrip("\n"))
        return path

    def src(self, rel, text):
        return self.write(f"{SOURCES}/{rel}", text)

    def row(self, check_id):
        check = next(c for c in RDC.CHECKS if c.id == check_id)
        return check.evaluate(self.tree)

    def run_main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = RDC.main(["--repo", str(self.root), *args])
        return code, out.getvalue()


class LineQueries(FixtureTree):
    def test_dc1_allows_only_display_clock_and_vsync_hub(self):
        self.src("CmuxNextWakeups/DisplayClock.swift", "let link = CADisplayLink(target: self)\n")
        self.src("CmuxNextWakeups/VSyncHub.swift", "let l = window.displayLink(target: self, selector: s)\n")
        row = self.row("DC1")
        self.assertEqual((row.count, row.status), (0, "PASS"))
        self.src("CmuxNextWakeups/FrameScheduler.swift", "let l = window.displayLink(target: self, selector: s)\n")
        row = self.row("DC1")
        self.assertEqual((row.count, row.status), (1, "FAIL"))
        self.assertEqual(row.items, [f"{SOURCES}/CmuxNextWakeups/FrameScheduler.swift"])

    def test_sync_layout_needs_the_annotation_on_the_line_or_the_line_above(self):
        self.src("CmuxNextApp/A.swift", """
            func a() {
                view.layoutSubtreeIfNeeded() // sync-layout: the snapshot reads the final frame
                // sync-layout: the popup measures its content first
                CATransaction.flush()
                // sync-layout: two lines above does not count

                window.displayIfNeeded()
                layer.display()
            }
        """)
        row = self.row("DC11-sync-layout")
        self.assertEqual(row.count, 2, row.items)
        self.assertEqual([i.split(":")[1] for i in row.items], ["7", "8"])
        self.assertEqual(self.row("MQ-sync-layout").status, "OPEN")

    def test_an_empty_annotation_does_not_count(self):
        self.src("CmuxNextApp/A.swift", "view.layoutSubtreeIfNeeded() // sync-layout:\n")
        self.assertEqual(self.row("DC11-sync-layout").count, 1)

    def test_springs_count_files_and_skip_the_motion_core(self):
        self.src("CmuxNextLayout/A.swift", "var x = SpringValue(0)\nvar y = AnimatedFrame()\n")
        self.src("CmuxNextLayout/B.swift", "// input-driven: follows the pointer\nvar x = SpringValue(0)\n")
        self.src("CmuxNextDesign/Motion/Spring.swift", "struct SpringValue {}\n")
        row = self.row("MQ-springs")
        self.assertEqual(row.count, 1, row.items)
        self.assertTrue(all("CmuxNextLayout/A.swift" in i for i in row.items))

    def test_pane_autolayout_reads_only_the_named_app_files(self):
        line = "v.translatesAutoresizingMaskIntoConstraints = false\n"
        self.src("CmuxNextApp/PaneContentView+Toolbar.swift", line)
        self.src("CmuxNextApp/Screens/HomeScreen.swift", line)
        self.src("CmuxNextApp/Settings/SettingsView.swift", line)
        self.src("CmuxNextTabs/TabStripView.swift", line)
        self.assertEqual(self.row("MQ-pane-autolayout").count, 3)

    def test_loops_through_loop_visibility_are_marked(self):
        self.src("CmuxNextDesign/Spinner.swift", """
            spin.repeatCount = .infinity
            LoopVisibility.attach(layer, key: "spin") { spin.repeatCount = .infinity }
        """)
        self.assertEqual(self.row("MQ-loops").count, 1)

    def test_web_queries_read_webviews(self):
        self.write("webviews/src/a.ts", "requestAnimationFrame(tick)\nel.style.animation = 'x 1s infinite'\n")
        self.assertEqual(self.row("MQ-web-raf").count, 1)
        self.assertEqual(self.row("MQ-web-raf").status, "INFO")
        self.assertEqual(self.row("MQ-web-loops").count, 1)


class CommQueries(FixtureTree):
    def test_redraw_policy_lists_update_layer_files_without_a_policy(self):
        self.src("CmuxNextSidebar/A.swift", "override func updateLayer() {}\n")
        self.src("CmuxNextSidebar/B.swift",
                 "override public func updateLayer() {}\nlayerContentsRedrawPolicy = .never\n")
        self.src("CmuxNextSidebar/C.swift", "layerContentsRedrawPolicy = .onSetNeedsDisplay\n")
        row = self.row("MQ-redraw-policy")
        self.assertEqual(row.items, [f"{SOURCES}/CmuxNextSidebar/A.swift"])
        self.assertEqual(self.row("DC11-redraw-policy").status, "FAIL")
        self.assertIn("comm -23", row.query)

    def test_tracking_areas_are_the_intersection_minus_annotated_files(self):
        self.src("A.swift", "override func updateTrackingAreas() {}\nopts = [.inVisibleRect]\n")
        self.src("B.swift", "// tracking-area: options follow the hover state\noverride func updateTrackingAreas() {}\n"
                            "opts = [.inVisibleRect]\n")
        self.src("C.swift", "override func updateTrackingAreas() {}\n")
        row = self.row("MQ-tracking-areas")
        self.assertEqual(row.items, [f"{SOURCES}/A.swift"])

    def test_shadow_path_accepts_the_alpha_derived_reason(self):
        self.src("A.swift", "layer.shadowOpacity = 0.3\n")
        self.src("B.swift", "layer.shadowOpacity = 0.3\nlayer.shadowPath = path\n")
        self.src("C.swift", "layer.shadowOpacity = 0.3 // shadow: alpha-derived text glyphs\n")
        self.assertEqual(self.row("MQ-shadow-path").items, [f"{SOURCES}/A.swift"])


class FrameClients(FixtureTree):
    def test_debug_only_and_marked_sites_pass_the_rest_are_listed(self):
        self.src("CmuxNextWakeups/Probe.swift", """
            #if DEBUG || CMUX_BENCH_HOOKS
            let probe = FrameClient(owner: "debug.frames") { _ in true }
            #if canImport(AppKit)
            let nested = FrameClient(owner: "debug.nested") { _ in true }
            #endif
            #else
            let release = FrameClient(owner: "release.branch") { _ in true }
            #endif
        """)
        self.src("CmuxNextTabs/Autoscroll.swift", """
            // input-driven: edge autoscroll while the pointer is in the zone
            let a = FrameClient(owner: "tabs.autoscroll") { _ in true }
            let b = FrameClient(owner: "tabs.hold") { _ in true } // frame-client: holds the frame for the grid
            let c = FrameClient(owner: "tabs.unmarked") { _ in true }
        """)
        self.src("CmuxNextApp/Release.swift", """
            #if os(macOS)
            let d = FrameClient(owner: "app.release") { _ in true }
            #endif
        """)
        code, out = self.run_main("--frameclients")
        self.assertEqual(code, 1)
        self.assertIn("query: rg -n 'FrameClient\\(owner:'", out)
        self.assertIn(": 3 (threshold 0)", out)
        for owner in ("release.branch", "tabs.unmarked", "app.release"):
            self.assertIn(owner, out)
        for owner in ("debug.frames", "debug.nested", "tabs.autoscroll", "tabs.hold"):
            self.assertNotIn(owner, out)

    def test_no_unmarked_site_exits_0(self):
        self.src("A.swift", "#if DEBUG\nlet p = FrameClient(owner: \"p\") { _ in true }\n#endif\n")
        code, out = self.run_main("--frameclients")
        self.assertEqual(code, 0, out)


class Invalidate(FixtureTree):
    def test_change_checks_and_reasons_pass(self):
        self.src("CmuxNextSidebar/Row.swift", """
            var title = "" { didSet { if title != oldValue { needsLayout = true } } }
            var a = 0 {
                didSet {
                    guard a != oldValue else { return }
                    needsDisplay = true
                }
            }
            var b = 0 { didSet { needsLayout = true } }
            func apply(_ c: Int) {
                // invalidate: the theme changed every color
                needsDisplay = true
            }
            func f() { needsLayout = true }
        """)
        self.src("CmuxNextHome/Other.swift", "func g() { needsLayout = true }\n")
        code, out = self.run_main("--invalidate", f"{SOURCES}/CmuxNextSidebar")
        self.assertEqual(code, 1)
        self.assertIn(": 2 (threshold 0)", out)
        self.assertIn("Row.swift:8:", out)
        self.assertIn("Row.swift:13:", out)
        self.assertNotIn("Other.swift", out)
        code, out = self.run_main("--invalidate")
        self.assertIn(": 3 (threshold 0)", out)


class GhosttyPin(FixtureTree):
    def gitlink(self):
        module = self.root / "ghostty-next"
        module.mkdir()
        git(self.root, "init", "-q")
        git(module, "init", "-q")
        (module / "src/renderer").mkdir(parents=True)
        (module / "src/renderer/generic.zig").write_text("const DisplayLink = @import(\"x\");\n")
        git(module, "add", ".")
        git(module, "commit", "-q", "-m", "pin")
        pin = git(module, "rev-parse", "HEAD")
        git(self.root, "update-index", "--add", "--cacheinfo", f"160000,{pin},ghostty-next")
        git(self.root, "commit", "-q", "-m", "gitlink")
        return module, pin

    def test_uninitialized_submodule_fails_and_skips_ghostty_rows(self):
        module, pin = self.gitlink()
        shutil.rmtree(module / ".git")
        state = RDC.ghostty_state(self.root)
        self.assertEqual((state.pin, state.head, state.ok), (pin, None, False))
        self.assertIn("not initialized", state.describe())
        rows = {r.id: r for r in RDC.evaluate(self.tree, state)}
        self.assertEqual(rows["GHOSTTY"].status, "FAIL")
        self.assertEqual(rows["MQ-displaylinks-ghostty"].status, "SKIP")
        self.assertIsNone(rows["MQ-displaylinks-ghostty"].count)
        code, out = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("git submodule update --init ghostty-next", out)

    def test_pinned_submodule_runs_the_ghostty_queries(self):
        self.gitlink()
        state = RDC.ghostty_state(self.root)
        self.assertTrue(state.ok, state.describe())
        rows = {r.id: r for r in RDC.evaluate(self.tree, state)}
        self.assertEqual(rows["GHOSTTY"].status, "PASS")
        self.assertEqual((rows["MQ-displaylinks-ghostty"].count, rows["MQ-displaylinks-ghostty"].status), (1, "OPEN"))
        self.assertEqual(rows["DC6-ghostty"].status, "PASS")

    def test_a_submodule_off_the_pin_fails(self):
        module, pin = self.gitlink()
        (module / "x").write_text("x")
        git(module, "add", "x")
        git(module, "commit", "-q", "-m", "moved")
        state = RDC.ghostty_state(self.root)
        self.assertFalse(state.ok)
        self.assertIn(f"pins {pin[:12]}", state.describe())


class BenchJson(FixtureTree):
    def bench(self, name, data):
        path = self.root / f"{name}.json"
        path.write_text(json.dumps(data))
        return str(path)

    def test_motion_counts_pass_and_fail_by_scenario(self):
        path = self.bench("motion", {"scenarios": {"cmd-d": {"frame_sets": 0, "layouts": 0, "update_visibility": 2},
                                                   "cmd-w": {"frame_sets": 3, "layouts": 0, "update_visibility": 4}}})
        rows = {r.id: r for r in RDC.bench_rows("motion", path)}
        self.assertEqual(rows["DC2 frame_sets"].status, "FAIL")
        self.assertEqual(rows["DC2 frame_sets"].items, ["scenarios.cmd-w.frame_sets = 3"])
        self.assertEqual(rows["DC2 layouts"].status, "PASS")
        self.assertEqual(rows["DC2 update_visibility"].count, 1)
        self.assertNotIn("DC2 window_calls", rows)

    def test_a_file_without_the_bench_keys_fails(self):
        rows = RDC.bench_rows("hitches", self.bench("wrong", {"switches": 3}))
        self.assertEqual([r.status for r in rows], ["FAIL"])
        self.assertIn("not a --hitches report", rows[0].note)

    def test_typing_and_cef_read_distributions(self):
        typing = self.bench("typing", {"runs": [{"key_to_frame_ms": {"p50": 6.1, "p99": 15.0}},
                                                {"key_to_frame_ms": {"p50": 9.0, "p99": 20.0}}]})
        rows = {r.id: r for r in RDC.bench_rows("typing", typing)}
        self.assertEqual((rows["DC5 key_to_frame_ms.p50"].count, rows["DC5 key_to_frame_ms.p99"].count), (1, 1))
        cef = self.bench("cef", {"modes": {"on": {"switch": {"a": {"input_to_commit_ms": {"p95": 8.3},
                                                                  "longest_frame_ms": {"max": 8.0}}}}}})
        rows = {r.id: r for r in RDC.bench_rows("cef", cef)}
        self.assertEqual(rows["DC10 input_to_commit_ms.p95"].status, "FAIL")  # strict < 8.3
        self.assertEqual(rows["DC10 longest_frame_ms.max"].status, "PASS")

    def test_idle_sums_app_and_daemon_and_flags_render_owners(self):
        path = self.bench("idle", {"scenarios": {
            "terminals": {"processes": [{"kind": "app", "wakeups_per_s": 0.4}, {"kind": "daemon", "wakeups_per_s": 0.4},
                                        {"kind": "terminal-host", "wakeups_per_s": 3.0}],
                          "ledger": [{"owner": "FrameScheduler.window", "reason": "stalled frame", "per_second": 0.2},
                                     {"owner": "Sidebar.refresh", "reason": "timer", "per_second": 0.1}]},
            "minimized": {"processes": [{"kind": "app", "wakeups_per_s": 0.9},
                                        {"kind": "daemon", "wakeups_per_s": 0.5}]},
            "chromium-hidden": {"skipped": "no Chromium"}}})
        rows = {r.id: r for r in RDC.bench_rows("idle", path)}
        self.assertEqual(rows["DC7j app+daemon"].items, ["minimized: app + daemon 1.4/s"])
        self.assertEqual(rows["DC7r render wakeups"].items, ["terminals: FrameScheduler.window stalled frame 0.2/s"])

    def test_unreadable_json_is_a_tool_error(self):
        self.src("A.swift", "\n")
        bad = self.root / "bad.json"
        bad.write_text("{")
        code, out = self.run_main("--motion", str(bad))
        self.assertEqual(code, 2)
        self.assertIn("cannot read bench JSON", out)


class Output(FixtureTree):
    def test_every_row_prints_query_count_and_threshold(self):
        self.src("CmuxNextApp/A.swift", "view.layoutSubtreeIfNeeded()\n")
        out_json = self.root / "rows.json"
        code, out = self.run_main("--json", str(out_json))
        self.assertEqual(code, 1)  # DC11 and the missing gitlink fail
        self.assertRegex(out, r"DC11-sync-layout\s+FAIL\s+count 1\s+threshold 0")
        self.assertIn("query: rg -n 'layoutSubtreeIfNeeded|displayIfNeeded", out)
        rows = json.loads(out_json.read_text())["rows"]
        self.assertEqual({r["id"] for r in rows} - {"GHOSTTY"}, {c.id for c in RDC.CHECKS})
        for r in rows:
            self.assertTrue(r["query"] and r["threshold"], r)

    def test_not_a_checkout_is_a_tool_error(self):
        shutil.rmtree(self.root / "Packages")
        code, out = self.run_main()
        self.assertEqual(code, 2)
        self.assertIn("pass --repo", out)


class Registration(unittest.TestCase):
    def test_manual_lane_with_the_reason_and_no_ci_reference(self):
        text = (ROOT / "tests/test-execution.toml").read_text()
        entry = text.split('path = "tests/test_render_done_checks.py"', 1)[1].split("[[test]]", 1)[0]
        self.assertIn('lane = "manual"', entry)
        self.assertIn("fleet and local tool; Lawrence 2026-10-23 no new CI tests", entry)
        self.assertNotIn(".github", SCRIPT.read_text())


if __name__ == "__main__":
    unittest.main()
