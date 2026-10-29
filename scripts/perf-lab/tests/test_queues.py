#!/usr/bin/env python3
"""queues.py: the perf program's machine queues, on fixture trees and on this checkout.

Run: python3 -m unittest scripts/perf-lab/tests/test_queues.py
"""

import contextlib
import importlib.util
import io
import os
import shutil
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(LAB))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


queues = _load("perf_lab_queues_under_test", os.path.join(LAB, "queues.py"))


class Fixture(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="queues-")
        self.addCleanup(shutil.rmtree, self.root)

    def write(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(textwrap.dedent(text).lstrip("\n"))

    def keys(self, run):
        with contextlib.redirect_stderr(io.StringIO()):
            return [item.key for item in run(self.root)]


class PrivateStats(Fixture):
    """MQ1."""

    def test_every_stat_form_in_every_perf_directory(self):
        self.write("scripts/cmux-next/def-bench.py", "def pct(values, q):\n    return 0\n")
        self.write("scripts/cmux-next/median-bench.py", "def _median(values):\n    return 0\n")
        self.write("scripts/cmux-next/stats-bench.py", "def stats(values):\n    return {}\n")
        self.write("scripts/cmux-next/lambda-bench.py", "p95 = lambda values: sorted(values)[0]\n")
        self.write("cmux-tui/scripts/q-bench.py", "q = lambda p: s[min(len(s) - 1, int(p * len(s)))]\n")
        self.write("scripts/cmux-next/inline-bench.py", "p95 = ordered[int(len(ordered) * 0.95)]\n")
        self.write("scripts/cmux-next/inline-front.py", "p90 = ordered[int(0.9 * (len(ordered) - 1))]\n")
        self.write("scripts/cmux-next/inline-round.py", "p = v[round(0.95 * (len(v) - 1))]\n")
        self.write("webviews/scripts/x/rank.py", "k = (len(vals) - 1) * q\n")
        self.write("scripts/measure/quantiles.py", "import statistics\ncuts = statistics.quantiles(v, n=100)\n")
        self.write("tests/automation-bench/perf/bench.py", "def percentile(values, p):\n    return 0\n")
        self.assertEqual(self.keys(queues.private_stats), [
            "cmux-tui/scripts/q-bench.py",
            "scripts/cmux-next/def-bench.py",
            "scripts/cmux-next/inline-bench.py",
            "scripts/cmux-next/inline-front.py",
            "scripts/cmux-next/inline-round.py",
            "scripts/cmux-next/lambda-bench.py",
            "scripts/cmux-next/median-bench.py",
            "scripts/cmux-next/stats-bench.py",
            "scripts/measure/quantiles.py",
            "tests/automation-bench/perf/bench.py",
            "webviews/scripts/x/rank.py",
        ])

    def test_shared_home_allowlist_retired_tests_and_comments_stay_out(self):
        self.write("scripts/perf-lab/perf_stats.py", "def pct(values, q):\n    return 0\n")
        self.write("scripts/cmux-next/perf-budgets.py", "def pct(values, q):\n    return 0\n")
        self.write("scripts/cmux-next/perf-cron.py", "def _median(values):\n    return 0\n")
        self.write("scripts/ci/ci_health_report.py", "def percentile(sorted_values, pct):\n    return 0\n")
        self.write("scripts/cmux-next/tests/test_x.py", "def pct(values):\n    return 0\n")
        self.write("scripts/cmux-next/commented.py", "# def pct(values):\n")
        self.write("scripts/cmux-next/wait-live.py", "two = wait(lambda: [s for s in strips() if len(s) >= 2], 15)\n")
        self.write("scripts/cmux-next/other.py", "def summarize_rows(values):\n    return 0\n")
        self.write("scripts/perf-lab/alerts.py",
                   "def _stats(samples, unit):\n    summary = perf_stats.summary(samples)\n    return str(summary)\n")
        self.write("scripts/cmux-next/one-line-bench.py", "def pct(v, p): return perf_stats.pct(v, p)\nx = 1\n")
        self.assertEqual(self.keys(queues.private_stats), [])

    def test_one_item_per_file_with_its_first_line(self):
        self.write("scripts/cmux-next/two-bench.py", "x = 1\ndef pct(v):\n    pass\ndef median(v):\n    pass\n")
        with contextlib.redirect_stderr(io.StringIO()):
            (item,) = queues.private_stats(self.root)
        self.assertEqual(item.where, "scripts/cmux-next/two-bench.py:2")
        self.assertIn("(+1 more)", item.detail)

    def test_a_stale_keep_entry_warns(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            queues.private_stats(self.root)
        self.assertIn("perf-budgets.py", stderr.getvalue())


class SelfLaunch(Fixture):
    """MQ2."""

    def test_perf_named_self_launchers_without_bench_launch(self):
        self.write("scripts/cmux-next/perf-gate.py", "class App:\n    def launch(self):\n        pass\n")
        self.write("scripts/cmux-next/cmd-n-paint-e2e.py", 'b = glob("Contents/MacOS/*")\n')
        self.write("scripts/cmux-next/storm-bench.py", 'subprocess.run(["open", "-n", app])\n')
        self.write("scripts/cmux-next/shared-bench.py", "from bench_launch import BenchApp\nb = 'Contents/MacOS'\n")
        self.write("scripts/cmux-next/sidebar-live.py", 'b = "Contents/MacOS"\n')  # not a perf name
        self.write("scripts/cmux-next/perf-cron.py", "def launch():\n    pass\n")
        self.write("scripts/cmux-next/launch-env-fence-live.py", "def launch():\n    pass\n")
        self.write("scripts/cmux-next/note-bench.py", "# Contents/MacOS in a comment\n")
        self.write("scripts/cmux-next/sub/deep-bench.py", 'b = "Contents/MacOS"\n')
        items = queues.self_launch(self.root)
        self.assertEqual([item.key for item in items], [
            "scripts/cmux-next/cmd-n-paint-e2e.py",
            "scripts/cmux-next/perf-gate.py",
            "scripts/cmux-next/storm-bench.py",
        ])
        self.assertEqual(items[1].where, "scripts/cmux-next/perf-gate.py:2")


class P95WithoutP99(Fixture):
    """MQ3."""

    def test_files_that_report_p95_and_never_p99(self):
        self.write("scripts/cmux-next/only-p95.py", "x = 1\nrow['p95'] = 2\n")
        self.write("scripts/cmux-next/both.py", "row['p95'] = 1\nrow['p99'] = 2\n")
        self.write("scripts/cmux-next/neither.py", "row['p50'] = 1\n")
        self.write("scripts/cmux-next/guardrails.py", "p95\n")
        self.write("scripts/cmux-next/tests/test_only_p95.py", "p95\n")
        items = queues.p95_without_p99(self.root)
        self.assertEqual([(item.key, item.where) for item in items],
                         [("scripts/cmux-next/only-p95.py", "scripts/cmux-next/only-p95.py:2")])


class BenchMigration(Fixture):
    """MQ-B."""

    def test_union_by_file_names_each_queue(self):
        self.write("scripts/cmux-next/a-bench.py", "def pct(v):\n    pass\nrow = {'p95': 1}\n")
        self.write("scripts/cmux-next/b-perf.py", "class X:\n    def launch(self):\n        pass\n")
        self.write("scripts/cmux-next/c.py", "p95\n")
        with contextlib.redirect_stderr(io.StringIO()):
            items = queues.bench_migration(self.root)
        self.assertEqual([(item.key, item.detail) for item in items], [
            ("scripts/cmux-next/a-bench.py", "MQ1,MQ3"),
            ("scripts/cmux-next/b-perf.py", "MQ2"),
            ("scripts/cmux-next/c.py", "MQ3"),
        ])


class Signposts(Fixture):
    """MQ5."""

    def test_cases_without_an_emitter(self):
        self.write(queues.SIGNPOST_NAME, """
            public enum SignpostName: UInt16 {
                /// `signposter.begin(.direct)` in a doc comment is not an emit.
                case direct = 1
                case wrapped = 2
                case staticName = 3
                case documented = 4
                case switched = 5
                case qualified = 6
                case bound = 7
                case ring = 8
                case timer = 9
                case timerShort = 10
            }
            """)
        self.write("Packages/macOS/CmuxNext/Sources/A/Emit.swift", """
            let state = Signposter.action.begin(.direct, "id=x")
            signposter.end(
                .wrapped, interval)
            signposter.emitEvent(SignpostName.staticName.staticName, "")
            /// signposter.begin(.documented)
            Signposter.stall.begin(SignpostName.qualified, taskClass: "a", owner: "b")
            let name: SignpostName = .bound
            trace.asyncBegin(.ring, id: 1)
            static let timer = SwitchFrameTimer(owner: "debug.x", signpost: SignpostName.timer)
            let short = SwitchFrameTimer(owner: "y", signpost: .timerShort, trace: runtime)
            switch name {
            case .switched: break
            }
            """)
        self.assertEqual(self.keys(queues.unemitted_signposts), ["documented", "switched"])

    def test_calls_on_other_receivers_are_not_emits(self):
        self.write(queues.SIGNPOST_NAME, """
            public enum SignpostName: UInt16 {
                case cefPump = 1
                case inputFrame = 2
                case direct = 3
                case wrapped = 4
                case stalled = 5
                case viaRuntime = 6
            }
            """)
        self.write("Packages/macOS/CmuxNext/Sources/A/Other.swift", """
            metrics.counter(.cefPump, 1)
            histograms?.event(.inputFrame, value: 2)
            inlineRename.begin(.direct)
            source?.end(.wrapped)
            Signposter.stall.event(.stalled, "x")
            self.runtime.begin(.viaRuntime)
            """)
        self.assertEqual(self.keys(queues.unemitted_signposts), ["cefPump", "inputFrame", "direct", "wrapped"])

    def test_a_missing_catalog_is_an_error(self):
        with self.assertRaises(queues.QueueError):
            queues.unemitted_signposts(self.root)


class Features(Fixture):
    """MQ6, through gen-features.py --unmigrated."""

    def test_seed_tunables_and_env_switch(self):
        os.makedirs(os.path.join(self.root, "schemas/features"))
        shutil.copy(os.path.join(REPO, "schemas/features/features.schema.json"),
                    os.path.join(self.root, "schemas/features/features.schema.json"))
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Tunables.swift", """
            enum LayoutTunables {
                public static let layerHosting = Tunable<Bool>.toggle(
                    "browserResize.layerHosting", .springs, "Host", default: false)
                public static let other = Tunable<Bool>.toggle("unrelated.key", .springs, "Other", default: false)
            }
            """)
        self.write("cmux-tui/crates/core/src/holder.rs", 'let m = std::env::var("CMUX_TUI_TERMINAL_HOST_MODEL");\n')
        self.assertEqual(self.keys(queues.unmigrated_features), ["CMUX_TUI_TERMINAL_HOST_MODEL", "browserResize.layerHosting"])


class BenchGaps(Fixture):
    """MQ13."""

    def test_compiled_lines_follow_the_bench_defines(self):
        text = textwrap.dedent("""
            a
            #if DEBUG
            b
            #elseif CMUX_BENCH_HOOKS && os(macOS)
            c
            #if !(DEBUG || CMUX_BENCH_HOOKS)
            d
            #else
            e
            #endif
            #else
            f
            #endif
            #if canImport(AppKit) // a trailing comment
            g
            #endif
            #if os(iOS)
            h
            #endif
            """).strip()
        compiled = queues.compiled_lines(text)
        self.assertEqual([line for line, on in zip(text.splitlines(), compiled) if on], ["a", "c", "e", "g"])

    def test_blocking_checks_is_not_a_bench_define(self):
        # reload.sh --config bench passes -DCMUX_BENCH_HOOKS only; bench-checks adds CMUX_BLOCKING_CHECKS.
        self.assertEqual(queues.compiled_lines("#if DEBUG || CMUX_BLOCKING_CHECKS\nx\n#endif"), [False, False, False])

    def test_an_unreadable_condition_is_an_error(self):
        with self.assertRaises(queues.QueueError):
            queues.compiled_lines("#if DEBUG +\n#endif\n")

    def test_debug_only_names_a_bench_uses(self):
        self.write("Packages/macOS/CmuxNext/Sources/App/Debug.swift", """
            #if DEBUG
            router.register([.mainActor("debug.only") { _ in .null }])
            let extra = env["CMUX_NEXT_DEBUG_ONLY"]
            #else
            let extra = ""
            #endif
            #if DEBUG || CMUX_BENCH_HOOKS
            router.register([.mainActor("debug.bench") { _ in .null }])
            #endif
            #if DEBUG || CMUX_BLOCKING_CHECKS
            router.register([.mainActor("debug.blocking_only") { _ in .null }])
            let fence = env["CMUX_NEXT_FENCE_ONLY"]
            #endif
            #if DEBUG
            let both = env["CMUX_NEXT_BOTH"]
            #else
            let both = env["CMUX_NEXT_BOTH"]
            #endif
            // "debug.commented" in a comment
            """)
        self.write("Packages/macOS/CmuxNext/Tests/AppTests/T.swift", '#if DEBUG\nx("debug.test_only")\n#endif\n')
        self.write("scripts/cmux-next/a-bench.py", """
            rpc("debug.only")
            rpc("debug.bench")
            rpc("debug.unknown")
            rpc("debug.test_only")
            rpc("debug.blocking_only")
            env = {"CMUX_NEXT_DEBUG_ONLY": "1", "CMUX_NEXT_BOTH": "1"}
            """)
        self.write("scripts/cmux-next/sidebar-live.py", 'rpc("debug.commented")\n')  # not a bench
        # A functional launch check (NOT_A_BENCH, the same set MQ2 skips) is not a bench script.
        self.write("scripts/cmux-next/launch-env-fence-live.py", 'env = {"CMUX_NEXT_FENCE_ONLY": "1"}\n')
        items = queues.bench_gaps(self.root)
        self.assertEqual([item.key for item in items], ["debug.blocking_only", "debug.only", "CMUX_NEXT_DEBUG_ONLY"])
        self.assertEqual(items[1].where, "Packages/macOS/CmuxNext/Sources/App/Debug.swift:2")
        self.assertIn("scripts/cmux-next/a-bench.py", items[1].detail)

    def test_a_debug_only_use_by_design_is_not_a_gap_for_that_script_only(self):
        self.write("Packages/macOS/CmuxNext/Sources/Browser/CEFSwitches.swift", """
            #if DEBUG
            let extra = env["CMUX_NEXT_CEF_EXTRA_SWITCHES"]
            let other = env["CMUX_NEXT_OTHER_SWITCHES"]
            #endif
            #if DEBUG || CMUX_BENCH_HOOKS
            let bench = env["CMUX_NEXT_BENCH_CEF_SWITCHES"]
            #endif
            """)
        self.write("scripts/cmux-next/bench_memory.py", """
            env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": "a", "CMUX_NEXT_OTHER_SWITCHES": "b", "CMUX_NEXT_BENCH_CEF_SWITCHES": "c"}
            """)
        self.assertIn(("CMUX_NEXT_CEF_EXTRA_SWITCHES", "scripts/cmux-next/bench_memory.py"), queues.DEBUG_ONLY_BY_DESIGN)
        self.assertEqual([item.key for item in queues.bench_gaps(self.root)], ["CMUX_NEXT_OTHER_SWITCHES"])
        # A script whose measurement needs the name (trace.py's remote-debugging-port) is still a gap.
        self.write("scripts/cmux-next/trace.py", """
            env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": "remote-debugging-port=9222"}
            BenchApp(path, env=env)
            """)
        items = queues.bench_gaps(self.root)
        self.assertEqual([item.key for item in items], ["CMUX_NEXT_CEF_EXTRA_SWITCHES", "CMUX_NEXT_OTHER_SWITCHES"])
        self.assertIn("scripts/cmux-next/trace.py", items[0].detail)

    def test_the_queue_source_is_not_a_bench_script(self):
        self.write("Packages/macOS/CmuxNext/Sources/Browser/CEFSwitches.swift", """
            #if DEBUG
            let extra = env["CMUX_NEXT_CEF_EXTRA_SWITCHES"]
            #endif
            """)
        self.write(queues.QUEUES_SOURCE, """
            USES = re.compile(r"BenchApp")
            NAMES = {("CMUX_NEXT_CEF_EXTRA_SWITCHES", "x.py"): "why"}
            """)
        self.assertEqual(queues.bench_gaps(self.root), [])

class CommandLine(Fixture):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = queues.main(list(argv) + ["--root", self.root])
        return code, out.getvalue(), err.getvalue()

    def test_all_counts_has_one_line_per_queue(self):
        self.write("scripts/cmux-next/a-bench.py", "def pct(v):\n    pass\n")
        self.write(queues.SIGNPOST_NAME, "enum SignpostName {\n    case a = 1\n}\n")
        self.write("schemas/features/features.schema.json", "{}")
        self.write("run/typecheck-queue.json", '{"tasks": [{"file": "A.swift", "max_ms": 120, "functions": '
                   '[{"line": 3, "column": 6, "subject": "f()", "declaration": "global function", "ms": 120}]}]}')
        code, out, _ = self.run_main("--all", "--counts", "--dir", os.path.join(self.root, "run"))
        rows = [line.split("\t") for line in out.splitlines()]
        self.assertEqual([row[0] for row in rows], [queue.mq for queue in queues.QUEUES])
        self.assertEqual(dict((row[0], row[2]) for row in rows)["MQ1"], "1")
        self.assertEqual(dict((row[0], row[2]) for row in rows)["MQ5"], "1")
        self.assertEqual(dict((row[0], row[2]) for row in rows)["MQ15"], "1")
        self.assertEqual(code, 0)

    def test_mq15_without_a_store_is_an_error_not_an_empty_queue(self):
        with mock.patch.dict(os.environ):
            os.environ.pop(queues.DB_ENV, None)
            code, out, err = self.run_main("mq15", "--counts")
        self.assertEqual((code, out), (1, "MQ15\ttypecheck\terror\n"))
        self.assertIn("no lab store", err)

    def test_a_queue_that_cannot_run_reports_error_and_exits_1(self):
        code, out, err = self.run_main("signposts", "--counts")
        self.assertEqual(code, 1)
        self.assertIn("error", out)
        self.assertIn("SignpostName.swift is missing", err)

    def test_files_prints_only_keys(self):
        self.write("scripts/cmux-next/a-bench.py", "def pct(v):\n    pass\n")
        code, out, _ = self.run_main("bench-migration", "--files")
        self.assertEqual((code, out), (0, "scripts/cmux-next/a-bench.py\n"))

    def test_all_files_prints_only_keys(self):
        self.write("scripts/cmux-next/a-bench.py", "def pct(v):\n    pass\n")
        self.write(queues.SIGNPOST_NAME, "enum SignpostName {\n    case a = 1\n}\n")
        self.write("schemas/features/features.schema.json", "{}")
        _, out, _ = self.run_main("--all", "--files")
        self.assertNotIn("==", out)
        self.assertEqual(sorted(set(out.splitlines())), ["a", "scripts/cmux-next/a-bench.py"])

    def test_queue_names_and_ids(self):
        for name in ("mq1", "MQ-B", "mqb", "bench-gaps", "MQ13"):
            self.assertIn(queues.find(name), queues.QUEUES)
        with self.assertRaises(queues.QueueError):
            queues.find("mq99")


@unittest.skipUnless(os.path.isfile(os.path.join(REPO, queues.SIGNPOST_NAME)), "not a cmux checkout")
class Checkout(unittest.TestCase):
    """The plan's acceptance on this checkout (p12-perf-process.md section 7, task 200)."""

    RESERVED = ("motionFrame", "motionRun", "switchWorkspace", "switchTab", "switchPaneFocus", "createTab",
                "createWorkspace", "cefPump", "cefCreateBrowser")
    EMITTED = ("actionPerform", "actionCommit", "actionGate", "keyToFrame", "keyFlow", "scrollToFrame",
               "stallMainTask", "stallOverBudget")

    def test_mq5_lists_the_reserved_cases_and_not_the_emitted(self):
        listed = {item.key for item in queues.unemitted_signposts(REPO)}
        for case in self.RESERVED:
            if case in queues.signpost_cases(REPO) and self._still_reserved(case):
                self.assertIn(case, listed)
        for case in self.EMITTED:
            self.assertNotIn(case, listed)

    def _still_reserved(self, case):
        """An emitter task (080-083) landing takes its case off the queue; the test follows the catalog's doc."""
        with open(os.path.join(REPO, queues.SIGNPOST_NAME)) as handle:
            text = handle.read()
        declaration = text.index("case %s " % case)
        return "Reserved" in text[text.rfind("case ", 0, declaration):declaration]

    def test_mq2_includes_the_known_self_launchers(self):
        listed = {item.key for item in queues.self_launch(REPO)}
        for name in ("perf-gate.py", "cmd-n-paint-e2e.py", "pane-zoom-terminal.py", "cli-storm-session.py"):
            path = "scripts/cmux-next/" + name
            with open(os.path.join(REPO, path)) as handle:
                if "BenchApp" in handle.read():
                    continue  # migrated (MQ-B)
            self.assertIn(path, listed)

    def test_mq3_returns_files(self):
        items = queues.p95_without_p99(REPO)
        self.assertTrue(items)
        for item in items:
            self.assertTrue(os.path.isfile(os.path.join(REPO, item.key)), item.key)

    def test_mq6_drops_the_motion_holds_that_became_features(self):
        """p12-perf-process-102: features paneHoldsContentInMotion and sidebarSlideHoldsContent replace them."""
        with contextlib.redirect_stderr(io.StringIO()):
            listed = {item.key for item in queues.unmigrated_features(REPO)}
        self.assertNotIn("motion.pane.holdContent", listed)
        self.assertNotIn("sidebar.slideHoldsContent", listed)

    def test_mq1_keeps_only_the_allowlist_out(self):
        with contextlib.redirect_stderr(io.StringIO()):
            listed = {item.key for item in queues.private_stats(REPO)}
        self.assertFalse(listed & set(queues.ALLOWLIST))
        self.assertFalse(listed & set(queues.RETIRED))
        self.assertNotIn("scripts/perf-lab/perf_stats.py", listed)


if __name__ == "__main__":
    unittest.main()
