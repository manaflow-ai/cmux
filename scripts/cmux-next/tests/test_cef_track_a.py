#!/usr/bin/env python3
"""Layer hosting on, on a pin below the fork API of every Track A call, is a skip, not a failure (cef_track_a.py).

cef-layer-verify.py --mode on exits 3 there; cef-resize-sync-bench.py, cef-pin-staging.sh and split-spring-terminal.py
--suite=cef-resize-sync read that exit as a skip; a real failure beside it still fails them. Under the perf-lab
runner a skipped bench marks its run not-measurable.

Runs on any host (Linux included): the app, the verify and the benches are faked; no fleet.

    python3 -m unittest scripts/cmux-next/tests/test_cef_track_a.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import cef_track_a  # noqa: E402

SKIP_LINE = "skipped: needs CEF API >= 34, pin has 30"


class Decision(unittest.TestCase):
    def test_mode_on_below_the_track_a_fork_api_is_skipped_with_the_pins_api(self):
        self.assertEqual(cef_track_a.skip_reason("on", 30), SKIP_LINE)
        self.assertEqual(cef_track_a.skip_reason("on", 33), "skipped: needs CEF API >= 34, pin has 33")

    def test_mode_on_from_the_track_a_fork_api_mode_off_and_no_chromium_are_checked(self):
        self.assertIsNone(cef_track_a.skip_reason("on", 34))
        self.assertIsNone(cef_track_a.skip_reason("on", 40))
        self.assertIsNone(cef_track_a.skip_reason("off", 30))
        self.assertIsNone(cef_track_a.skip_reason("on", 0), "no Chromium is a failure, not a skip")

    def test_the_exit_code_is_distinct_and_a_failed_row_outranks_a_skip(self):
        ok, bad = {"check": "arm", "ok": True}, {"check": "arm", "ok": False}
        self.assertEqual(cef_track_a.exit_code([ok], None), 0)
        self.assertEqual(cef_track_a.exit_code([ok], SKIP_LINE), cef_track_a.SKIP_EXIT)
        self.assertEqual(cef_track_a.exit_code([], SKIP_LINE), cef_track_a.SKIP_EXIT)
        self.assertEqual(cef_track_a.exit_code([ok, bad], SKIP_LINE), 1)
        self.assertEqual(cef_track_a.exit_code([], None), 1)
        self.assertNotIn(cef_track_a.SKIP_EXIT, (0, 1))

    def test_the_fork_apis_are_the_apps(self):
        cef = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF"
        source = (cef / "CEFLayerHosting.swift").read_text() + (cef / "CEFLayerHosting+Default.swift").read_text()
        apis = {name: int(value) for name, value in re.findall(r"static let (\w+ForkAPI): Int32 = (\d+)", source)}
        self.assertEqual(apis["resizeFenceForkAPI"], cef_track_a.RESIZE_FENCE_FORK_API)
        self.assertEqual(apis["embedderVisibilityForkAPI"], cef_track_a.EMBEDDER_VISIBILITY_FORK_API)
        required = re.search(r"static let required: TrackA = \[([^\]]*)\]", source).group(1)
        self.assertEqual(sorted(p.strip() for p in required.split(",")), [".embedderVisibility", ".resizeFence"])

    def test_the_staging_script_uses_the_same_exit_code(self):
        script = (HERE / "cef-pin-staging.sh").read_text()
        self.assertIn(f"skip_exit={cef_track_a.SKIP_EXIT} ", script)

    def test_a_lab_skip_adds_the_need_and_keeps_the_launchs_answer(self):
        out = tempfile.mkdtemp(prefix="cef-track-a-")
        self.addCleanup(shutil.rmtree, out, True)
        probe = os.path.join(out, "debug-capabilities.json")
        self.assertIsNone(cef_track_a.report_lab_skip({}))
        with open(probe, "w") as f:
            json.dump({"missing": ["debug:debug.motion"], "asked": 3}, f)
        cef_track_a.report_lab_skip({cef_track_a.LAB_PROBE_OUT: probe})
        cef_track_a.report_lab_skip({cef_track_a.LAB_PROBE_OUT: probe})
        with open(probe) as f:
            self.assertEqual(json.load(f), {"missing": ["debug:debug.motion", "cef-fork-api>=34"], "asked": 3})


def load_bench():
    spec = importlib.util.spec_from_file_location("cef_resize_sync_bench_skip", HERE / "cef-resize-sync-bench.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ResizeSyncBench(unittest.TestCase):
    """On an API 30 pin the bench's verify of modes on and on0 exits 3; mode off verifies and runs its benches."""

    def setUp(self):
        self.bench = load_bench()
        self.out = tempfile.mkdtemp(prefix="cef-resize-skip-")
        self.addCleanup(shutil.rmtree, self.out, True)
        self.tunables = os.path.join(self.out, "debug-tunables.json")
        with open(self.tunables, "w") as f:
            json.dump({"version": 1, "values": {}}, f)
        self.off_fails = False
        self.recorded = []
        self.benches = []

        def call(command, stdout=None, stderr=None):
            out = command[command.index("--out") + 1]
            if command[1].endswith("cef-layer-verify.py"):
                mode = command[command.index("--mode") + 1]
                skipped = cef_track_a.skip_reason(mode, 30)
                ok = not (mode == "off" and self.off_fails)
                with open(os.path.join(out, f"verify-{mode}.json"), "w") as f:
                    json.dump({"rows": [{"check": "arm", "ok": ok}], "skipped": skipped,
                               "facts": {"fork_api": 30, "tunables_file": self.tunables}}, f)
                return cef_track_a.exit_code([{"ok": ok}], skipped)
            self.benches.append(Path(out).parent.name)
            run = {"layout": "1x2", "action": "split", "round": 0, "commit_p95_ms": 4.0, "commit_max_ms": 6.0,
                   "missed": 0, "frames_p95_ms": 8.3, "frames_p99_ms": 9.0, "frames_max_ms": 10.0,
                   "layout_p95_ms": 1.0, "refresh_ms": 8.3, "frame_intervals_ms": [8.3]}
            with open(command[command.index("--json") + 1], "w") as f:
                json.dump({"runs": [run], "summary": [run]}, f)
            return 0

        def record(series):
            self.recorded.extend(series)
            return True

        self.bench.subprocess.call = call
        self.bench.record_results = record

    def main(self, modes="off,on,on0"):
        with redirect_stdout(io.StringIO()) as printed:
            code = self.bench.main(["--app", "/x/cmux DEV.app", "--tag", "t", "--out", self.out, "--modes", modes,
                                    "--benches", "light"])
        with open(os.path.join(self.out, "summary.json")) as f:
            return code, json.load(f), printed.getvalue()

    def failed(self, mode):
        return [list(s.samples) for s in self.recorded if s.metric == f"cef_resize_sync.{mode}.failed"]

    def test_skipped_modes_run_no_bench_record_no_failure_and_exit_3(self):
        code, summary, printed = self.main()
        self.assertEqual(code, cef_track_a.SKIP_EXIT)
        self.assertEqual(self.benches, ["off"])
        for mode in ("on", "on0"):
            self.assertIsNone(summary["validity"][mode]["ok"])
            self.assertEqual(summary["validity"][mode]["skipped"], SKIP_LINE)
            self.assertEqual(self.failed(mode), [], "a skipped mode is not a failed one")
            self.assertIn(f"== {mode}: {SKIP_LINE}", printed)
        self.assertEqual(self.failed("off"), [[0]])

    def test_a_failure_beside_a_skip_still_fails(self):
        self.off_fails = True
        code, summary, _ = self.main()
        self.assertEqual(code, 1)
        self.assertFalse(summary["validity"]["off"]["ok"])

    def test_under_the_lab_runner_a_skip_marks_the_run_not_measurable(self):
        probe = os.path.join(self.out, "debug-capabilities.json")
        os.environ[cef_track_a.LAB_PROBE_OUT] = probe
        self.addCleanup(os.environ.pop, cef_track_a.LAB_PROBE_OUT, None)
        code, _, _ = self.main()
        self.assertEqual(code, cef_track_a.SKIP_EXIT)
        with open(probe) as f:
            self.assertEqual(json.load(f)["missing"], [cef_track_a.NEED])

    def test_mode_off_alone_exits_0(self):
        code, _, _ = self.main("off")
        self.assertEqual(code, 0)


