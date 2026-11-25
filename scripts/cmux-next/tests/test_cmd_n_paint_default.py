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
# The files that `--screen` needs more: its mode, its numbers, the page's engine, and the app's settings (the look).
SCREEN_MODE = ("new_surface_screen.py", "new_surface_frames.py", "bench_page_engine.py", "new_surface_look.py", "window_look.py")
# Each case: the driver's arguments after `--socket app.sock --out out --json report.json`.
CASES = {
    "default arguments, each frame good": [],
    "a split workspace, one key, bad frames": ["--split", "3", "--keys", "n", "--runs", "3", "--duration-ms", "900"],
}
RUN = ("import runpy, sys, time\n"
       "time.sleep = lambda seconds: None\n"
       "sys.argv = sys.argv[1:]\n"
       "runpy.run_path(sys.argv[0], run_name='__main__')\n")


# A run of the driver's own launch (`--app`) in which no app starts: `subprocess.Popen` prints the names of the
# app's variables in the launch's environment and ends the run. The screen mode's steps before its launch (the
# bundle's last run, the tag's saved session) do not run here: they read and move a Mac's files.
LAUNCH = ("import json, os, runpy, subprocess, sys, time, types\n"
          "time.sleep = lambda seconds: None\n"
          "sys.argv = sys.argv[1:]\n"
          "sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))\n"
          "if '--screen' in sys.argv:\n"
          "    import new_surface_screen\n"
          "    new_surface_screen.fresh_session = lambda *asked: None\n"
          "    end = types.SimpleNamespace(last=lambda: None, set_aside=lambda: None, own=None, launch_fault=lambda pid: None)\n"
          "    sys.modules['run_end_record'] = types.SimpleNamespace(RunEnd=lambda app: end)\n"
          "def popen(command, env=None, **more):\n"
          "    print('LAUNCH-ENV ' + json.dumps(sorted(name for name in env if name.startswith('CMUX_NEXT_'))), flush=True)\n"
          "    raise SystemExit(7)\n"
          "subprocess.Popen = popen\n"
          "runpy.run_path(sys.argv[0], run_name='__main__')\n")


def launched_with(arguments, files):
    """The driver's exit status and the names of the app's `CMUX_NEXT_` variables in the launch that it makes for a
    bundle (`LAUNCH`), from a scratch folder that is also the run's home and its folder for temporary files. With
    no such line: the last lines that the driver wrote."""
    scratch = tempfile.mkdtemp(prefix="cmd-n-paint-launch-")
    try:
        only, binary = os.path.join(scratch, "driver"), Path(scratch, "cmux DEV launch-test.app", "Contents", "MacOS", "cmux DEV launch-test")
        os.mkdir(only)
        for name in files:
            shutil.copy(os.path.join(str(HERE.parent), name), only)
        binary.parent.mkdir(parents=True)
        binary.write_text("")
        done = subprocess.run([sys.executable, "-I", "-c", LAUNCH, os.path.join("driver", NEEDED[0]), "--app", str(binary.parents[2]),
                               "--tag", f"launch-test-{os.getpid()}", "--out", "out", *arguments], cwd=scratch, capture_output=True,
                              text=True, timeout=120, check=False, env={**os.environ, "HOME": scratch, "TMPDIR": scratch})
        said = [line for line in done.stdout.splitlines() if line.startswith("LAUNCH-ENV ")]
        return done.returncode, json.loads(said[0][len("LAUNCH-ENV "):]) if said else (done.stdout + done.stderr).splitlines()[-3:]
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def frame(index, **bad):
    return {"ms": 17.0 * index, "file": f"frame-{index:03d}.png", "outside_vs_before": 0.01, "outside_vs_final": 0.0,
            "content_vs_before": 0.3, "content_vs_final": 0.0, "intermediate": False, "blank": False,
            "content_intermediate": False, **bad}


class App:
    """The app's side of the socket. `bad` is the case with bad frames: its 2nd recording has a frame between the two
    pictures and took no spare, its 5th fails, its 8th has a blank frame. `window`: the app lists one window (with no
    pane), it is active with that window as its key window, and its list of windows has that one window, shown."""

    def __init__(self, path, bad, window=False):
        self.bad, self.calls, self.openings, self.strips = bad, [], [], 0
        self.window, self.active = window, window
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
        if self.window and method == "debug.focus":
            return {"ok": True, "result": {"app_active": self.active, "windows": [{"id": "window-1", "is_key": self.active}]}}
        if self.window and method == "debug.window.focus":
            return {"ok": True, "result": {"key": "window-1" if self.active else None, "front": "window-1"}}
        if self.window and method == "debug.window_list":
            return {"ok": True, "result": {"windows": [{
                "id": 41, "kind": "main", "title": "a title", "frame": {"x": 40.0, "y": 230.0, "width": 1200.0, "height": 900.0},
                "visible": True, "parent": None, "class": "ShellWindow", "key": self.active, "occluded": False, "miniaturized": False}]}}
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


