#!/usr/bin/env python3
"""Exercise the Chief benchmark shell route without Xcode or a simulator.

Run on Linux: python3 -I tests/test_ios_chief_benchmark_route.py
The real benchmark block and final status handling run against fake Apple tools;
the assertions cover calls and retained evidence, not shell implementation text.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux-next-ios-sim.sh"
MARKER = "CHIEF_LIVE_LAYOUT main_thread_ms_per_1000_tokens="
SIMULATOR = "chief-benchmark-test-simulator"

FAKE_TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALLS"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"tool": tool, "args": args,
        "opt_in": os.environ.get("TEST_RUNNER_CMUX_CHIEF_LIVE_PERF"),
        "cwd": os.getcwd()}) + "\n")

def measurement(run):
    return "CHIEF_LIVE_LAYOUT main_thread_ms_per_1000_tokens=" + str(100 + run)

if tool == "xcodebuild":
    result = Path(args[args.index("-resultBundlePath") + 1])
    result.mkdir()
    (result / "test-evidence").write_text("retained result bundle")
    run = int(result.stem.rsplit("-", 1)[1])
    if run == int(os.environ["FAIL_RUN"]):
        print("fake xcodebuild failed", flush=True)
        sys.exit(65)
    if run == int(os.environ["MISSING_RUN"]):
        print("Test case ChiefLiveLayoutPerformanceTests skipped")
    elif os.environ["METRIC_SOURCE"] == "stdout":
        print(measurement(run))
elif tool == "xcrun":
    if args[:2] == ["simctl", "create"]:
        print("chief-benchmark-test-simulator")
    elif args[:2] in (["simctl", "shutdown"], ["simctl", "delete"]):
        pass
    elif args[:4] == ["xcresulttool", "get", "log", "--type"]:
        result = Path(args[args.index("--path") + 1])
        run = int(result.stem.rsplit("-", 1)[1])
        if os.environ["METRIC_SOURCE"] == "console" and run != int(os.environ["MISSING_RUN"]):
            print(measurement(run))
    else:
        sys.exit("unexpected xcrun invocation: " + repr(args))
elif tool == "shasum":
    print("a" * 64 + "  " + args[-1])
else:
    sys.exit("unexpected tool: " + tool)
'''


class ChiefBenchmarkRouteTests(unittest.TestCase):
    def run_route(self, *, baseline=False, source="stdout", missing_run=0, fail_run=0):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-chief-route-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        out = root / "artifacts"
        work = root / "work"
        package = root / "cmux-next-ios/CmuxMobileKit"
        binaries = root / "bin"
        for path in (out / "bench", work, package, binaries):
            path.mkdir(parents=True)
        for name in ("xcodebuild", "xcrun", "shasum"):
            tool = binaries / name
            tool.write_text(FAKE_TOOL, encoding="utf-8")
            tool.chmod(0o755)

        script = SCRIPT.read_text(encoding="utf-8")
        start = script.index("# --- Chief layout benchmark")
        end = script.index("# --- Benchmarks", start)
        # Keep production exit propagation too; the unrelated app packaging needs
        # a real app and is deliberately outside this portable route test.
        status = script.index('if [[ "${test_status:-0}" -ne 0 ]]')
        harness = root / "route.sh"
        harness.write_text(
            'set -euo pipefail\n'
            'mode="$1"; work="$2"; out="$3"; summary="$out/SUMMARY.md"\n'
            'device_type="test-device"; runtime="test-runtime"\n'
            'note() { printf "%s\\n" "$*" | tee -a "$summary"; }\n'
            + script[start:end] + "\n" + script[status:],
            encoding="utf-8",
        )
        calls_file = root / "calls.jsonl"
        environment = {
            **os.environ,
            "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "CALLS": str(calls_file),
            "METRIC_SOURCE": source,
            "MISSING_RUN": str(missing_run),
            "FAIL_RUN": str(fail_run),
            "CMUX_CI_STEP_KEY": "route-test",
        }
        # Prove the route sets this itself, rather than inheriting a local opt-in.
        environment.pop("TEST_RUNNER_CMUX_CHIEF_LIVE_PERF", None)
        mode = "chief-live-perf-baseline" if baseline else "chief-live-perf"
        process = subprocess.run(
            ["bash", str(harness), mode, str(work), str(out)],
            cwd=root, env=environment, text=True, capture_output=True, timeout=20,
        )
        calls = [json.loads(line) for line in calls_file.read_text().splitlines()]
        return process, calls, out, work

    def assert_cleanup(self, calls):
        for operation in ("shutdown", "delete"):
            self.assertEqual(
                [call["args"] for call in calls
                 if call["tool"] == "xcrun" and call["args"][:2] == ["simctl", operation]],
                [["simctl", operation, SIMULATOR]],
            )

    def test_three_runs_share_simulator_and_derived_data_and_keep_stdout_metrics(self):
        process, calls, out, work = self.run_route()
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        creates = [call for call in calls
                   if call["tool"] == "xcrun" and call["args"][:2] == ["simctl", "create"]]
        self.assertEqual(len(creates), 1)
        builds = [call for call in calls if call["tool"] == "xcodebuild"]
        self.assertEqual(len(builds), 3)
        for run, call in enumerate(builds, 1):
            with self.subTest(run=run):
                args = call["args"]
                self.assertEqual(args[0], "test")
                self.assertEqual(call["opt_in"], "1")
                self.assertEqual(args[args.index("-destination") + 1], f"id={SIMULATOR},arch=arm64")
                self.assertEqual(args[args.index("-derivedDataPath") + 1], str(work / "dd-chief-perf"))
                self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "NO")
                self.assertIn("-only-testing:CmuxMobileChiefTests/ChiefLiveLayoutPerformanceTests", args)
                self.assertIn("CODE_SIGNING_ALLOWED=NO", args)
                self.assertFalse(any("CMUX_CHIEF_LIVE_BASELINE" in arg for arg in args))
                result = out / "bench" / f"chief-live-{run}.xcresult"
                self.assertEqual(args[args.index("-resultBundlePath") + 1], str(result))
                self.assertTrue((result / "test-evidence").is_file())
                metric = f"{MARKER}{100 + run}"
                self.assertIn(metric, (out / "bench" / f"chief-live-{run}.log").read_text())
                self.assertIn(metric, (out / "bench" / f"chief-live-{run}.txt").read_text())
                self.assertIn(metric, (out / "SUMMARY.md").read_text())
        self.assert_cleanup(calls)

    def test_baseline_compiles_the_flag_and_keeps_xcresult_console_metrics(self):
        process, calls, out, _ = self.run_route(baseline=True, source="console")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        builds = [call for call in calls if call["tool"] == "xcodebuild"]
        self.assertEqual(len(builds), 3)
        for run, call in enumerate(builds, 1):
            self.assertEqual(call["opt_in"], "1")
            self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CHIEF_LIVE_BASELINE", call["args"])
            metric = f"{MARKER}{100 + run}"
            self.assertNotIn(MARKER, (out / "bench" / f"chief-live-{run}.log").read_text())
            self.assertIn(metric, (out / "bench" / f"chief-live-{run}-console.log").read_text())
            self.assertIn(metric, (out / "bench" / f"chief-live-{run}.txt").read_text())
            self.assertIn(metric, (out / "SUMMARY.md").read_text())
        self.assert_cleanup(calls)

    def test_skipped_test_without_measurement_fails_and_stops_after_that_run(self):
        process, calls, out, _ = self.run_route(missing_run=2)
        self.assertNotEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(len([call for call in calls if call["tool"] == "xcodebuild"]), 2)
        self.assertIn("no measurement", (out / "SUMMARY.md").read_text())
        self.assertIn("skipped", (out / "bench/chief-live-2.log").read_text())
        self.assertIn(MARKER, (out / "bench/chief-live-1.txt").read_text())
        self.assertFalse((out / "bench/chief-live-3.log").exists())
        self.assert_cleanup(calls)

    def test_xcodebuild_failure_propagates_and_keeps_failure_evidence(self):
        process, calls, out, _ = self.run_route(fail_run=1)
        self.assertEqual(process.returncode, 65, process.stdout + process.stderr)
        self.assertEqual(len([call for call in calls if call["tool"] == "xcodebuild"]), 1)
        self.assertIn("fake xcodebuild failed", (out / "bench/chief-live-1.log").read_text())
        self.assertTrue((out / "bench/chief-live-1.xcresult/test-evidence").is_file())
        self.assert_cleanup(calls)


if __name__ == "__main__":
    unittest.main()
