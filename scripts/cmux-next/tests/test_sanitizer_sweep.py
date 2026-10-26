#!/usr/bin/env python3
"""sanitizer_sweep.py: fleet-only refusal, suppressions rules, closure enumeration, base-red pre-pass, counting."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
FIXTURES = HERE / "fixtures" / "signature"
spec = importlib.util.spec_from_file_location("sanitizer_sweep", SCRIPTS / "sanitizer_sweep.py")
ss = importlib.util.module_from_spec(spec)
sys.modules["sanitizer_sweep"] = ss
spec.loader.exec_module(ss)

FLEET = {"CMUX_CI_STEP_KEY": "step-1", "PATH": "/usr/bin:/bin"}
TOOLCHAIN = ss.Toolchain("/Applications/Xcode_26.6.app/Contents/Developer",
                         "/Applications/Xcode_26.6.app/Contents/Developer/Platforms/MacOSX.platform/SDKs/MacOSX.sdk")
TSAN = (FIXTURES / "tsan-race.txt").read_text()
ASAN = (FIXTURES / "asan-uaf.txt").read_text()
HANG = (FIXTURES / "hang-sample.txt").read_text()
# A strict-pool deadlock: the main thread idles in dispatch_main, the one cooperative worker waits on a semaphore.
POOL_STALL = (HERE / "fixtures" / "sanitizer-sweep" / "pool-stall-sample.txt").read_text()


def watchdog_sample(process: str, sample: str) -> str:
    """How hung_test_watchdog.py prints one process's `sample` report."""
    return f"::group::Stack sample of {process} (5150)\n{sample}::endgroup::\n"


def lane_text(package: str, targets: dict[str, tuple[str, str]]) -> str:
    """What package-test-lane.sh suite prints: one group per filter, then the results table."""
    lines = ["::group::swift build --build-tests -c debug " + package, "Build complete!", "::endgroup::"]
    for target, (_, body) in targets.items():
        lines += [f"::group::swift test --filter {target}", *body.splitlines(),
                  "::group::Stack sample of xctest (1)", "::endgroup::", "::endgroup::"]
    lines.append(f"Swift suite results ({package}):")
    lines.append(f"{'suite':<48} {'result':<18} {'time':>7}")
    for target, (result, _) in targets.items():
        lines.append(f"{target:<48} {result:<18} {3:>6}s")
    return "\n".join(lines) + "\n"


class FakeLane:
    """Scripted lane output per (mode, package): the mode is read from the environment, as the lane does."""

    def __init__(self, scripts: dict[tuple[str, str], tuple[int, str]]):
        self.scripts = scripts
        self.calls: list[tuple[str, str, dict]] = []

    def __call__(self, package, env, log: Path):
        mode = env.get("CMUX_SWIFT_SANITIZE") or ("coop-strict" if env.get("CMUX_SWIFT_TEST_COOP_STRICT") else "base")
        self.calls.append((mode, package.path, dict(env)))
        status, text = self.scripts.get((mode, package.path), (0, lane_text(package.path, {
            t: ("passed", "✔ Test passed.") for t in package.tests})))
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(text)
        results, output = ss.parse_lane_output(text)
        return ss.LaneRun(status, results, output, log)


MANIFESTS = {
    "Packages/macOS/CmuxNext": {
        "name": "CmuxNext",
        "targets": [{"name": "CmuxNextCore", "type": "regular"}, {"name": "CmuxNextAppTests", "type": "test"},
                    {"name": "CmuxNextDaemonTests", "type": "test"}],
        "dependencies": [{"fileSystem": [{"identity": "cmuxtheme", "path": "../../Shared/CmuxTheme"}]},
                         {"fileSystem": [{"identity": "cmuxupdater", "path": "{root}/Packages/macOS/CmuxUpdater"}]},
                         {"sourceControl": [{"identity": "sparkle", "location": {"remote": ["https://x"]}}]},
                         {"fileSystem": [{"identity": "outside", "path": "/elsewhere/Outside"}]}],
    },
    "Packages/Shared/CmuxTheme": {
        "name": "CmuxTheme", "targets": [{"name": "CmuxThemeTests", "type": "test"}],
        "dependencies": [{"fileSystem": [{"identity": "cmuxupdater", "path": "../../macOS/CmuxUpdater"}]}],
    },
    "Packages/macOS/CmuxUpdater": {"name": "CmuxUpdater", "targets": [{"name": "CmuxUpdater", "type": "regular"}],
                                   "dependencies": []},
}


