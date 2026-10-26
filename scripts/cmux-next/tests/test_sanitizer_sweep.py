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
TSAN = (FIXTURES / "tsan-race.txt").read_text()
ASAN = (FIXTURES / "asan-uaf.txt").read_text()
HANG = (FIXTURES / "hang-sample.txt").read_text()


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
        mode = env.get("CMUX_SWIFT_SANITIZE") or ("coop-strict" if env.get("LIBDISPATCH_COOPERATIVE_POOL_STRICT")
                                                  else "base")
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

    def dump(package_dir: Path) -> dict:
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
            status = ss.main(argv, environ=environ, system=system, dump=self.dump, run_lane=lane, root=self.root)
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
        ss.check_suppressions("# third-party Sparkle 2.6: reads cached state off main\nrace:SPUUpdater\n")
        with self.assertRaisesRegex(ss.UsageError, "third-party"):
            ss.check_suppressions("race:SPUUpdater\n")
        with self.assertRaisesRegex(ss.UsageError, "third-party"):
            ss.check_suppressions("# Sparkle races\nrace:SPUUpdater\n")

    def test_refuses_cmux_code_and_unknown_types(self):
        with self.assertRaisesRegex(ss.UsageError, "cmux code"):
            ss.check_suppressions("# third-party x: y\nrace:CmuxNextTerminal\n")
        with self.assertRaisesRegex(ss.UsageError, "not a TSan suppression"):
            ss.check_suppressions("# third-party x: y\nleak:Foo\n")

    def test_refuses_more_than_ten(self):
        text = "".join(f"# third-party Lib{i}: benign\nrace:Lib{i}\n" for i in range(11))
        with self.assertRaisesRegex(ss.UsageError, "limit is 10"):
            ss.check_suppressions(text)


class EnumerationTests(SweepCase):
    def test_closure_follows_path_dependencies_inside_the_repository(self):
        packages = ss.enumerate_closure(self.root, self.dump)
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

    def test_coop_strict_counts_a_stalled_targets_hang_sample(self):
        lane = FakeLane({
            ("coop-strict", self.THEME): (124, lane_text(self.THEME, {"CmuxThemeTests": ("stalled/timeout", HANG)})),
        })
        status, _, _ = self.run_main(["--sanitize", "coop-strict", "--package", "CmuxTheme"], lane)
        self.assertEqual(status, 1)
        self.assertEqual([f["kind"] for f in self.out()], ["hang"])
        coop_env = next(env for mode, _, env in lane.calls if mode == "coop-strict")
        self.assertEqual(coop_env["LIBDISPATCH_COOPERATIVE_POOL_STRICT"], "1")
        self.assertNotIn("CMUX_SWIFT_SANITIZE", coop_env)

    def test_a_mode_that_does_not_build_is_no_verdict(self):
        lane = FakeLane({("thread", self.THEME): (1, "error: linker failed\n")})
        status, stdout, _ = self.run_main(["--sanitize", "thread", "--package", "CmuxTheme"], lane)
        self.assertEqual(status, 3)
        self.assertIn("no verdict for Packages/Shared/CmuxTheme under thread: build failed (exit 1)", stdout)

    def test_a_package_red_at_base_build_is_all_base_red_and_skipped(self):
        lane = FakeLane({("base", self.THEME): (1, "error: compile failed\n")})
        status, stdout, _ = self.run_main(["--sanitize", "thread", "--package", "CmuxTheme"], lane)
        self.assertEqual(status, 0)
        self.assertIn("CmuxThemeTests: build failed (exit 1)", stdout)
        self.assertEqual([mode for mode, _, _ in lane.calls], ["base"])


if __name__ == "__main__":
    unittest.main()
