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


def queries_of(check):
    if isinstance(check, RDC.CommCheck):
        return (check.left, check.right)
    return getattr(check, "queries", ())


def make_scope(root, scope):
    """An empty file or directory for each scope path the checks read (a glob: one file that matches it)."""
    path = root / scope.replace("*", "")
    if path.suffix in (".swift", ".zig"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
    else:
        path.mkdir(parents=True, exist_ok=True)


@unittest.skipUnless(shutil.which("rg"), "needs ripgrep")
class FixtureTree(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / SOURCES).mkdir(parents=True)
        for scope in sorted({p for c in RDC.CHECKS for q in queries_of(c) for p in q.paths}):
            if not scope.startswith(RDC.GHOSTTY):  # the pin tests make the submodule
                make_scope(self.root, scope)
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

    def test_displaylinks_queue_is_done_with_only_the_one_link_per_display_owners(self):
        self.src("CmuxNextWakeups/DisplayClock.swift", "let link = CADisplayLink(target: self)\n")
        self.src("CmuxNextWakeups/VSyncHub.swift", "var link: CVDisplayLink?\n")
        self.assertEqual((self.row("MQ-displaylinks").count, self.row("MQ-displaylinks").status), (0, "DONE"))
        self.src("CmuxNextTerminal/FrameScheduler.swift", "let l = window.displayLink(target: self, selector: s)\n")
        row = self.row("MQ-displaylinks")
        self.assertEqual((row.count, row.status), (1, "OPEN"))
        self.assertTrue(row.items[0].startswith(f"{SOURCES}/CmuxNextTerminal/FrameScheduler.swift:1:"), row.items)

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

    def test_a_trailing_annotation_on_the_line_above_counts(self):
        # The plan and task 066's guardrail: "on the line or the line above", comment-only or not.
        self.src("CmuxNextApp/A.swift", """
            header.layoutSubtreeIfNeeded() // sync-layout: the header and the body measure together
            body.layoutSubtreeIfNeeded()
            footer.layoutSubtreeIfNeeded()
        """)
        row = self.row("DC11-sync-layout")
        self.assertEqual([i.split(":")[1] for i in row.items], ["3"])
        self.src("CmuxNextSidebar/Row.swift", """
            func apply() {
                update() // invalidate: the theme changed every color
                needsDisplay = true
            }
        """)
        code, out = self.run_main("--invalidate", f"{SOURCES}/CmuxNextSidebar")
        self.assertEqual(code, 0, out)

    def test_a_missing_scope_path_fails_the_row(self):
        shutil.rmtree(self.root / SOURCES / "CmuxNextTerminal")
        row = self.row("MQ-pane-autolayout")
        self.assertEqual(row.status, "FAIL")
        self.assertIn(f"{SOURCES}/CmuxNextTerminal", row.note)
        (self.root / SOURCES / "CmuxNextApp/PaneContentView.swift").unlink()
        self.assertIn(f"{SOURCES}/CmuxNextApp/PaneContentView*.swift", self.row("MQ-pane-autolayout").items)
        shutil.rmtree(self.root / "webviews")
        self.assertEqual(self.row("MQ-web-raf").status, "FAIL")  # an info row too: a gone scope is no count

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
            let c = FrameClient(owner: "tabs.unmarked") { _ in true }
            let b = FrameClient(owner: "tabs.hold") { _ in true } // frame-client: holds the frame for the grid
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

    def test_a_path_that_does_not_exist_is_a_usage_error(self):
        self.src("CmuxNextSidebar/Row.swift", "func f() { needsLayout = true }\n")
        code, out = self.run_main("--invalidate", f"{SOURCES}/CmuxNextSidebr")
        self.assertEqual(code, 2)
        self.assertIn("CmuxNextSidebr: no such file or directory", out)
        code, out = self.run_main("--invalidate", str(Path(self._tmp.name).parent))
        self.assertEqual(code, 2)
        self.assertIn("outside the checkout", out)

    def test_a_path_is_read_against_the_working_directory_first(self):
        self.src("CmuxNextSidebar/Row.swift", "func f() { needsLayout = true }\n")
        here = os.getcwd()
        os.chdir(self.root / SOURCES)
        try:
            code, out = self.run_main("--invalidate", "CmuxNextSidebar")
        finally:
            os.chdir(here)
        self.assertEqual(code, 1)
        self.assertIn(f"{SOURCES}/CmuxNextSidebar/Row.swift:1:", out)


def kit_manifest(sha):
    return (".binaryTarget(\n    name: \"GhosttyNextKit\",\n    url: \"https://github.com/manaflow-ai/ghostty-next/releases/"
            f"download/xcframework-{sha}-apple-v6/GhosttyNextKit.xcframework.zip\",\n    checksum: \"00\"\n)\n")


class GhosttyPin(FixtureTree):
    def gitlink(self, kit=None):
        """A root repo whose ghostty-next gitlink is the submodule's HEAD and whose GhosttyNextKit url names KIT
        (default: that same commit)."""
        module = self.root / "ghostty-next"
        module.mkdir()
        git(self.root, "init", "-q")
        git(module, "init", "-q")
        (module / "src/renderer/metal").mkdir(parents=True)
        (module / "src/renderer/generic.zig").write_text("const DisplayLink = @import(\"x\");\n")
        (module / "src/renderer/metal/IOSurfaceLayer.zig").write_text("const std = @import(\"std\");\n")
        git(module, "add", ".")
        git(module, "commit", "-q", "-m", "pin")
        pin = git(module, "rev-parse", "HEAD")
        self.write(RDC.GHOSTTY_KIT, kit_manifest(kit or pin))
        git(self.root, "add", RDC.GHOSTTY_KIT)
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
        # The DisplayLink path stays for vsync_external off (task 082): a count, not a queue that never ends.
        self.assertEqual((rows["MQ-displaylinks-ghostty"].count, rows["MQ-displaylinks-ghostty"].status), (1, "INFO"))
        self.assertEqual(rows["DC6-ghostty"].status, "PASS")

    def test_a_submodule_off_the_pin_fails(self):
        module, pin = self.gitlink()
        (module / "x").write_text("x")
        git(module, "add", "x")
        git(module, "commit", "-q", "-m", "moved")
        state = RDC.ghostty_state(self.root)
        self.assertFalse(state.ok)
        self.assertIn(f"pins {pin[:12]}", state.describe())

    def test_a_gitlink_off_the_ghosttynextkit_source_fails_and_skips_ghostty_rows(self):
        other = "a" * 40
        module, pin = self.gitlink(kit=other)
        state = RDC.ghostty_state(self.root)
        self.assertEqual((state.pin, state.head, state.kit), (pin, pin, other))
        self.assertTrue(state.initialized)
        self.assertFalse(state.ok)
        rows = {r.id: r for r in RDC.evaluate(self.tree, state)}
        self.assertEqual(rows["GHOSTTY"].status, "PASS")
        self.assertEqual(rows["GHOSTTY-kit"].status, "FAIL")
        self.assertIn(f"built from {other[:12]}", rows["GHOSTTY-kit"].note)
        self.assertEqual(rows["DC6-ghostty"].status, "SKIP")
        code, out = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("move both in one pin commit", out)

    def test_no_ghosttynextkit_url_fails(self):
        module, pin = self.gitlink()
        self.write(RDC.GHOSTTY_KIT, "// no binary target\n")
        git(self.root, "commit", "-q", "-am", "drop the kit")
        state = RDC.ghostty_state(self.root)
        self.assertIsNone(state.kit)
        self.assertIn("no GhosttyNextKit release url", state.describe_kit())


class GhosttyPinLane(unittest.TestCase):
    """LANE-ghostty-pins: the gitlink moves in the window before HEAD, each naming its ghostty-next PRs."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        git(self.root, "init", "-q", "-b", "main")
        self.clock = 1_800_000_000

    def tearDown(self):
        self._tmp.cleanup()

    def timed_git(self, hours_later, *args):
        self.clock += hours_later * 3600
        stamp = f"@{self.clock} +0000"
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True,
                       env={**GIT_ENV, "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp})

    def commit(self, message, hours_later, sha=None):
        if sha:
            git(self.root, "update-index", "--add", "--cacheinfo", f"160000,{sha},ghostty-next")
        else:
            (self.root / "other.txt").write_text(f"{self.clock} {message}")
            git(self.root, "add", "other.txt")
        self.timed_git(hours_later, "commit", "-q", "-m", message)

    def pin(self, n, message, hours_later=1):
        self.commit(message, hours_later, sha=f"{n:x}".rjust(40, "0"))

    def merge(self, branch, message, hours_later=1):
        """Land BRANCH on the checked-out branch the way perf/chrome-parity lands task branches."""
        self.timed_git(hours_later, "merge", "-q", "--no-ff", "-m", message, branch)

    def branch(self, name, start="main"):
        git(self.root, "checkout", "-q", "-B", name, start)

    def test_a_named_pin_landed_by_a_merge_commit_is_done(self):
        self.commit("base", 0)
        self.branch("cp/x")
        self.pin(1, "ghostty-next: bump (manaflow-ai/ghostty-next#88)")
        self.branch("main", "main")
        self.commit("unrelated on main", 1)
        self.merge("cp/x", "Merge cp/x: x")
        row = RDC.pin_lane_row(self.root, 72)
        self.assertEqual((row.count, row.status), (1, "DONE"), row.items)
        self.assertIn("ghostty-next#88: Merge cp/x: x", row.items[0])

    def test_a_merge_bringing_named_upstream_pins_counts_one_named_pin(self):
        self.commit("base", 0)
        self.branch("feat-cmux-next")
        self.pin(1, "ghostty-next: bump (ghostty-next#40)")
        self.pin(2, "ghostty-next: bump again (ghostty-next#41)")
        self.branch("main", "main")
        self.merge("feat-cmux-next", "Merge origin/feat-cmux-next into perf/chrome-parity")
        row = RDC.pin_lane_row(self.root, 72)
        self.assertEqual((row.count, row.status), (1, "DONE"), row.items)  # one new gitlink value, one pin
        self.assertIn("ghostty-next#41, ghostty-next#40", row.items[0])

    def test_a_merge_bringing_an_unnamed_pin_is_open(self):
        self.commit("base", 0)
        self.pin(1, "ghostty-next: bump (ghostty-next#10)")  # on main: not brought by the later merge
        self.branch("cp/y")
        self.pin(2, "ghostty-next: bump to 723c4ab93e7")
        self.branch("main", "main")
        self.commit("unrelated on main", 1)
        self.merge("cp/y", "Merge cp/y: y")
        row = RDC.pin_lane_row(self.root, 72)
        self.assertEqual((row.count, row.status), (2, "OPEN"), row.items)
        self.assertIn("names no ghostty-next PR: Merge cp/y: y", row.items[0])
        self.assertIn("1 naming no ghostty-next PR", row.note)

    def test_the_same_gitlink_value_again_is_one_pin(self):
        self.pin(1, "ghostty-next: bump (ghostty-next#1)", 0)
        self.pin(2, "ghostty-next: bump (ghostty-next#2)")
        self.pin(1, "ghostty-next: back to #1's pin (ghostty-next#3)")
        row = RDC.pin_lane_row(self.root, 72)
        self.assertEqual((row.count, row.status), (2, "DONE"), row.items)
        self.assertIn("ghostty-next#3, ghostty-next#1", row.items[0])

    def test_three_named_pins_in_the_window_are_done(self):
        self.pin(1, "ghostty-next: bump (ghostty-next#40)", 0)
        self.pin(2, "ghostty-next: bump to 1111 (manaflow-ai/ghostty-next#88, ghostty-next#89)", 100)  # window starts
        self.pin(3, "ghostty-next: bump (ghostty-next#82)", 10)
        self.commit("unrelated", 5)
        self.pin(4, "ghostty-next: bump\n\nLands ghostty-next#80 and ghostty-next#84.", 20)
        row = RDC.pin_lane_row(self.root, 72)
        self.assertEqual((row.count, row.status), (3, "DONE"))
        self.assertTrue(row.items[0].endswith("ghostty-next#80, ghostty-next#84: ghostty-next: bump"), row.items)
        self.assertIn("ghostty-next#88, ghostty-next#89", row.items[2])

    def test_a_fourth_pin_or_an_unnamed_pin_is_open(self):
        for n in range(1, 5):
            self.pin(n, f"bump (ghostty-next#{n})")
        self.assertEqual((RDC.pin_lane_row(self.root, 72).count, RDC.pin_lane_row(self.root, 72).status),
                         (4, "OPEN"))
        self.assertEqual(RDC.pin_lane_row(self.root, 2).status, "DONE")  # the window is HEAD's time, not the clock
        self.pin(9, "ghostty-next: bump to 723c4ab93e7", 100)
        row = RDC.pin_lane_row(self.root, 72)
        self.assertEqual((row.count, row.status), (1, "OPEN"))
        self.assertIn("1 naming no ghostty-next PR", row.note)
        self.assertIn("names no ghostty-next PR", row.items[0])

    def test_not_a_repo_counts_nothing(self):
        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(RDC.pin_lane_row(Path(empty), 72).count, 0)


MOTION_MAIN_WORK = ROOT / "scripts/cmux-next/motion-main-work.py"
COUNTERS = ("frame_sets", "layouts", "window_calls", "tracking_area_adds", "contents_sets", "damage_rects")


def motion_pass(scenario, phase="do", round_index=0, after=None, frame1=None, noisy=False, visibility=1, error=None,
                session="light"):
    """One record in the shape motion-main-work.py's counting_pass and split_pass write (schema v2)."""
    after = {k: 0 for k in COUNTERS} | (after or {})
    frame1 = {k: 0 for k in COUNTERS} | {"frame_sets": 4, "layouts": 3} | (frame1 or {})
    return {"session": session, "scenario": scenario, "phase": phase, "round": round_index, "error": error,
            "counts": {"noisy": noisy,
                       "idle": {"frames": 24, "structural_max": 1 if noisy else 0, **{k: 0 for k in COUNTERS}},
                       "frame1": {"offset": 0, **frame1},
                       "frames_2_n": {"frames": 30, **after},
                       "frames_2_n_max": {k: min(v, 1) for k, v in after.items()},
                       "frames_2_n_with_work": sum(1 for v in after.values() if v), "last_work_frame": None},
            "layout_counters": {"layout_root_passes": 2}, "update_visibility": visibility,
            "owners": [{"owner": "PaneHostView", "frame_sets": 4, "layouts": 3}]}


def motion_report(passes):
    """The report around the passes; summary rows carry frame_sets/layouts/update_visibility maxima too, which the
    reader must not judge (they include every pass)."""
    return {"schema": "motion-main-work/v2", "environment": {}, "launches": {}, "sessions": {}, "passes": passes,
            "summary": [{"session": "light", "scenario": "cmd-d", "phase": "do", "frame_sets": {"median": 9, "max": 9},
                         "update_visibility": {"median": 9, "max": 9}, "zero_frames_2_n": True}],
            "problems": []}


def cef_summary(on_switch, on_tabs, off_longest=40.0, show_again=True):
    """cef-layer-ab.py's summary.json: both modes, validity rows from cef-layer-verify.py."""
    def switch(commit_p95, longest_max):
        return {"exit": 0, "rows": {f"chromium.{how}": {"input_to_commit_ms": {"n": 20, "p50": 4.0, "p95": commit_p95},
                                                         "input_to_idle_ms": {"n": 20, "p95": 30.0},
                                                         "longest_frame_ms": {"n": 20, "max": longest_max}}
                                    for how in ("click", "cmd_digit")}}

    def tabs(e2e_p95):
        line = {"n": 20, "commit": {"p50": 2.0, "p95": 3.0},
                "e2e": {"p50": 4.0, "p90": 6.0, "p95": e2e_p95, "max": 9.0}}
        part = {"table": {"chromium": line}, "switches": [], "stalls": {"count": 0, "max_ms": None}, "timed": 20}
        return {"exit": 0, "rows": {"tag": "t", "baseline": {}, "scenarios": [
            {"kind": "chromium", "count": 2, "ctrl_tab": part, "cmd_shift_bracket": part}]}}

    verify = lambda ok: {"ok": True, "exit": 0, "rows": [{"check": "valid", "ok": True, "observed": {}},  # noqa: E731
                                                         {"check": "show.again", "ok": ok, "observed": {"shown": ok}}]}
    return {"tag": "t", "app": "a",
            "modes": {"off": {"switch": switch(30.0, off_longest), "tabs": tabs(25.0)},
                      "on": {"switch": switch(*on_switch), "tabs": tabs(on_tabs)}},
            "validity": {"off": verify(True), "on": verify(show_again)}}


class BenchJson(FixtureTree):
    def bench(self, name, data):
        path = self.root / f"{name}.json"
        path.write_text(json.dumps(data))
        return str(path)

    def motion(self, passes):
        return {r.id: r for r in RDC.bench_rows("motion", self.bench("motion", motion_report(passes)))}

    def test_motion_judges_frames_2_n_of_quiet_counted_passes_only(self):
        rows = self.motion([
            motion_pass("cmd-d"), motion_pass("cmd-d", "undo"),
            # A noisy pass and a failed step count nowhere, as in motion-main-work.py's zero_frames_2_n.
            motion_pass("cmd-d", round_index=1, after={"frame_sets": 5}, noisy=True),
            motion_pass("cmd-d", round_index=2, after={"layouts": 5}, error="the pane did not close"),
        ])
        for row_id in ("DC2 passes", "DC2 frames_2_n.frame_sets", "DC2 frames_2_n.layouts",
                       "DC13 frames_2_n.window_calls", "DC2 update_visibility"):
            self.assertEqual(rows[row_id].status, "PASS", (row_id, rows[row_id]))
        self.assertIn("(of 2)", rows["DC2 frames_2_n.frame_sets"].threshold)  # frame 1's work is the step's own
        self.assertEqual(rows["DC2 MotionClock layout frames"].status, "SKIP")

    def test_motion_fails_on_frames_2_n_work_visibility_and_a_scenario_without_evidence(self):
        rows = self.motion([
            motion_pass("cmd-w", after={"frame_sets": 3, "window_calls": 2}, visibility=4),
            motion_pass("zoom", visibility=None),  # a build before p03-rendering-002
            motion_pass("band", noisy=True), motion_pass("band", round_index=1, error="prepare: no band"),
        ])
        self.assertEqual(rows["DC2 frames_2_n.frame_sets"].items, ["light cmd-w do #0 = 3"])
        self.assertEqual(rows["DC13 frames_2_n.window_calls"].items, ["light cmd-w do #0 = 2"])
        self.assertEqual(rows["DC2 frames_2_n.layouts"].status, "PASS")
        self.assertEqual(rows["DC2 update_visibility"].items, ["light cmd-w do #0 = 4", "light zoom do #0: no value"])
        self.assertEqual(rows["DC2 passes"].status, "FAIL")
        self.assertEqual(rows["DC2 passes"].items,
                         ["light band do: no quiet counted pass of 2 (1 noisy; prepare: no band)"])

    def test_motion_without_a_quiet_pass_or_its_schema_fails(self):
        rows = self.motion([motion_pass("cmd-d", noisy=True)])
        self.assertEqual({k: v.status for k, v in rows.items() if v.status != "SKIP"},
                         {k: "FAIL" for k in ("DC2 passes", "DC2 frames_2_n.frame_sets", "DC2 frames_2_n.layouts",
                                              "DC13 frames_2_n.window_calls", "DC2 update_visibility")})
        rows = RDC.bench_rows("motion", self.bench("flat", {"scenarios": {"cmd-d": {"frame_sets": 0, "layouts": 0}}}))
        self.assertEqual([r.status for r in rows], ["FAIL"])
        self.assertIn("not a motion-main-work.py report", rows[0].note)

    @unittest.skipUnless(MOTION_MAIN_WORK.exists(), "motion-main-work.py is not in this checkout")
    def test_motion_reads_motion_main_work_split_pass_output(self):
        spec = importlib.util.spec_from_file_location("motion_main_work", MOTION_MAIN_WORK)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # 3 idle frames, the step's frame (mark 3) with work, then frames 2..n: quiet, then one late layout.
        quiet = {k: [0, 0, 0, 2, 0, 0] for k in module.ALL_COUNTERS}
        late = {k: [0, 0, 0, 2, 0, 1 if k == "layouts" else 0] for k in module.ALL_COUNTERS}
        passes = [{"session": "light", "scenario": name, "phase": "do", "round": 0, "error": None,
                   "counts": module.split_pass(series, 3, 3), "layout_counters": {}, "update_visibility": 2,
                   "owners": []} for name, series in (("cmd-d", quiet), ("cmd-w", late))]
        report = {"schema": module.SCHEMA, "passes": passes, "summary": module.summarize(passes), "problems": []}
        rows = {r.id: r for r in RDC.bench_rows("motion", self.bench("real", report))}
        self.assertEqual(rows["DC2 frames_2_n.frame_sets"].status, "PASS")
        self.assertEqual(rows["DC2 frames_2_n.layouts"].items, ["light cmd-w do #0 = 1"])
        self.assertEqual(rows["DC2 passes"].status, "PASS")

    def test_every_criterion_without_a_value_fails(self):
        rows = RDC.bench_rows("hitches", self.bench("wrong", {"switches": 3}))
        self.assertEqual([r.status for r in rows], ["FAIL", "FAIL", "FAIL"])
        self.assertIn("not a --hitches report", rows[0].note)
        # A partial report: the criteria it has pass, the one it lacks still fails.
        rows = {r.id: r for r in RDC.bench_rows("hitches", self.bench("partial", {"scenarios": [
            {"name": "cmd-d", "hitch_count": 0, "max_interval_ms": 8.4}]}))}
        self.assertEqual(rows["DC3 hitches|hitch_count"].status, "PASS")
        self.assertEqual(rows["DC3 max_interval_ms"].status, "PASS")
        self.assertEqual(rows["DC2t main_work_p99_ms"].status, "FAIL")

    def test_typing_reads_distributions_and_a_run_without_one_fails(self):
        typing = self.bench("typing", {"runs": [{"key_to_frame_ms": {"p50": 6.1, "p99": 15.0}},
                                                {"key_to_frame_ms": {"p50": 9.0, "p99": 20.0}},
                                                {"key_to_frame_ms": None}]})
        rows = {r.id: r for r in RDC.bench_rows("typing", typing)}
        self.assertEqual(rows["DC5 key_to_frame_ms.p50"].items,
                         ["runs[1].key_to_frame_ms = 9", "runs[2].key_to_frame_ms: no value"])
        self.assertEqual(rows["DC5 key_to_frame_ms.p99"].count, 2)

    def test_cef_judges_the_on_mode_only(self):
        # The off baseline (child windows) misses DC10 by far; a good hosted run still passes.
        rows = {r.id: r for r in RDC.bench_rows("cef", self.bench("cef", cef_summary((5.0, 8.0), 6.0)))}
        for row_id in ("DC10 show.again", "DC10 switch input_to_commit_ms.p95", "DC10 switch longest_frame_ms.max",
                       "DC10 tabs e2e.p95"):
            self.assertEqual(rows[row_id].status, "PASS", (row_id, rows[row_id]))
        self.assertIn("(of 2)", rows["DC10 switch longest_frame_ms.max"].threshold)
        self.assertIn("(of 2)", rows["DC10 tabs e2e.p95"].threshold)
        self.assertEqual(rows["DC10 viewDidMoveToWindow"].status, "SKIP")

    def test_cef_fails_on_limits_show_again_and_a_missing_bench(self):
        rows = {r.id: r for r in RDC.bench_rows("cef", self.bench("cef", cef_summary((8.3, 9.0), 8.3,
                                                                                      show_again=False)))}
        self.assertEqual(rows["DC10 switch input_to_commit_ms.p95"].count, 2)  # strict < 8.3
        self.assertEqual(rows["DC10 switch longest_frame_ms.max"].count, 2)
        self.assertEqual(rows["DC10 tabs e2e.p95"].items, ["tabs chromium 2 ctrl_tab = 8.3",
                                                           "tabs chromium 2 cmd_shift_bracket = 8.3"])
        self.assertEqual(rows["DC10 show.again"].status, "FAIL")
        summary = cef_summary((5.0, 8.0), 6.0)
        summary["modes"]["on"]["tabs"] = {"exit": 1, "rows": {"error": "no report"}}
        del summary["modes"]["on"]["switch"]["rows"]["chromium.click"]["input_to_commit_ms"]
        rows = {r.id: r for r in RDC.bench_rows("cef", self.bench("cef", summary))}
        self.assertEqual(rows["DC10 tabs e2e.p95"].status, "FAIL")
        self.assertIn("no modes.on.tabs scenarios", rows["DC10 tabs e2e.p95"].note)
        self.assertEqual(rows["DC10 switch input_to_commit_ms.p95"].items, ["switch chromium.click: no value"])
        del summary["modes"]["on"]
        self.assertEqual([r.status for r in RDC.bench_rows("cef", self.bench("cef", summary))], ["FAIL"])

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

    def test_idle_fails_an_app_or_daemon_that_came_or_went_in_the_window(self):
        # bench_idle.py writes a partial row (no rate) for such a process, and its own criteria fail it.
        path = self.bench("idle", {"scenarios": {"terminals": {"processes": [
            {"kind": "app", "wakeups_per_s": 0.2},
            {"pid": 41, "kind": "daemon", "partial": True, "note": "exited during the window"},
            {"pid": 42, "kind": "terminal-host", "partial": True, "note": "appeared during the window"}]}}})
        row = {r.id: r for r in RDC.bench_rows("idle", path)}["DC7j app+daemon"]
        self.assertEqual((row.status, row.items), ("FAIL", ["terminals: daemon 41 exited during the window"]))

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
        self.assertEqual({r["id"] for r in rows} - {"GHOSTTY", "GHOSTTY-kit", "LANE-ghostty-pins"},
                         {c.id for c in RDC.CHECKS})
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
