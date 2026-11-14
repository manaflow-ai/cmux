#!/usr/bin/env python3
"""Exercise `cmux-next-ios-sim.sh test ui=... profile` without Xcode or a simulator.

Run on Linux: python3 -I tests/test_ios_sim_ui_profile.py
The script's real argument parsing, profile block and UI test block run against fake Apple
tools (xcrun simctl/xctrace, xcodebuild, notifyutil, ditto); the summarizer
(scripts/ci/ios_sim_time_profile.py) runs on an export shaped like xctrace's, ids and refs
included. The assertions cover calls and retained evidence.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux-next-ios-sim.sh"
SUMMARIZER = ROOT / "scripts/ci/ios_sim_time_profile.py"
SIMULATOR = "ui-profile-test-simulator"

# Two launches of the app (pids 101 and 202, as a UI test relaunches it) and a test runner.
# Values appear once with id= and later as ref=, as xctrace export writes them.
TABLE = """<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[9]'><schema name="time-profile"><col><mnemonic>time</mnemonic><name>Sample Time</name></col></schema>
<row><sample-time id="1" fmt="00:00.001">1000000</sample-time><thread id="2" fmt="Main Thread 0x1 (CmuxMobileApp, pid: 101)"><tid id="3" fmt="0x1">1</tid><process id="4" fmt="CmuxMobileApp (101)"><pid id="5" fmt="101">101</pid></process></thread><core id="6" fmt="CPU 0">0</core><thread-state id="7" fmt="Running">Running</thread-state><weight id="8" fmt="1.00 ms">1000000</weight><backtrace id="9"><frame id="10" name="ListLayout.measure" addr="0x10"><binary id="11" name="CmuxMobileApp"/></frame><frame id="12" name="ListView.body.getter" addr="0x20"><binary ref="11"/></frame><frame id="13" name="main" addr="0x30"><binary ref="11"/></frame></backtrace></row>
<row><sample-time id="14" fmt="00:00.002">2000000</sample-time><thread ref="2"/><core ref="6"/><thread-state ref="7"/><weight ref="8"/><backtrace ref="9"/></row>
<row><sample-time id="15" fmt="00:00.003">3000000</sample-time><thread id="16" fmt="Main Thread 0x2 (CmuxMobileApp, pid: 202)"><tid id="17" fmt="0x2">2</tid><process id="18" fmt="CmuxMobileApp (202)"><pid id="19" fmt="202">202</pid></process></thread><core ref="6"/><thread-state ref="7"/><weight id="20" fmt="2.00 ms">2000000</weight><backtrace id="21"><frame id="22" name="JSONDecoder.decode" addr="0x40"><binary ref="11"/></frame><frame ref="12"/><frame ref="13"/></backtrace></row>
<row><sample-time id="23" fmt="00:00.004">4000000</sample-time><thread id="24" fmt="Thread 0x3 (CmuxMobileApp, pid: 202)"><tid id="25" fmt="0x3">3</tid><process ref="18"/></thread><core ref="6"/><thread-state ref="7"/><weight ref="8"/><backtrace id="26"><frame id="27" name="worker_loop" addr="0x50"><binary ref="11"/></frame></backtrace></row>
<row><sample-time id="28" fmt="00:00.005">5000000</sample-time><thread id="29" fmt="Main Thread 0x4 (CmuxMobileAppUITests-Runner, pid: 303)"><tid id="30" fmt="0x4">4</tid><process id="31" fmt="CmuxMobileAppUITests-Runner (303)"><pid id="32" fmt="303">303</pid></process></thread><core ref="6"/><thread-state ref="7"/><weight ref="8"/><sentinel/></row>
</node></trace-query-result>
"""

FAKE_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, signal, sys, time, zipfile
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALLS"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"tool": tool, "args": args}) + "\n")
notices = pathlib.Path(os.environ["NOTICES"])

if tool == "notifyutil":
    assert args[0] == "-1", args
    while not (notices / args[1]).exists():
        time.sleep(0.05)
elif tool == "xcodebuild":
    pathlib.Path(args[args.index("-resultBundlePath") + 1]).mkdir()
    # Long enough for a recorder started just before to set its SIGINT handler.
    time.sleep(0.5)
    print("fake UI tests ran")
    sys.exit(int(os.environ.get("UI_STATUS", "0")))
elif tool == "ditto":
    src, dst = map(pathlib.Path, args[-2:])
    with zipfile.ZipFile(dst, "w") as z:
        for path in src.rglob("*"):
            z.write(path, path.relative_to(src.parent))
elif tool == "xcrun" and args[:2] == ["xctrace", "record"]:
    if "--device" in args and os.environ.get("DEVICE_FAILS") == "1":
        print("Cannot find device", file=sys.stderr)
        sys.exit(1)
    if os.environ.get("HOST_FAILS") == "1" and "--device" not in args:
        sys.exit(1)
    trace = pathlib.Path(args[args.index("--output") + 1])
    def stop(*_):
        trace.mkdir()
        (trace / "fixture").write_text("trace")
        print("Output file saved as: " + str(trace))
        sys.exit(0)
    signal.signal(signal.SIGINT, stop)
    (notices / args[args.index("--notify-tracing-started") + 1]).write_text("")
    print("Starting recording. Ctrl-C to stop the recording", flush=True)
    while True:
        time.sleep(0.05)
elif tool == "xcrun" and args[:2] == ["xctrace", "export"]:
    output = pathlib.Path(args[args.index("--output") + 1])
    if "--toc" in args:
        output.write_text("<trace-toc/>")
    else:
        assert args[args.index("--xpath") + 1] == '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', args
        output.write_text(os.environ["TABLE"])
elif tool == "xcrun" and args[0] == "simctl":
    if args[1] == "create":
        print("ui-profile-test-simulator")
    elif args[1] in ("boot", "bootstatus", "shutdown", "delete"):
        pass
    elif args[1] == "io" and args[3] == "recordVideo":
        signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
        pathlib.Path(args[-1]).write_bytes(b"mp4")
        while True:
            time.sleep(0.05)
    else:
        sys.exit("unexpected simctl: " + repr(args))
else:
    sys.exit("unexpected tool: " + tool + " " + repr(args))
'''


class SummarizerTests(unittest.TestCase):
    def test_refs_resolve_and_launches_group_by_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            table = Path(tmp) / "table.xml"
            table.write_text(TABLE)
            md, js = Path(tmp) / "s.md", Path(tmp) / "s.json"
            run = subprocess.run([sys.executable, "-I", str(SUMMARIZER), str(table), "--markdown", str(md), "--json", str(js)],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            summary = json.loads(js.read_text())
            self.assertEqual(summary["rows"], 5)
            app = summary["processes"][0]
            self.assertEqual(app["process"], "CmuxMobileApp")
            self.assertEqual(app["pids"], ["101", "202"])
            self.assertEqual(app["samples"], 4)
            self.assertEqual(app["cpu_ms"], 5.0)
            self.assertEqual(app["main_thread_samples"], 3)
            self.assertEqual(app["main_thread_ms"], 4.0)
            self.assertEqual(app["main_thread_self"], [{"symbol": "JSONDecoder.decode", "ms": 2.0},
                                                       {"symbol": "ListLayout.measure", "ms": 2.0}])
            total = {r["symbol"]: r["ms"] for r in app["main_thread_total"]}
            self.assertEqual(total, {"main": 4.0, "ListView.body.getter": 4.0, "JSONDecoder.decode": 2.0,
                                     "ListLayout.measure": 2.0})
            self.assertNotIn("worker_loop", total)
            runner = summary["processes"][1]
            self.assertEqual((runner["process"], runner["main_thread_samples"], runner["main_thread_self"]),
                             ("CmuxMobileAppUITests-Runner", 1, []))
            self.assertIn("## CmuxMobileApp: main thread, 4.0 ms", md.read_text())
            self.assertIn("CmuxMobileApp: main thread 4.0 ms of 5.0 ms CPU; top self JSONDecoder.decode 2.0 ms", run.stdout)

    def test_an_empty_table_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            table = Path(tmp) / "table.xml"
            table.write_text("<trace-query-result><node/></trace-query-result>")
            run = subprocess.run([sys.executable, "-I", str(SUMMARIZER), str(table), "--markdown", f"{tmp}/m", "--json", f"{tmp}/j"],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)


class ProfileRouteTests(unittest.TestCase):
    def run_route(self, *args, **env):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-ui-profile-route-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        out, work, binaries, notices = root / "artifacts", root / "work", root / "bin", root / "notices"
        for path in (out, work, binaries, notices, root / "scripts/ci"):
            path.mkdir(parents=True)
        (root / "scripts/ci/ios_sim_time_profile.py").write_text(SUMMARIZER.read_text())
        for name in ("xcodebuild", "xcrun", "notifyutil", "ditto"):
            tool = binaries / name
            tool.write_text(FAKE_TOOL)
            tool.chmod(0o755)
        script = SCRIPT.read_text()
        # The real selection parsing, then the real profile and UI test blocks.
        parse = script[script.index("# test's optional selection"):script.index("run_kit=1")]
        start = script.index("# --- UI test profile")
        end = script.index("# --- Chief layout benchmark", start)
        harness = root / "route.sh"
        harness.write_text(
            'set -euo pipefail\n'
            'mode=test; work="$WORK"; out="$OUT"; summary="$out/SUMMARY.md"\n'
            'device_type="test-device"; runtime="test-runtime"\n'
            'note() { printf "%s\\n" "$*" | tee -a "$summary"; }\n'
            'keep_test_logs() { :; }\n'
            + parse + script[start:end]
        )
        calls = root / "calls.jsonl"
        process = subprocess.run(
            ["bash", str(harness), "test", *args], cwd=root, text=True, capture_output=True, timeout=60,
            env={**os.environ, "PATH": f"{binaries}{os.pathsep}{os.environ['PATH']}", "CALLS": str(calls),
                 "NOTICES": str(notices), "TABLE": TABLE, "WORK": str(work), "OUT": str(out),
                 "CMUX_CI_STEP_KEY": "route-test", **env},
        )
        recorded = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        return process, recorded, out, work

    def records(self, calls):
        return [c["args"] for c in calls if c["tool"] == "xcrun" and c["args"][:2] == ["xctrace", "record"]]

    def test_profile_records_the_ui_run_on_its_simulator_and_keeps_the_summary(self):
        process, calls, out, work = self.run_route("ui=PairingFlowUITests", "profile")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        tools = [(c["tool"], c["args"][:2]) for c in calls]
        boot = tools.index(("xcrun", ["simctl", "boot"]))
        record = tools.index(("xcrun", ["xctrace", "record"]))
        build = next(i for i, c in enumerate(calls) if c["tool"] == "xcodebuild")
        self.assertLess(boot, record)
        self.assertLess(record, build)
        [args] = self.records(calls)
        self.assertEqual(args[args.index("--device") + 1], SIMULATOR)
        self.assertEqual(args[args.index("--template") + 1], "Time Profiler")
        self.assertIn("--all-processes", args)
        summary = json.loads((out / "ui-profile-summary.json").read_text())
        self.assertEqual(summary["processes"][0]["process"], "CmuxMobileApp")
        self.assertTrue((out / "ui-profile-summary.md").is_file())
        self.assertTrue((out / "ui-time-profile.xml.gz").is_file())
        self.assertTrue((out / "ui-profile-toc.xml").is_file())
        with zipfile.ZipFile(out / "ui-profile.trace.zip") as z:
            self.assertIn("ui-profile.trace/fixture", z.namelist())
        text = (out / "SUMMARY.md").read_text()
        self.assertIn("all processes on the device", text)
        self.assertIn("CmuxMobileApp: main thread 4.0 ms", text)
        self.assertIn("ui-profile.trace.zip", text)
        self.assertFalse((work / "ui-profile.trace").exists())
        self.assertIn(["simctl", "delete", SIMULATOR], [c["args"] for c in calls if c["tool"] == "xcrun"])

    def test_profile_and_video_together(self):
        process, calls, out, _ = self.run_route("ui=A", "video", "profile")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual([c["args"][:2] for c in calls if c["args"][:2] == ["simctl", "boot"]], [["simctl", "boot"]])
        self.assertTrue((out / "ui-video.mp4").is_file())
        self.assertTrue((out / "ui-profile-summary.json").is_file())

    def test_a_device_recording_that_fails_falls_back_to_the_host(self):
        process, calls, out, _ = self.run_route("ui=A", "profile", DEVICE_FAILS="1")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        first, second = self.records(calls)
        self.assertIn("--device", first)
        self.assertNotIn("--device", second)
        self.assertIn("all processes on the host", (out / "SUMMARY.md").read_text())

    def test_no_recording_still_runs_the_tests_and_says_so(self):
        process, calls, out, _ = self.run_route("ui=A", "profile", DEVICE_FAILS="1", HOST_FAILS="1")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertTrue(any(c["tool"] == "xcodebuild" for c in calls))
        self.assertIn("xctrace did not start", (out / "SUMMARY.md").read_text())
        self.assertFalse((out / "ui-profile-summary.json").exists())

    def test_a_failing_ui_run_still_keeps_the_profile(self):
        process, _, out, _ = self.run_route("ui=A", "profile", UI_STATUS="65")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIn("exit 65", (out / "SUMMARY.md").read_text())
        self.assertTrue((out / "ui-profile-summary.json").is_file())

    def test_profile_without_ui_is_refused_before_any_work(self):
        process, calls, _, _ = self.run_route("only=A/B", "profile")
        self.assertEqual(process.returncode, 2)
        self.assertIn("give it ui=", process.stderr)
        self.assertEqual(calls, [])

    def test_without_profile_nothing_is_recorded(self):
        process, calls, out, _ = self.run_route("ui=A", "video")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(self.records(calls), [])
        self.assertFalse(any(c["tool"] == "notifyutil" for c in calls))
        self.assertFalse((out / "ui-profile-summary.json").exists())


if __name__ == "__main__":
    unittest.main()