FAKE_VERIFY = textwrap.dedent("""\
    import json, os, sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import cef_track_a
    args = sys.argv[1:]
    mode, out = args[args.index("--mode") + 1], args[args.index("--out") + 1]
    os.makedirs(out, exist_ok=True)
    skipped = cef_track_a.skip_reason(mode, 30)
    ok = os.environ.get("FAKE_FAIL") != mode
    print(f"SKIP | track-a | {skipped}" if skipped else f"{'PASS' if ok else 'FAIL'} | hosted | {mode}")
    json.dump({"rows": [{"check": "arm", "ok": ok}], "facts": {"fork_api": 30}, "skipped": skipped},
              open(os.path.join(out, f"verify-{mode}.json"), "w"))
    sys.exit(cef_track_a.exit_code([{"ok": ok}], skipped))
    """)


class Callers(unittest.TestCase):
    """The real cef-pin-staging.sh and split-spring-terminal.py over a fake verify (and bench) that answers as an
    API 30 pin does."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="cef-track-a-callers-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        for name in ("cef-pin-staging.sh", "split-spring-terminal.py", "cef_track_a.py"):
            shutil.copy(HERE / name, self.dir)
        Path(self.dir, "cef-layer-verify.py").write_text(FAKE_VERIFY)
        Path(self.dir, "cef_pin_staging.py").write_text("print('PASS fork-api: 30')\n")
        # split-spring-terminal.py's prologue: this host has no GUI session, and the suite never launches an app here.
        Path(self.dir, "bench_launch.py").write_text(
            "BenchApp = LaunchError = None\ndef require_gui_session(name):\n    pass\n")
        Path(self.dir, "cef-resize-sync-bench.py").write_text(
            "import os, sys\nsys.exit(int(os.environ.get('FAKE_BENCH_EXIT', '3')))\n")
        self.out = os.path.join(self.dir, "out")

    def staging(self, **env):
        return subprocess.run(["bash", os.path.join(self.dir, "cef-pin-staging.sh"), "check"], capture_output=True,
                              text=True, env={**os.environ, "NX_ARTIFACTS": self.out, "NX_APP": "/x/a.app",
                                              "NX_APP_TAG": "t", "STAGING_PARTS": "verify,api", **env})

    def test_staging_reads_a_skipped_verify_as_a_skip(self):
        done = self.staging()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn(f"SKIP | track-a | {SKIP_LINE}", done.stdout)
        self.assertIn("skipped, not failed", done.stdout)
        self.assertIn("PASS fork-api: 30", done.stdout)
        self.assertIn("staging rc=0", done.stdout)

    def test_staging_still_fails_on_a_failed_verify(self):
        done = self.staging(FAKE_FAIL="off")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)

    def suite(self, **env):
        return subprocess.run([sys.executable, os.path.join(self.dir, "split-spring-terminal.py"),
                               "--suite=cef-resize-sync", "--app", "/x/a.app", "--tag", "t", "--out", self.out],
                              capture_output=True, text=True, env={**os.environ, **env})

    def test_split_spring_reads_skipped_parts_as_skips(self):
        done = self.suite()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        with open(os.path.join(self.out, "cef-resize-sync.json")) as f:
            report = json.load(f)
        self.assertEqual(report["skipped"], ["bench", "verify-on"])
        self.assertEqual(report["verify-off"], 0)

    def test_split_spring_still_fails_on_a_failed_part(self):
        done = self.suite(FAKE_BENCH_EXIT="1")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
