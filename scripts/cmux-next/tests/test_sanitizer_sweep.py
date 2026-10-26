#!/usr/bin/env python3
"""sanitizer_sweep.py (p10-stability-013): base-red pre-pass, per-mode lane runs, only
sanitizer signatures counted, suppression rules, fleet-only refusal. The lane and
crash_signature.py are faked; no Swift build runs.

Run: python3 -I -m unittest scripts/cmux-next/tests/test_sanitizer_sweep.py
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent
sys.path.insert(0, str(HERE.parent))
import sanitizer_sweep as sweep  # noqa: E402

TSAN_REPORT = """==================
WARNING: ThreadSanitizer: data race (pid=4242)
  Write of size 8 at 0x7b0c00001234 by thread T3:
    #0 CmuxNextControl.Counter.bump() Counter.swift:12 (CmuxNextControlTests:arm64+0x1234)
    #1 closure #1 in CounterTests.race() CounterTests.swift:30 (CmuxNextControlTests:arm64+0x2234)
  Previous read of size 8 at 0x7b0c00001234 by main thread:
    #0 CmuxNextControl.Counter.value.getter Counter.swift:8 (CmuxNextControlTests:arm64+0x3234)
SUMMARY: ThreadSanitizer: data race Counter.swift:12 in CmuxNextControl.Counter.bump()
=================="""

UBSAN_REPORT = """Sources/Foo/Bar.c:10:5: runtime error: signed integer overflow: 2147483647 + 1 cannot be represented in type 'int'
    #0 0x1000 in bar Bar.c:10
    #1 0x2000 in foo Foo.c:3
SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior Sources/Foo/Bar.c:10:5"""


def lane_output(package: str, suites: dict, built: bool = True) -> str:
    """What package-test-lane.sh suite prints: a build group, one group per suite, the table."""
    lines = [f"::group::swift build --build-tests -c debug {package}", "Build complete!", "::endgroup::"]
    if not built:
        lines.append("error: compile failed")
        return "\n".join(lines) + "\n"
    rows = []
    for suite, (result, body) in suites.items():
        lines.append(f"::group::swift test --filter {suite}")
        lines.extend(body.splitlines())
        lines.append("::endgroup::")
        rows.append(f"{suite:<48} {result:<18} {12:>6}s")
    lines.append(f"Swift suite results ({package}):")
    lines.append(f"{'suite':<48} {'result':<18} {'time':>7}")
    lines.extend(rows)
    lines.append("All suites passed." if all(r == "passed" for r, _ in suites.values()) else "1 of 2 suites failed.")
    return "\r\n".join(lines) + "\r\n"


def fake_signature(path: Path) -> list:
    text = path.read_text()
    if "ThreadSanitizer" in text:
        kind = "tsan"
    elif "AddressSanitizer" in text:
        kind = "asan"
    elif "runtime error" in text:
        kind = "ubsan"
    elif "LeakSanitizer" in text:
        kind = "lsan"
    else:
        return []
    frame = next((line.strip() for line in text.splitlines() if line.strip().startswith("#0")), "")
    return [{"kind": kind, "process": "xctest", "exception": kind, "frames": [frame],
             "hash12": hashlib.sha1(f"{kind}{frame}".encode()).hexdigest()[:12]}]


class FakeLane:
    """Answers each (mode, package) with a scripted lane output and records the calls."""

    def __init__(self, script):
        self.script = script
        self.calls = []

    def __call__(self, package, targets, env, log):
        mode = env.get("CMUX_SWIFT_SANITIZE") or ("coop-strict" if env.get("LIBDISPATCH_COOPERATIVE_POOL_STRICT") else "base")
        self.calls.append((mode, package, list(targets), dict(env)))
        return self.script(mode, package, targets)


class SweepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.supp = self.tmp / "supp.txt"
        self.supp.write_text("# none\n")

    def make(self, script, modes=("thread",), packages=None, **kw):
        packages = packages or [sweep.Package("Packages/macOS/CmuxNext", ["AppTests", "ControlTests", "StoreTests"])]
        lane = FakeLane(script)
        s = sweep.Sweep(repo=self.tmp, out_dir=self.tmp / "out", packages=packages,
                        modes=[sweep.MODES[m] for m in modes], suppressions=self.supp, run_lane=lane,
                        base_env={"PATH": "/usr/bin", "CMUX_SWIFT_SANITIZE": "stale"},
                        **{"signature": fake_signature, **kw})
        return s, lane

    def test_base_red_suites_are_listed_skipped_and_not_counted(self):
        def script(mode, package, targets):
            if mode == "base":
                return lane_output(package, {"AppTests": ("failed (exit 11)", "Exited with unexpected signal code 11"),
                                             "ControlTests": ("passed", ""), "StoreTests": ("passed", "")})
            return lane_output(package, {t: ("passed", "") for t in targets})
        s, lane = self.make(script)
        self.assertEqual(s.run(), sweep.EXIT_CLEAN)
        self.assertEqual(s.base_red, [{"package": "Packages/macOS/CmuxNext", "suite": "AppTests",
                                       "result": "failed (exit 11)"}])
        base_call, thread_call = lane.calls
        self.assertEqual(base_call[2], ["AppTests", "ControlTests", "StoreTests"])
        self.assertNotIn("CMUX_SWIFT_SANITIZE", base_call[3], "the base pass runs with no sanitizer")
        self.assertEqual(thread_call[2], ["ControlTests", "StoreTests"], "base-red suites are not swept")
        self.assertEqual(thread_call[3]["CMUX_SWIFT_SANITIZE"], "thread")
        self.assertIn(f"suppressions={self.supp}", thread_call[3]["TSAN_OPTIONS"])
        report = s.report()
        self.assertIn("Base-red suites", report)
        self.assertIn("AppTests  failed (exit 11)", report)

    def test_a_tsan_race_counts_once_per_signature(self):
        def script(mode, package, targets):
            if mode == "base":
                return lane_output(package, {t: ("passed", "") for t in targets})
            body = "Test race started.\n" + TSAN_REPORT + "\nTest other started.\n" + TSAN_REPORT
            return lane_output(package, {"AppTests": ("passed", ""), "ControlTests": ("failed (exit 66)", body),
                                         "StoreTests": ("passed", "")})
        s, _ = self.make(script)
        self.assertEqual(s.run(), sweep.EXIT_FINDINGS)
        counted = s.counted_findings()
        self.assertEqual(len(counted), 1)
        self.assertEqual(counted[0]["kind"], "tsan")
        self.assertEqual(counted[0]["count"], 2)
        self.assertEqual(counted[0]["suites"], ["ControlTests"])
        s.write(self.tmp / "findings.jsonl", "abc")
        rows = [json.loads(line) for line in (self.tmp / "findings.jsonl").read_text().splitlines()]
        self.assertEqual([r["hash12"] for r in rows], [counted[0]["hash12"]])
        summary = json.loads((self.tmp / "out" / "summary.json").read_text())
        self.assertEqual(summary["counted_findings"], 1)
        self.assertEqual(summary["exit"], sweep.EXIT_FINDINGS)

    def test_a_red_suite_without_a_report_is_listed_not_counted(self):
        def script(mode, package, targets):
            if mode == "base":
                return lane_output(package, {t: ("passed", "") for t in targets})
            return lane_output(package, {"AppTests": ("stalled/timeout", "made no progress"),
                                         "ControlTests": ("failed (exit 1)", "Expectation failed"),
                                         "StoreTests": ("passed", "")})
        s, _ = self.make(script)
        self.assertEqual(s.run(), sweep.EXIT_CLEAN)
        self.assertEqual(len(s.per_mode["thread"]["red_without_report"]), 2)
        self.assertEqual(s.counted_findings(), [])

    def test_colored_tsan_output_is_read(self):
        colored = "\n".join(f"\x1b[1m\x1b[31m{line}\x1b[0m" for line in TSAN_REPORT.splitlines())

        def script(mode, package, targets):
            body = "" if mode == "base" else colored
            return lane_output(package, {t: ("passed", body if t == "StoreTests" else "") for t in targets})
        s, _ = self.make(script)
        self.assertEqual(s.run(), sweep.EXIT_FINDINGS)
        (row,) = s.counted_findings()
        self.assertNotIn("\x1b", Path(row["reports"][0]).read_text())

    def test_ubsan_report_in_a_passing_suite_counts(self):
        def script(mode, package, targets):
            body = "" if mode == "base" else UBSAN_REPORT + "\nTest x passed."
            return lane_output(package, {"AppTests": ("passed", body), "ControlTests": ("passed", ""),
                                         "StoreTests": ("passed", "")})
        s, _ = self.make(script, modes=("undefined",))
        self.assertEqual(s.run(), sweep.EXIT_FINDINGS)
        (row,) = s.counted_findings()
        self.assertEqual(row["kind"], "ubsan")
        report = Path(row["reports"][0]).read_text()
        self.assertNotIn("Test x passed", report, "a UBSan report ends at its stack")

    def test_a_report_of_another_kind_is_recorded_not_counted(self):
        leak = "ERROR: LeakSanitizer: detected memory leaks\n    #0 0x1 in malloc\nSUMMARY: LeakSanitizer: 8 byte(s) leaked"
        def script(mode, package, targets):
            body = "" if mode == "base" else leak
            return lane_output(package, {t: ("passed", body if t == "AppTests" else "") for t in targets})
        s, _ = self.make(script, modes=("address",))
        self.assertEqual(s.run(), sweep.EXIT_CLEAN)
        self.assertEqual([r["kind"] for r in s.findings.values()], ["lsan"])
        self.assertEqual(s.counted_findings(), [])

    def test_a_package_that_does_not_build_under_a_mode_has_no_verdict(self):
        def script(mode, package, targets):
            if mode == "base":
                return lane_output(package, {t: ("passed", "") for t in targets})
            return lane_output(package, {}, built=False)
        s, _ = self.make(script, modes=("address",))
        self.assertEqual(s.run(), sweep.EXIT_NO_VERDICT)
        self.assertEqual(s.per_mode["address"]["no_verdict"][0]["package"], "Packages/macOS/CmuxNext")

    def test_a_package_that_does_not_build_at_the_base_is_all_base_red(self):
        def script(mode, package, targets):
            return lane_output(package, {}, built=False)
        s, lane = self.make(script)
        self.assertEqual(s.run(), sweep.EXIT_CLEAN)
        self.assertEqual(len(s.base_red), 3)
        self.assertTrue(all("did not build" in r["result"] for r in s.base_red))
        self.assertEqual(len(lane.calls), 1, "nothing is left to sweep")

    def test_an_unclassified_report_has_no_verdict(self):
        def script(mode, package, targets):
            body = "" if mode == "base" else "WARNING: ThreadSanitizer: something new\nSUMMARY: ThreadSanitizer: x"
            return lane_output(package, {t: ("passed", body if t == "StoreTests" else "") for t in targets})
        s, _ = self.make(script, signature=lambda path: [])
        self.assertEqual(s.run(), sweep.EXIT_NO_VERDICT)
        self.assertEqual(s.unclassified[0]["suite"], "StoreTests")

    def test_coop_strict_sets_the_pool_variable_and_counts_a_new_hang(self):
        def script(mode, package, targets):
            if mode == "base":
                return lane_output(package, {t: ("passed", "") for t in targets})
            return lane_output(package, {"AppTests": ("stalled/timeout", "\x1b[1m◇ Test waits() started.\x1b[0m"),
                                         "ControlTests": ("stalled/timeout", "made no progress"),
                                         "StoreTests": ("passed", "")})
        s, lane = self.make(script, modes=("coop-strict",))
        self.assertEqual(s.run(), sweep.EXIT_FINDINGS)
        env = lane.calls[1][3]
        self.assertEqual(env["LIBDISPATCH_COOPERATIVE_POOL_STRICT"], "1")
        self.assertNotIn("CMUX_SWIFT_SANITIZE", env, "a stale sanitizer setting is dropped")
        (row,) = s.counted_findings()
        self.assertEqual((row["kind"], row["suites"]), ("coop-strict-hang", ["AppTests"]))
        # A stall before any test started is swift test's own, not a finding.
        self.assertEqual(s.per_mode["coop-strict"]["no_verdict"][0]["suite"], "ControlTests")

    def test_include_base_red_runs_them_without_counting(self):
        def script(mode, package, targets):
            if mode == "base":
                return lane_output(package, {"AppTests": ("failed (exit 11)", ""), "ControlTests": ("passed", ""),
                                             "StoreTests": ("passed", "")})
            return lane_output(package, {t: ("failed (exit 66)" if t == "AppTests" else "passed",
                                             TSAN_REPORT if t == "AppTests" else "") for t in targets})
        s, lane = self.make(script, include_base_red=True)
        self.assertEqual(s.run(), sweep.EXIT_CLEAN)
        self.assertEqual(lane.calls[1][2], ["AppTests", "ControlTests", "StoreTests"])
        self.assertEqual(len(s.findings), 1)
        self.assertEqual(s.counted_findings(), [])


class EnumerateTests(unittest.TestCase):
    def test_follows_path_dependencies_inside_packages(self):
        repo = Path(tempfile.mkdtemp()).resolve()
        manifests = {
            repo / "Packages/macOS/CmuxNext": {
                "targets": [{"name": "CmuxNextApp", "type": "regular"}, {"name": "ZTests", "type": "test"},
                            {"name": "ATests", "type": "test"}],
                "dependencies": [{"fileSystem": [{"path": str(repo / "Packages/Shared/CmuxTheme")}]},
                                 {"fileSystem": [{"path": "../../Shared/CMUXAuthCore"}]},
                                 {"sourceControl": [{"identity": "sentry"}]},
                                 {"fileSystem": [{"path": str(repo / "vendor/Outside")}]}]},
            repo / "Packages/Shared/CmuxTheme": {"targets": [{"name": "ThemeTests", "type": "test"}],
                                                 "dependencies": [{"fileSystem": [{"path": "../CMUXAuthCore"}]}]},
            repo / "Packages/Shared/CMUXAuthCore": {"targets": [{"name": "CMUXAuthCore", "type": "regular"}],
                                                    "dependencies": []},
        }
        dumped = []

        def dump(path):
            dumped.append(path)
            return manifests[path]
        packages = sweep.enumerate_closure(repo, dump)
        self.assertEqual([(p.dir, p.targets) for p in packages],
                         [("Packages/macOS/CmuxNext", ["ATests", "ZTests"]),
                          ("Packages/Shared/CmuxTheme", ["ThemeTests"])])
        self.assertEqual(len(dumped), 3, "each package is read once; outside Packages/ is not read")

    def test_prefix_overlaps(self):
        self.assertEqual(sweep.prefix_overlaps(["CmuxNextAppTests", "CmuxNextAppTestsSlow", "Other"]),
                         [("CmuxNextAppTests", "CmuxNextAppTestsSlow")])


class SuppressionTests(unittest.TestCase):
    def check(self, text):
        path = Path(tempfile.mkdtemp()) / "s.txt"
        path.write_text(text)
        return sweep.check_suppressions(path)

    def test_the_checked_in_file_is_valid(self):
        active, errors = sweep.check_suppressions(REPO / sweep.SUPPRESSIONS)
        self.assertEqual(errors, [])
        self.assertLessEqual(active, sweep.MAX_SUPPRESSIONS)

    def test_reasoned_third_party_entry_passes(self):
        self.assertEqual(self.check("# Sentry's SentryCrash reads a flag racily; getsentry/sentry-cocoa#1\n"
                                    "race:SentryCrashMonitor\n"), (1, []))

    def test_entry_without_reason_fails(self):
        _, errors = self.check("# header\n\nrace:SPUUpdater\n")
        self.assertTrue(any("no '# reason'" in e for e in errors))

    def test_one_reason_does_not_cover_two_entries(self):
        _, errors = self.check("# reason\nrace:A\nrace:B\n")
        self.assertEqual(len(errors), 1)

    def test_cmux_code_is_refused(self):
        _, errors = self.check("# no\nrace:CmuxNextControl.Counter\n")
        self.assertTrue(any("cmux code" in e for e in errors))

    def test_bad_type_is_refused(self):
        _, errors = self.check("# why\nleak:Foo\n")
        self.assertTrue(any("TYPE:PATTERN" in e for e in errors))

    def test_more_than_ten_fail(self):
        text = "".join(f"# third-party reason {i}\nrace:Vendor{i}\n" for i in range(11))
        active, errors = self.check(text)
        self.assertEqual(active, 11)
        self.assertTrue(any("at most 10" in e for e in errors))


class CliTests(unittest.TestCase):
    def run_script(self, *args, env=None):
        base = {"PATH": "/usr/bin:/bin", "HOME": tempfile.mkdtemp()}
        base.update(env or {})
        return subprocess.run(["bash", str(REPO / "scripts/cmux-next/sanitizer-sweep.sh"), *args], env=base,
                              capture_output=True, text=True, cwd=REPO)

    def test_refuses_a_non_fleet_host(self):
        proc = self.run_script("--sanitize", "thread")
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("runs only on the build fleet", proc.stderr)
        self.assertIn("cmux-ci run --class isolated", proc.stderr)

    def test_python_driver_refuses_a_non_fleet_host_too(self):
        saved = dict(os.environ)
        try:
            os.environ.pop("CMUX_CI_STEP_KEY", None)
            os.environ.pop("GITHUB_ACTIONS", None)
            self.assertEqual(sweep.main(["--sanitize", "thread"]), sweep.EXIT_USAGE)
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_help_works_anywhere(self):
        proc = self.run_script("--help")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--sanitize", proc.stdout)

    def test_parse_modes(self):
        self.assertEqual([m.name for m in sweep.parse_modes("thread,coop-strict,thread")], ["thread", "coop-strict"])
        with self.assertRaises(Exception):
            sweep.parse_modes("memory")


class LaneParsingTests(unittest.TestCase):
    def test_the_real_lane_prints_what_the_parser_reads(self):
        lane = (REPO / sweep.LANE).read_text()
        self.assertIn("printf 'Swift suite results (%s):", lane)
        self.assertIn('echo "::group::swift test --filter $filter"', lane)
        self.assertIn("printf '%-48s %-18s %6ss' \"$filter\" \"$result\"", lane)
        self.assertIn('result="stalled/timeout"', lane)
        self.assertIn('result="failed (exit $status)"', lane)


if __name__ == "__main__":
    unittest.main()