def make_dump(root: Path):
    calls: list[str] = []

    def dump(toolchain, package_dir: Path, environ) -> dict:
        assert toolchain == TOOLCHAIN, toolchain
        relative = package_dir.relative_to(root).as_posix()
        calls.append(relative)
        text = json.dumps(MANIFESTS[relative]).replace("{root}", str(root))
        return json.loads(text)

    return dump, calls


class SweepCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for relative in MANIFESTS:
            (self.root / relative).mkdir(parents=True)
        self.dump, self.dumped = make_dump(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, argv, lane, environ=FLEET, system="Darwin"):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = ss.main(argv, environ=environ, system=system, resolve=lambda root, env: TOOLCHAIN,
                             dump=self.dump, run_lane=lane, names=lambda: [], root=self.root)
        return status, stdout.getvalue(), stderr.getvalue()

    def out(self, name="findings.jsonl"):
        path = self.root / ".build/sanitizer-sweep" / name
        return [json.loads(line) for line in path.read_text().splitlines()]


class RefusalTests(SweepCase):
    def test_refuses_outside_a_fleet_step(self):
        lane = FakeLane({})
        status, _, err = self.run_main(["--sanitize", "thread"], lane, environ={"PATH": "/bin"})
        self.assertEqual(status, 2)
        self.assertIn("cmux-ci run --class isolated", err)
        self.assertEqual(lane.calls, [])
        self.assertEqual(self.dumped, [])

    def test_refuses_a_linux_fleet_step(self):
        status, _, err = self.run_main(["--sanitize", "thread"], FakeLane({}), system="Linux")
        self.assertEqual(status, 2)
        self.assertIn("macOS", err)

    def test_shell_entry_refuses_outside_a_fleet_step(self):
        completed = subprocess.run(["bash", str(SCRIPTS / "sanitizer-sweep.sh"), "--sanitize", "thread"],
                                   env={"PATH": os.environ["PATH"]}, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn("fleet step", completed.stderr)

    def test_rejects_an_unknown_mode(self):
        with redirect_stderr(io.StringIO()):
            status, _, _ = self.run_main(["--sanitize", "thread,memory"], FakeLane({}))
        self.assertEqual(status, 2)


class SuppressionTests(unittest.TestCase):
    def test_checked_in_file_is_valid_and_small(self):
        suppressions = ss.check_suppressions(ss.SUPPRESSIONS.read_text())
        self.assertLessEqual(len(suppressions), ss.MAX_SUPPRESSIONS)

    def test_needs_a_third_party_reason_above_each_line(self):
        ss.check_suppressions("# third-party Sparkle 2.6: reads cached state off main\nrace:SPUUpdater\n", lambda: [])
        with self.assertRaisesRegex(ss.UsageError, "third-party"):
            ss.check_suppressions("race:SPUUpdater\n", lambda: [])
        with self.assertRaisesRegex(ss.UsageError, "third-party"):
            ss.check_suppressions("# Sparkle races\nrace:SPUUpdater\n", lambda: [])

    def test_refuses_cmux_code_and_unknown_types(self):
        with self.assertRaisesRegex(ss.UsageError, "cmux code"):
            ss.check_suppressions("# third-party x: y\nrace:CmuxNextTerminal\n", lambda: [])
        with self.assertRaisesRegex(ss.UsageError, "not a TSan suppression"):
            ss.check_suppressions("# third-party x: y\nleak:Foo\n")

    def test_refuses_more_than_ten(self):
        text = "".join(f"# third-party Lib{i}: benign\nrace:LibFoo{i}\n" for i in range(11))
        with self.assertRaisesRegex(ss.UsageError, "limit is 10"):
            ss.check_suppressions(text, lambda: [])

    def test_refuses_wildcards_and_patterns_too_short_to_name_a_library(self):
        # TSan matches a pattern anywhere in a function, file or module name: `race:*` hides every race.
        for pattern in ("*", "*Foo", "^*", "**", "ab", "a*b*c"):
            with self.subTest(pattern=pattern), self.assertRaises(ss.UsageError):
                ss.check_suppressions(f"# third-party x: y\nrace:{pattern}\n", lambda: [])

    def test_refuses_a_pattern_that_matches_a_declared_cmux_name_or_path(self):
        names = ["Packages/macOS/CmuxNext/Sources/Terminal/TerminalRegistry.swift", "TerminalRegistry"]
        for pattern in ("TerminalRegistry", "Registry", "TerminalRegistry.register", "^Terminal*"):
            with self.subTest(pattern=pattern), self.assertRaisesRegex(ss.UsageError, "matches cmux code"):
                ss.check_suppressions(f"# third-party Sparkle: y\nrace:{pattern}\n", lambda: names)
        self.assertEqual(ss.check_suppressions("# third-party Sparkle 2.6: z\nrace:Sparkle.framework\n",
                                               lambda: names), ["race:Sparkle.framework"])

    def test_repository_names_are_the_packages_declarations_and_paths(self):
        names = ss.repository_names(ss.ROOT)
        self.assertIn("AgentLaneStore", names)
        with self.assertRaisesRegex(ss.UsageError, "AgentLaneStore"):
            ss.check_suppressions("# third-party Sparkle: y\nrace:AgentLaneStore\n", lambda: names)
        # CmuxUpdater's SparkleSeam.swift declares `extension SPUUpdater`: `race:SPUUpdater` would hide cmux code too.
        with self.assertRaisesRegex(ss.UsageError, "SPUUpdater"):
            ss.check_suppressions("# third-party Sparkle: y\nrace:SPUUpdater\n", lambda: names)


class EnumerationTests(SweepCase):
    def test_closure_follows_path_dependencies_inside_the_repository(self):
        packages = ss.enumerate_closure(self.root, lambda path: self.dump(TOOLCHAIN, path, {}))
        self.assertEqual([p.path for p in packages],
                         ["Packages/macOS/CmuxNext", "Packages/Shared/CmuxTheme", "Packages/macOS/CmuxUpdater"])
        self.assertEqual(packages[0].tests, ("CmuxNextAppTests", "CmuxNextDaemonTests"))
        self.assertEqual(packages[2].tests, ())


class LaneParseTests(unittest.TestCase):
    def test_each_target_gets_its_own_output_across_nested_groups(self):
        text = lane_text("Packages/macOS/CmuxNext", {"A": ("passed", "one"), "B": ("failed (exit 66)", TSAN)})
        results, output = ss.parse_lane_output("\x1b[1m" + text.replace("\n", "\r\n"))
        self.assertEqual(results, {"A": "passed", "B": "failed (exit 66)"})
        self.assertNotIn("ThreadSanitizer", output["A"])
        self.assertIn("WARNING: ThreadSanitizer: data race", output["B"])


class SweepTests(SweepCase):
    NEXT = "Packages/macOS/CmuxNext"
    THEME = "Packages/Shared/CmuxTheme"

    def test_base_red_is_listed_and_its_reports_are_not_counted(self):
        lane = FakeLane({
            ("base", self.NEXT): (11, lane_text(self.NEXT, {"CmuxNextAppTests": ("failed (exit 11)", "signal 11"),
                                                            "CmuxNextDaemonTests": ("passed", "ok")})),
            ("thread", self.NEXT): (66, lane_text(self.NEXT, {"CmuxNextAppTests": ("failed (exit 66)", TSAN),
                                                              "CmuxNextDaemonTests": ("failed (exit 66)", TSAN)})),
        })
        status, stdout, _ = self.run_main(["--sanitize", "thread"], lane)
        self.assertEqual(status, 1)
        self.assertIn("base-red suites (red with no sanitizer; listed, not counted): 1", stdout)
        self.assertIn(f"{self.NEXT} CmuxNextAppTests: failed (exit 11)", stdout)
        findings = self.out()
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["kind"], "tsan")
        self.assertEqual(findings[0]["targets"], [f"{self.NEXT}:CmuxNextDaemonTests"])
        self.assertEqual(findings[0]["frames"][0], "TerminalRegistry.register(_:)")
        self.assertEqual([r["target"] for r in self.out("base-red.jsonl")], ["CmuxNextAppTests"])
        self.assertEqual([r["reason"] for r in self.out("not-counted.jsonl")], ["base-red"])
        # The base pass runs with no sanitizer; the thread pass with suppressions and longer limits.
        base_env = next(env for mode, _, env in lane.calls if mode == "base")
        self.assertNotIn("CMUX_SWIFT_SANITIZE", base_env)
        thread_env = next(env for mode, _, env in lane.calls if mode == "thread")
        self.assertIn(f"suppressions={ss.SUPPRESSIONS}", thread_env["TSAN_OPTIONS"])
        self.assertEqual(thread_env["CMUX_SWIFT_TEST_STALL_SECONDS"], "540")
        # CmuxUpdater has no test target: never run.
        self.assertNotIn("Packages/macOS/CmuxUpdater", {path for _, path, _ in lane.calls})

    def test_only_the_modes_kind_counts(self):
        lane = FakeLane({
            ("address", self.THEME): (1, lane_text(self.THEME, {"CmuxThemeTests": ("failed (exit 66)", TSAN + ASAN)})),
        })
        status, _, _ = self.run_main(["--sanitize", "address", "--package", "CmuxTheme"], lane)
        self.assertEqual(status, 1)
        self.assertEqual([f["kind"] for f in self.out()], ["asan"])
        self.assertEqual([r["reason"] for r in self.out("not-counted.jsonl")], ["kind tsan is not counted in address"])
        self.assertEqual({path for _, path, _ in lane.calls}, {self.THEME})

    def test_same_report_in_two_targets_is_one_finding(self):
        lane = FakeLane({
            ("thread", self.NEXT): (66, lane_text(self.NEXT, {"CmuxNextAppTests": ("failed (exit 66)", TSAN),
                                                              "CmuxNextDaemonTests": ("failed (exit 66)", TSAN)})),
        })
        self.run_main(["--sanitize", "thread", "--package", self.NEXT], lane)
        findings = self.out()
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["count"], 2)

    def test_clean_sweep_exits_zero_and_red_without_report_is_not_counted(self):
        lane = FakeLane({
            ("undefined", self.THEME): (1, lane_text(self.THEME, {"CmuxThemeTests": ("stalled/timeout", "slow")})),
        })
        status, _, _ = self.run_main(["--sanitize", "undefined"], lane)
        self.assertEqual(status, 0)
        self.assertEqual(self.out(), [])
        self.assertEqual([r["reason"] for r in self.out("not-counted.jsonl")],
                         ["red under the mode with no counted report"])
        undefined_env = next(env for mode, _, env in lane.calls if mode == "undefined")
        self.assertIn("print_stacktrace=1", undefined_env["UBSAN_OPTIONS"])

    def test_coop_strict_counts_the_blocked_pool_thread_not_the_idle_main_thread(self):
        stalled = watchdog_sample("swiftpm-testing-helper", POOL_STALL)
        lane = FakeLane({
            ("coop-strict", self.THEME): (124, lane_text(self.THEME, {"CmuxThemeTests": ("stalled/timeout", stalled)})),
        })
        status, _, _ = self.run_main(["--sanitize", "coop-strict", "--package", "CmuxTheme"], lane)
        self.assertEqual(status, 1)
        [finding] = self.out()
        self.assertEqual((finding["kind"], finding["exception"]), ("hang", ss.POOL_STALL))
        self.assertEqual(finding["frames"][0], "ThemeLoader.loadSync()")
        self.assertNotIn("dispatch_main", " ".join(finding["frames"]))
        self.assertEqual(finding["process"], "swiftpm-testing-helper")
        # The lane gets the test-only knob; the build never sees the strict pool.
        coop_env = next(env for mode, _, env in lane.calls if mode == "coop-strict")
        self.assertEqual(coop_env["CMUX_SWIFT_TEST_COOP_STRICT"], "1")
        self.assertNotIn("LIBDISPATCH_COOPERATIVE_POOL_STRICT", coop_env)
        self.assertNotIn("CMUX_SWIFT_SANITIZE", coop_env)

    def test_two_different_pool_deadlocks_are_two_findings(self):
        other = POOL_STALL.replace("ThemeLoader.loadSync()", "PaletteCache.warm()")
        lane = FakeLane({
            ("coop-strict", self.NEXT): (124, lane_text(self.NEXT, {
                "CmuxNextAppTests": ("stalled/timeout", watchdog_sample("swiftpm-testing-helper", POOL_STALL)),
                "CmuxNextDaemonTests": ("stalled/timeout", watchdog_sample("xctest", other))})),
        })
        self.run_main(["--sanitize", "coop-strict", "--package", self.NEXT], lane)
        findings = self.out()
        self.assertEqual(len({f["hash12"] for f in findings}), 2)
        self.assertEqual(sorted(f["frames"][0] for f in findings), ["PaletteCache.warm()", "ThemeLoader.loadSync()"])

    def test_coop_strict_stall_without_a_test_process_pool_thread_is_not_counted(self):
        # The SwiftPM driver stalled before a test process started, or the sample shows only the main thread.
        for body in (watchdog_sample("swift-test", POOL_STALL), watchdog_sample("xctest", HANG)):
            with self.subTest(body=body[:40]):
                lane = FakeLane({
                    ("coop-strict", self.THEME): (124, lane_text(self.THEME, {"CmuxThemeTests": ("stalled/timeout", body)})),
                })
                status, _, _ = self.run_main(["--sanitize", "coop-strict", "--package", "CmuxTheme"], lane)
                self.assertEqual(status, 0)
                self.assertEqual(self.out(), [])
                self.assertIn("stalled with no cooperative-pool thread in a test-process sample",
                              [r["reason"] for r in self.out("not-counted.jsonl")])

    def test_a_mode_that_does_not_build_is_no_verdict(self):
        lane = FakeLane({("thread", self.THEME): (1, "error: linker failed\n")})
        status, stdout, _ = self.run_main(["--sanitize", "thread", "--package", "CmuxTheme"], lane)
        self.assertEqual(status, 3)
        self.assertIn("no verdict for Packages/Shared/CmuxTheme under thread: build failed (exit 1)", stdout)

    def test_a_package_that_does_not_build_at_the_base_is_no_verdict(self):
        lane = FakeLane({("base", self.THEME): (1, "error: compile failed\n")})
        status, stdout, _ = self.run_main(["--sanitize", "thread", "--package", "CmuxTheme"], lane)
        self.assertEqual(status, 3)
        self.assertIn("CmuxThemeTests: build failed (exit 1)", stdout)
        self.assertIn("no verdict for Packages/Shared/CmuxTheme under base: build failed (exit 1)", stdout)
        self.assertEqual([mode for mode, _, _ in lane.calls], ["base"])

    def test_no_package_building_at_the_base_never_exits_zero(self):
        # No Xcode, no GhosttyKit or a compile break: zero sanitizer tests ran, so `0 findings` is no evidence.
        lane = FakeLane({("base", self.NEXT): (1, "error: no such module\n"),
                         ("base", self.THEME): (1, "error: no such module\n")})
        status, _, _ = self.run_main(["--sanitize", "thread"], lane)
        self.assertEqual(status, 3)
        self.assertEqual([mode for mode, _, _ in lane.calls], ["base", "base"])
        summary = json.loads((self.root / ".build/sanitizer-sweep/summary.json").read_text())
        self.assertEqual({row["package"] for row in summary["incomplete"]}, {self.NEXT, self.THEME})

    def test_lane_runs_get_the_resolved_xcode_and_sdk(self):
        lane = FakeLane({})
        self.run_main(["--sanitize", "thread", "--package", "CmuxTheme"], lane,
                      environ={**FLEET, "SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"})
        self.assertTrue(lane.calls)
        for _, _, env in lane.calls:
            self.assertEqual(env["DEVELOPER_DIR"], TOOLCHAIN.developer_dir)
            self.assertEqual(env["SDKROOT"], TOOLCHAIN.sdkroot)

    def test_a_killed_step_keeps_the_base_red_list_and_the_runs_done(self):
        class Killed(Exception):
            pass

        scripted = FakeLane({
            ("base", self.THEME): (1, lane_text(self.THEME, {"CmuxThemeTests": ("failed (exit 1)", "boom")})),
            ("thread", self.NEXT): (66, lane_text(self.NEXT, {"CmuxNextAppTests": ("failed (exit 66)", TSAN),
                                                              "CmuxNextDaemonTests": ("passed", "ok")})),
        })

        def lane(package, env, log):
            if env.get("CMUX_SWIFT_SANITIZE") == "thread" and package.path == self.THEME:
                raise Killed  # the step timeout ends the sweep in its last run
            return scripted(package, env, log)

        with self.assertRaises(Killed), redirect_stdout(io.StringIO()):
            ss.main(["--sanitize", "thread"], environ=FLEET, system="Darwin", resolve=lambda root, env: TOOLCHAIN,
                    dump=self.dump, run_lane=lane, names=lambda: [], root=self.root)
        self.assertEqual([r["target"] for r in self.out("base-red.jsonl")], ["CmuxThemeTests"])
        self.assertEqual([f["kind"] for f in self.out()], ["tsan"])
        summary = json.loads((self.root / ".build/sanitizer-sweep/summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual(summary["runs"], [f"base {self.NEXT}", f"base {self.THEME}", f"thread {self.NEXT}"])


class ToolchainTests(unittest.TestCase):
    """resolve_toolchain: the lane's select_xcode + pin_sdkroot, with a fake select-ci-xcode.sh and xcrun."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "scripts/select-ci-xcode.sh").write_text(
            '#!/bin/bash\n[ "$CMUX_CI_SKIP_XCODE_SELECT" = 1 ] || exit 9\n'
            'echo "DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer" >> "$GITHUB_ENV"\n')
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        # xcrun answers with DEVELOPER_DIR's SDK, and only when no SDKROOT leaked into it.
        (bin_dir / "xcrun").write_text('#!/bin/bash\n[ -z "${SDKROOT:-}" ] || exit 7\n'
                                       'echo "$DEVELOPER_DIR/Platforms/MacOSX.platform/SDKs/MacOSX.sdk"\n')
        (bin_dir / "xcrun").chmod(0o755)
        self.path = f"{bin_dir}:{os.environ['PATH']}"

    def tearDown(self):
        self.tmp.cleanup()

    def test_selects_the_ci_xcode_and_its_sdk_over_a_leaked_sdkroot(self):
        toolchain = ss.resolve_toolchain(self.root, {"PATH": self.path,
                                                     "SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"})
        self.assertEqual(toolchain, TOOLCHAIN)

    def test_keeps_an_exported_developer_dir(self):
        toolchain = ss.resolve_toolchain(self.root, {"PATH": self.path, "DEVELOPER_DIR": "/Applications/Xcode_27.app"})
        self.assertEqual(toolchain.developer_dir, "/Applications/Xcode_27.app")
        self.assertEqual(toolchain.sdkroot, "/Applications/Xcode_27.app/Platforms/MacOSX.platform/SDKs/MacOSX.sdk")

    def test_no_xcode_is_no_verdict(self):
        (self.root / "scripts/select-ci-xcode.sh").write_text("#!/bin/bash\necho 'no pinned Xcode' >&2\nexit 1\n")
        with self.assertRaisesRegex(ss.SweepError, "no pinned Xcode"):
            ss.resolve_toolchain(self.root, {"PATH": self.path})


if __name__ == "__main__":
    unittest.main()
