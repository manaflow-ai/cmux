#!/usr/bin/env python3
"""scripts/cmux-next/media/tour.py, run as the CLI against a fake app: the step shots
and the video frames come from the app's own window (`debug.window_snapshot` on its
control socket) without touching the desktop, and a snapshot error lands on the step."""

from __future__ import annotations

import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/media/tour.py"
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32

# The app: serves CMUX_NEXT_SOCKET_PATH, one request per connection, and logs
# each method. FAKE_SNAPSHOT_ERROR makes every snapshot answer with an error.
FAKE_APP = r'''#!/usr/bin/env python3
import json, os, socket, threading
path = os.environ["CMUX_NEXT_SOCKET_PATH"]
log = os.environ["FAKE_LOG"]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(8)
lock = threading.Lock()
with open(log, "a") as out:
    out.write(json.dumps({"method": "_launch", "params": {"no_activate": os.environ.get("CMUX_NEXT_NO_ACTIVATE")}}) + "\n")
def answer(connection):
    with connection:
        data = b""
        while not data.endswith(b"\n"):
            chunk = connection.recv(65536)
            if not chunk:
                return
            data += chunk
        request = json.loads(data)
        method, params = request["method"], request.get("params") or {}
        with lock, open(log, "a") as out:
            out.write(json.dumps({"method": method, "params": params}) + "\n")
        if method == "debug.layers":
            result = {"windows": [{"frame": [100, 100, 800, 600]}]}
        elif method == "debug.window_snapshot" and os.environ.get("FAKE_SNAPSHOT_ERROR"):
            result = {"error": os.environ["FAKE_SNAPSHOT_ERROR"]}
        elif method == "debug.window_snapshot":
            with open(params["path"], "wb") as image:
                image.write(b"\x89PNG\r\n\x1a\n" + b"0" * 32)
            result = {"path": params["path"], "width": 1600, "height": 1200, "method": "composited"}
        else:
            connection.sendall(json.dumps({"id": 1, "ok": False, "error": "unknown method"}).encode() + b"\n")
            return
        connection.sendall(json.dumps({"id": 1, "ok": True, "result": result}).encode() + b"\n")
while True:
    connection, _ = server.accept()
    threading.Thread(target=answer, args=(connection,), daemon=True).start()
'''

# The bundled CLI: answers ping and identify, and accepts every step.
FAKE_CLI = r'''#!/usr/bin/env python3
import json, sys
if "identify" in sys.argv:
    print(json.dumps({"app": "cmux-next", "version": "0.0.0", "build": "1", "bundle_id": "dev.cmux.test"}))
if __import__("os").environ.get("FAKE_CLI_FAIL") and any(
    word in {"unsupported", "required"} for word in sys.argv
):
    raise SystemExit(1)
'''

# macOS tools the tour runs: the console user is root (no `launchctl asuser`),
# pkill finds nothing, and sips "converts" by copying.
FAKE_TOOLS = {
    "stat": "#!/bin/sh\necho root\n",
    "pkill": "#!/bin/sh\nexit 1\n",
    "osascript": "#!/bin/sh\necho \"$*\" >> \"$FAKE_LOG.osascript\"\n",
    "sips": "#!/bin/sh\n# sips -s format jpeg IN --out OUT\ncp \"$4\" \"$6\"\n",
}


# A screen route through a prefix, the way `launchctl asuser` runs commands:
# osascript finds the app's window as id 4242 and screencapture writes an
# image, logging its arguments to FAKE_CAPTURES.
FAKE_ROUTE = r'''#!/bin/sh
case "$1" in
  osascript) echo 4242 ;;
  /usr/sbin/screencapture) shift; echo "$*" >> "$FAKE_CAPTURES"; for last; do :; done; printf 'SCREEN' > "$last" ;;
  *) exec "$@" ;;
esac
'''

# tour.py's CLI with the probe answering that the route works; on macOS the
# probe would find it by writing a display image.
ROUTE_LAUNCHER = r'''import runpy, sys
sys.path.insert(0, sys.argv[1])
import tour
route = sys.argv[2]
def probe(self, scratch):
    self.capture_prefix, self.capture_mode = [route], "direct"
tour.Session.probe_capture = probe
sys.argv = [tour.__file__] + sys.argv[3:]
sys.exit(tour.main())
'''


def executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AppWindowCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tour-test.")
        self.root = Path(self.temp.name)
        self.app = self.root / "cmux DEV test.app"
        (self.app / "Contents").mkdir(parents=True)
        with (self.app / "Contents/Info.plist").open("wb") as plist:
            plistlib.dump({"CFBundleExecutable": "fakeapp"}, plist)
        executable(self.app / "Contents/MacOS/fakeapp", FAKE_APP)
        executable(self.app / "Contents/Resources/bin/cmux", FAKE_CLI)
        for name, text in FAKE_TOOLS.items():
            executable(self.root / "bin" / name, text)
        self.log = self.root / "requests.jsonl"
        self.tour = self.root / "demo.json"
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "wait": 1.2},
            {"title": "Split right", "cmux": ["action", "run", "splitRight"], "wait": 1.2},
        ]}), encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_tour(self, screen_route: bool = False, **extra: str) -> tuple[subprocess.CompletedProcess, dict]:
        env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
        env.update(PATH=f"{self.root / 'bin'}{os.pathsep}{env.get('PATH', '')}", FAKE_LOG=str(self.log), **extra)
        out = self.root / "out"
        argv = [sys.executable, str(SCRIPT)]
        if screen_route:
            route, launcher = self.root / "route", self.root / "launch.py"
            executable(route, FAKE_ROUTE)
            launcher.write_text(ROUTE_LAUNCHER, encoding="utf-8")
            argv = [sys.executable, str(launcher), str(SCRIPT.parent), str(route)]
        done = subprocess.run(argv + ["--app", str(self.app), "--out", str(out), str(self.tour)],
                              capture_output=True, text=True, timeout=120, env=env)
        manifest = json.loads((out / "demo/manifest.json").read_text(encoding="utf-8"))
        return done, manifest

    def test_shots_and_frames_come_from_the_app_window(self) -> None:
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["result"], "pass")
        self.assertEqual(manifest["capture_mode"], "app window (debug.window_snapshot)")
        out = self.root / "out/demo"
        for step in manifest["steps"]:
            self.assertNotIn("shot_error", step)
            self.assertEqual((out / step["shot"]).read_bytes(), PNG)
        self.assertNotIn("frames_error", manifest)
        self.assertGreaterEqual(len(manifest["frames"]), 2)
        for frame in manifest["frames"]:
            self.assertRegex(frame["file"], r"^frames/frame-\d{5}\.jpg$")
            self.assertTrue((out / frame["file"]).is_file())
        requests = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        snapshots = [request["params"] for request in requests if request["method"] == "debug.window_snapshot"]
        self.assertTrue(snapshots)
        self.assertTrue(all(params.get("kind") == "main" for params in snapshots))
        # No raw window image is left behind outside the published folders.
        self.assertEqual(sorted(path.name for path in out.iterdir()), ["app.log", "frames", "manifest.json", "shots"])

    def test_the_tour_never_activates_the_app(self) -> None:
        # Tours on one Mac run side by side and drive their apps through the
        # socket, so none takes focus or the key window from another.
        done, _ = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertFalse(Path(f"{self.log}.osascript").exists())
        launches = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        launches = [entry["params"] for entry in launches if entry["method"] == "_launch"]
        self.assertEqual(launches, [{"no_activate": "1"}], "the app refuses activation itself")

    def test_a_working_window_snapshot_never_probes_the_desktop(self) -> None:
        # A desktop capture shows whatever covers the window (permission
        # prompts, other jobs' windows), so it is only the fallback.
        done, _ = self.run_tour()
        self.assertIn("screen capture: app window (debug.window_snapshot)", done.stdout)
        self.assertNotIn("no screen capture route", done.stdout)

    def test_without_a_window_snapshot_the_tour_uses_a_screen_route(self) -> None:
        done, manifest = self.run_tour(screen_route=True, FAKE_SNAPSHOT_ERROR="unknown method",
                                       FAKE_CAPTURES=str(self.root / "captures.log"))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["capture_mode"], "direct")
        self.assertEqual(manifest["frame_interval"], 0.5)
        out = self.root / "out/demo"
        for step in manifest["steps"]:
            self.assertEqual(step["status"], "ok")
            self.assertEqual((out / step["shot"]).read_bytes(), b"SCREEN")
        self.assertTrue(manifest["frames"])
        # That window alone, by its window server id, never a rectangle of the
        # display: another tour's window over it on the same Mac stays out.
        self.assertEqual(manifest["capture_window"], 4242)
        captures = (self.root / "captures.log").read_text(encoding="utf-8").splitlines()
        self.assertTrue(captures)
        for argv in captures:
            self.assertIn("-l4242", argv.split())
            self.assertFalse(any(word.startswith("-R") for word in argv.split()), argv)

    def test_a_snapshot_error_is_recorded_on_each_step(self) -> None:
        _, manifest = self.run_tour(FAKE_SNAPSHOT_ERROR="no such window")
        self.assertEqual(manifest["capture_mode"], "app window (debug.window_snapshot)")
        self.assertEqual(manifest["result"], "degraded")
        for step in manifest["steps"]:
            self.assertNotIn("shot", step)
            self.assertIn("no such window", step["shot_error"])
        self.assertEqual(manifest["frames"], [])
        self.assertIn("no such window", manifest["frames_error"])

    def test_matching_rendered_state_postcondition_passes(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Split right", "cmux": ["action", "run", "splitRight"], "wait": 0,
             "expect": {"method": "debug.layers", "fields": {"windows.0.frame": [100, 100, 800, 600]}}},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["result"], "pass")
        step = manifest["steps"][0]
        self.assertEqual(step["status"], "ok")
        self.assertEqual(step["postcondition"]["status"], "passed")
        self.assertIn("matched windows.0.frame", step["postcondition"]["detail"])

    def test_required_rendered_state_mismatch_fails(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Split right", "cmux": ["action", "run", "splitRight"], "wait": 0,
             "expect": {"method": "debug.layers", "fields": {"windows.0.frame": [1, 2, 3, 4]}}},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 1)
        self.assertEqual(manifest["result"], "failed")
        step = manifest["steps"][0]
        self.assertEqual(step["status"], "failed")
        self.assertEqual(step["postcondition"]["status"], "failed")
        self.assertIn("expected [1, 2, 3, 4]", step["postcondition"]["detail"])

    def test_optional_rendered_state_mismatch_degrades(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Optional layout", "wait": 0, "optional": "layout is not ported",
             "expect": {"method": "debug.layers", "fields": {"windows.0.frame": [1, 2, 3, 4]}}},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["result"], "degraded")
        step = manifest["steps"][0]
        self.assertEqual(step["status"], "unavailable")
        self.assertEqual(step["postcondition"]["status"], "unavailable")
        self.assertIn("layout is not ported", step["detail"])

    def test_optional_failure_is_degraded_but_required_failure_is_failed(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "wait": 0},
            {"title": "Unavailable feature", "cmux": ["unsupported"], "optional": "not ported", "wait": 0},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour(FAKE_CLI_FAIL="1")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["result"], "degraded")
        self.assertEqual(manifest["steps"][1]["status"], "unavailable")

        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "wait": 0},
            {"title": "Required feature", "cmux": ["required"], "wait": 0},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour(FAKE_CLI_FAIL="1")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(manifest["result"], "failed")
        self.assertEqual(manifest["steps"][1]["status"], "failed")

    def test_a_display_step_shoots_the_screen_so_menus_show(self) -> None:
        # A menu is its own window, so the main window's snapshot leaves it
        # out; a `display` step's shot comes from the screen, cropped to the window.
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "wait": 0},
            {"title": "Profile menu", "cmux": ["action", "run", "sidebar.profileMenu"], "wait": 0,
             "display": True},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour(screen_route=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["capture_mode"], "app window (debug.window_snapshot)")
        out = self.root / "out/demo"
        launch, menu = manifest["steps"]
        self.assertEqual((out / launch["shot"]).read_bytes(), PNG)
        self.assertNotIn("shot_error", menu)
        self.assertEqual((out / menu["shot"]).read_bytes(), b"SCREEN")

    def test_display_must_be_true_or_false(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "display": "yes"},
        ]}), encoding="utf-8")
        sys.path.insert(0, str(SCRIPT.parent))
        import tour
        with self.assertRaisesRegex(tour.TourError, "`display` must be true or false"):
            tour.load_tour(self.tour)


if __name__ == "__main__":
    unittest.main()