def outcome(driver_folder, arguments, bad, files=NEEDED, window=False):
    """What one run of `driver_folder`'s driver asked the app, printed and returned, in a scratch folder that holds
    only `files` of it. `window`: the app lists a window that can become the key window of an active app (`App`)."""
    scratch = tempfile.mkdtemp(prefix="cmd-n-paint-default-")
    try:
        only = os.path.join(scratch, "driver")
        os.mkdir(only)
        for name in files:
            shutil.copy(os.path.join(driver_folder, name), only)
        app = App(os.path.join(scratch, "app.sock"), bad, window)
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
        mode = (*NEEDED, *SCREEN_MODE)
        got = outcome(str(HERE.parent), ["--screen", "--runs", "1", "--keys", "n", "--page-watch", "0"], bad=False, files=mode, window=True)
        self.assertEqual((got["exit"], got["stderr"]), (0, []))
        # One ask for the window in front, with no activation, before the first recording.
        asked = [index for index, call in enumerate(got["calls"]) if '"debug.window.focus"' in call]
        self.assertEqual([json.loads(got["calls"][index])[1] for index in asked], [{"window": "window-1"}])
        self.assertLess(asked[0], next(index for index, call in enumerate(got["calls"]) if '"frame_strip"' in call))
        # 2 reads of the app's windows: before the first recording and after the last one.
        strips = [index for index, call in enumerate(got["calls"]) if '"frame_strip"' in call]
        reads = [index for index, call in enumerate(got["calls"]) if '"debug.window_list"' in call]
        self.assertEqual((len(reads), reads[0] < strips[0], reads[-1] > strips[-1]), (2, True, True))
        self.assertEqual((json.loads(got["report"])["window"]["same"], json.loads(got["report"])["key_window_form"]), (True, "shell"))
        self.assertEqual(got["stdout"][-1], "NEW-SURFACE-SCREEN report only: 2 rows, 2 INVALID, 0 pictures kept")
        strips = [json.loads(call)[1] for call in got["calls"] if '"frame_strip"' in call]
        self.assertEqual([(s["above"], s["duration_ms"], s.get("repeat"), s.get("repeat_interval_ms")) for s in strips],
                         [(True, 2000, None, None), (True, 2100.0, 2, 100.0)])
        self.assertEqual([row["invalid"][0].split(":")[0] for row in json.loads(got["report"])["rows"]], ["capture", "capture"])
        self.assertNotIn("PASS", "".join(got["stdout"]))

    def test_the_launch_of_each_mode_has_the_variable_that_takes_no_keyboard(self):
        # An app with `CMUX_NEXT_NO_ACTIVATE=1` takes no keyboard of a person at the Mac, and only such an app reads
        # the 2 variables that place its window (`CMUX_NEXT_TEST_WINDOW_SCREEN`, `CMUX_NEXT_TEST_WINDOW_FRAME`).
        # Each mode's launch has the 3, also the screen mode's.
        wanted = ("CMUX_NEXT_NO_ACTIVATE", "CMUX_NEXT_SOCKET_MODE", "CMUX_NEXT_TEST_WINDOW_SCREEN", "CMUX_NEXT_TEST_WINDOW_FRAME")
        for arguments, files in (([], NEEDED), (["--screen", "--keys", "n", "--page-watch", "0"], (*NEEDED, *SCREEN_MODE)),
                                 (["--screen", "--keys", "t,w,n", "--gaps", "0", "--close-cases", "idle,hold", "--key-tabs", "6,84",
                                   "--page-watch", "0"], (*NEEDED, *SCREEN_MODE))):
            with self.subTest(arguments=arguments):
                code, names = launched_with(arguments, files)
                self.assertEqual((code, [name in names for name in wanted]), (7, [True] * 4), names)

    def test_screen_takes_12_runs_of_a_case(self):
        # 12 runs of 2 keys, alone and after a key, are 72 openings in the run and 2 at most in one recording. The
        # tool counts the app's new opening records for each recording alone, so the run's own count is no limit.
        mode = (*NEEDED, *SCREEN_MODE)
        got = outcome(str(HERE.parent), ["--screen", "--runs", "12", "--page-watch", "0"], bad=False, files=mode, window=True)
        self.assertEqual((got["exit"], got["stderr"]), (0, []))
        self.assertEqual(got["stdout"][-1], "NEW-SURFACE-SCREEN report only: 48 rows, 48 INVALID, 0 pictures kept")

    def test_screen_sends_the_close_tab_cases_keys_through_the_driver(self):
        # The driver's own sender (a thread beside the recording's call) and its real clock, against this app: its
        # frames are one window's and it lists no tabs, so each row is INVALID. The keys that went to the app are
        # counted, and not their order: the order is by the clock.
        mode = (*NEEDED, *SCREEN_MODE)
        got = outcome(str(HERE.parent), ["--screen", "--runs", "1", "--keys", "w", "--page-watch", "0"], bad=False, files=mode, window=True)
        self.assertEqual((got["exit"], got["stderr"]), (0, []))
        self.assertEqual(got["stdout"][-1], "NEW-SURFACE-SCREEN report only: 4 rows, 4 INVALID, 0 pictures kept")
        calls = [json.loads(call) for call in got["calls"]]
        new_tab = [params for method, params in calls if method == "debug.key" and params.get("key") == "t"]
        self.assertEqual(new_tab, [{"key": "t", "modifiers": ["command"]}] * 8)  # 1 for the idle case's tab, 1, and 6 key-downs
        held = [params for method, params in calls if method == "debug.key" and "sequence" in params]
        # The hold: one sequence in the shell window, 5 of its key-downs with the repeat flag.
        self.assertEqual([(h["key_window"], len(h["sequence"]), sum(1 for step in h["sequence"] if step.get("repeat"))) for h in held], [("shell", 9, 5)])
        strips = [params for method, params in calls if params.get("action") == "frame_strip"]
        self.assertEqual([(s["key"], s.get("repeat"), s["duration_ms"]) for s in strips], [("w", None, 2000)] * 4)
        labels = [row["label"] for row in json.loads(got["report"])["rows"]]
        self.assertEqual(labels, ["cmd-w-idle-0", "cmd-w-key100-0", "cmd-w-downs100-0", "cmd-w-hold100-0"])

    def test_screen_takes_the_counts_of_the_keys_workspaces_tabs_through_the_driver(self):
        # This app's window has no pane, so the tool can make no tab: it asks the app for no tab, and it ends at the
        # first count with the stopped run's code and no row. It made no workspace, so it asks for no other workspace.
        mode = (*NEEDED, *SCREEN_MODE)
        asked = ["--screen", "--runs", "12", "--keys", "t", "--gaps", "0", "--page-watch", "0", "--key-tabs", "6,84"]
        got = outcome(str(HERE.parent), asked, bad=False, files=mode, window=True)
        self.assertEqual((got["exit"], got["stderr"]), (3, []))
        self.assertEqual(got["stdout"][-1], "NEW-SURFACE-SCREEN report only: 0 rows, 0 INVALID, 0 pictures kept; STOPPED key-tabs: 6 tabs asked "
                                            "and the tool made no tab (the app lists no pane of the shown workspace (debug.focus); the app "
                                            "lists no tab): no case recorded at this count")
        report = json.loads(got["report"])
        self.assertEqual([(size["asked"], size["tabs"]) for size in report["key_tabs"]["sizes"]], [(6, None)])
        self.assertEqual([call for call in got["calls"] if '"action.run"' in call or '"frame_strip"' in call], [])
        self.assertEqual((report["rows"], report["head"][0]), ([], "the app was active: yes"))
        # Counts that do not rise are refused before a call to the app.
        falls = outcome(str(HERE.parent), ["--screen", "--key-tabs", "84,6"], bad=False, files=mode)
        self.assertEqual((falls["exit"], falls["calls"]), (2, []))
        self.assertIn("--key-tabs", falls["stderr"][-1])

    def test_screen_ends_at_once_with_its_own_exit_code_in_an_app_that_lists_no_window(self):
        # No window: no app to make active. The driver ends with the stopped run's code, and it records no case.
        mode = (*NEEDED, *SCREEN_MODE)
        got = outcome(str(HERE.parent), ["--screen", "--runs", "12", "--page-watch", "0", "--key-tabs", "6,84"], bad=False, files=mode)
        self.assertEqual((got["exit"], got["stderr"]), (3, []))
        self.assertEqual(got["stdout"][-1], "NEW-SURFACE-SCREEN report only: 0 rows, 0 INVALID, 0 pictures kept; STOPPED active: the app lists "
                                            "no window (debug.focus): no tab made, no case recorded")
        self.assertEqual([call for call in got["calls"] if '"frame_strip"' in call or '"action.run"' in call or '"debug.key"' in call], [])
        self.assertEqual(json.loads(got["report"])["rows"], [])

    def test_screen_refuses_what_it_cannot_count_before_a_call_to_the_app(self):
        mode = (*NEEDED, *SCREEN_MODE)
        # The app keeps its newest 64 opening records, and the tool counts the new ones of ONE recording by the
        # list's content. A hold of 31 New Tab key-downs can make 62 records in its recording: over the limit of 60.
        many = outcome(str(HERE.parent), ["--screen", "--keys", "w", "--hold-keys", "31"], bad=False, files=mode)
        self.assertEqual((many["exit"], many["calls"]), (2, []))
        self.assertIn("--screen: 62 opening records can come in one recording", many["stderr"][-1])
        # A case that is not one of the Close Tab key's is refused by its name.
        word = outcome(str(HERE.parent), ["--screen", "--keys", "w", "--close-cases", "idle,held"], bad=False, files=mode)
        self.assertEqual((word["exit"], word["calls"]), (2, []))
        self.assertIn("held", word["stderr"][-1])
        # A part of the flag's word is the flag to the parser, and the mode's module is read only by the whole word.
        part = outcome(str(HERE.parent), ["--scr", "--runs", "1"], bad=False, files=mode)
        self.assertEqual((part["exit"], part["calls"]), (2, []))
        self.assertIn("--screen: write the flag whole", part["stderr"][-1])


if __name__ == "__main__":
    unittest.main()
