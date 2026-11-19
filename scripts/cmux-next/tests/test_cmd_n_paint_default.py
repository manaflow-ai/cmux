#!/usr/bin/env python3
"""cmd-n-paint-e2e.py without `--screen`: the same calls, the same output and the same exit status as before it.

The driver runs against an app that is a socket in this test (its answers are fixed below), from a folder that
holds only the driver and bench_arms.py: the two files that these openings needed before `--screen`. What the app
was asked, what the driver printed, its `--json` and its exit status are compared with
fixtures/cmd-n-paint-default.json, which `outcome()` below made with the driver of the commit before `--screen`.
The driver's own waits (its `time.sleep` calls) do not run: they wait for a real app.

    python3 -I scripts/cmux-next/tests/test_cmd_n_paint_default.py
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
STORED = HERE / "fixtures" / "cmd-n-paint-default.json"
NEEDED = ("cmd-n-paint-e2e.py", "bench_arms.py")
# Each case: the driver's arguments after `--socket app.sock --out out --json report.json`.
CASES = {
    "default arguments, each frame good": [],
    "a split workspace, one key, bad frames": ["--split", "3", "--keys", "n", "--runs", "3", "--duration-ms", "900"],
}
RUN = ("import runpy, sys, time\n"
       "time.sleep = lambda seconds: None\n"
       "sys.argv = sys.argv[1:]\n"
       "runpy.run_path(sys.argv[0], run_name='__main__')\n")


def frame(index, **bad):
    return {"ms": 17.0 * index, "file": f"frame-{index:03d}.png", "outside_vs_before": 0.01, "outside_vs_final": 0.0,
            "content_vs_before": 0.3, "content_vs_final": 0.0, "intermediate": False, "blank": False,
            "content_intermediate": False, **bad}


class App:
    """The app's side of the socket. `bad` is the case with bad frames: its 2nd recording has a frame between the two
    pictures and took no spare, its 5th fails, its 8th has a blank frame."""

    def __init__(self, path, bad):
        self.bad, self.calls, self.openings, self.strips = bad, [], [], 0
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return  # closed: the case ended
            with conn:
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(1 << 16)
                    if not chunk:
                        break
                    buf += chunk
                if buf:
                    conn.sendall((json.dumps(self.answer(json.loads(buf))) + "\n").encode())

    def answer(self, request):
        method, params = request["method"], request.get("params") or {}
        self.calls.append([method, params])
        action = params.get("action")
        if method == "debug.new_tab" and action == "state":
            return {"ok": True, "result": {"spares": [{"ready": True}], "openings": list(self.openings)}}
        if method == "debug.new_tab" and action == "frame_strip":
            self.strips += 1
            if self.bad and self.strips == 5:
                return {"ok": False, "error": "the window is not on a screen"}
            frames = [frame(n) for n in range(4)]
            if self.bad and self.strips == 2:
                frames[1] = frame(1, intermediate=True, outside_vs_final=0.004)
            if self.bad and self.strips == 8:
                frames[0] = frame(0, blank=True)
            self.openings.append({"spare": not (self.bad and self.strips == 2)})
            return {"ok": True, "result": {
                "frames": frames, "frame_count": 6, "mean_interval_ms": 16.7, "intermediate": sum(f["intermediate"] for f in frames),
                "content_intermediate": 0, "strip_intermediate": 0, "blank": sum(f["blank"] for f in frames),
                "first_change_ms": 17, "settled_ms": 17 + self.strips, "spans": [{"name": "newTab.open", "ms": 2.0, "duration_ms": 1.0}]}}
        return {"ok": True, "result": {}}

    def close(self):
        self.server.close()


def outcome(driver_folder, arguments, bad, files=NEEDED):
    """What one run of `driver_folder`'s driver asked the app, printed and returned, in a scratch folder that holds
    only `files` of it."""
    scratch = tempfile.mkdtemp(prefix="cmd-n-paint-default-")
    try:
        only = os.path.join(scratch, "driver")
        os.mkdir(only)
        for name in files:
            shutil.copy(os.path.join(driver_folder, name), only)
        app = App(os.path.join(scratch, "app.sock"), bad)
        try:
            done = subprocess.run([sys.executable, "-I", "-c", RUN, os.path.join("driver", NEEDED[0]), "--socket", "app.sock",
                                   "--out", "out", "--json", "report.json", *arguments],
                                  cwd=scratch, capture_output=True, text=True, timeout=120, check=False)
        finally:
            app.close()
        report = Path(scratch, "report.json")
        # One line of text for each call and for the report: the stored file stays small and a difference names its line.
        return {"exit": done.returncode, "stdout": done.stdout.splitlines(), "stderr": done.stderr.splitlines(),
                "calls": [json.dumps(call, sort_keys=True) for call in app.calls],
                "report": json.dumps(json.loads(report.read_text()), sort_keys=True) if report.exists() else None}
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


class DefaultPathTests(unittest.TestCase):
    maxDiff = None

    def test_the_openings_without_screen_are_as_before(self):
        stored = json.loads(STORED.read_text())
        self.assertEqual(sorted(stored), sorted(CASES))
        for name, arguments in CASES.items():
            with self.subTest(name):
                got = outcome(str(HERE.parent), arguments, bad="bad frames" in name)
                for part in ("exit", "stderr", "stdout", "report", "calls"):
                    self.assertEqual(got[part], stored[name][part], part)

    def test_the_stored_cases_pass_and_fail(self):
        # The stored text is of a run that the driver judged: one case passes, one fails on its bad frames.
        stored = json.loads(STORED.read_text())
        good, bad = (stored[name] for name in CASES)
        self.assertEqual((good["exit"], good["stdout"][-1], good["stderr"]), (0, "PASS no blank or intermediate frame", []))
        self.assertEqual(bad["exit"], 1)
        self.assertIn("FAIL blank or intermediate frames: Cmd-N run 1 (no spare adopted", bad["stderr"][-1])
        self.assertTrue(any("frame_strip failed" in line for line in bad["stdout"]))
        self.assertTrue(any('"duration_ms": 700' in call for call in good["calls"]))  # the recording's length as before

    def test_screen_runs_its_own_mode_and_judges_nothing(self):
        # This app's frames are one window's, with no word of their capture: each row is INVALID, and the exit is 0.
        mode = (*NEEDED, "new_surface_screen.py", "new_surface_frames.py", "bench_page_engine.py")
        got = outcome(str(HERE.parent), ["--screen", "--runs", "1", "--keys", "n", "--page-watch", "0"], bad=False, files=mode)
        self.assertEqual((got["exit"], got["stderr"]), (0, []))
        self.assertEqual(got["stdout"][-1], "NEW-SURFACE-SCREEN report only: 2 rows, 2 INVALID, 0 pictures kept")
        strips = [json.loads(call)[1] for call in got["calls"] if '"frame_strip"' in call]
        self.assertEqual([(s["above"], s["duration_ms"], s.get("repeat"), s.get("repeat_interval_ms")) for s in strips],
                         [(True, 2000, None, None), (True, 2100.0, 2, 100.0)])
        self.assertEqual([row["invalid"][0].split(":")[0] for row in json.loads(got["report"])["rows"]], ["capture", "capture"])
        self.assertNotIn("PASS", "".join(got["stdout"]))

    def test_screen_refuses_what_it_cannot_count_before_a_call_to_the_app(self):
        mode = (*NEEDED, "new_surface_screen.py", "new_surface_frames.py", "bench_page_engine.py")
        # 11 runs of 2 keys, alone and after a key: 66 openings, and the app keeps its newest 64 opening records.
        many = outcome(str(HERE.parent), ["--screen", "--runs", "11"], bad=False, files=mode)
        self.assertEqual((many["exit"], many["calls"]), (2, []))
        self.assertIn("--screen: 66 openings asked", many["stderr"][-1])
        # A part of the flag's word is the flag to the parser, and the mode's module is read only by the whole word.
        part = outcome(str(HERE.parent), ["--scr", "--runs", "1"], bad=False, files=mode)
        self.assertEqual((part["exit"], part["calls"]), (2, []))
        self.assertIn("--screen: write the flag whole", part["stderr"][-1])


if __name__ == "__main__":
    unittest.main()
