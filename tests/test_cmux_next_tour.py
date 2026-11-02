#!/usr/bin/env python3
"""scripts/cmux-next/media/tour.py, run as the CLI against a fake app: the step shots
and the video frames come from the app's own window (`debug.window_snapshot` on its
control socket) without touching the desktop, and a snapshot error lands on the step."""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
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
    markers = {key: os.environ[key] for key in ("CMUX_SOCKET_PATH", "CMUX_BUNDLE_ID", "CMUX_TAG", "MUX_AGENT_TOKEN_FILE")
               if key in os.environ}
    out.write(json.dumps({"method": "_markers", "params": markers}) + "\n")
    home = os.environ.get("CMUX_CAPTURE_SHELL_HOME") or ""
    zshrc = os.path.join(home, ".zshrc")
    out.write(json.dumps({"method": "_fixture", "params": {"shell_home": home,
        "zshrc": open(zshrc).read() if home and os.path.isfile(zshrc) else None}}) + "\n")
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
        elif method == "debug.fixture":
            result = {"rows": params.get("count", 0)}
        elif method == "debug.fixture_error":
            result = {"error": "no Home page in the active window"}
        elif method == "debug.window_snapshot" and os.environ.get("FAKE_SNAPSHOT_ERROR"):
            result = {"error": os.environ["FAKE_SNAPSHOT_ERROR"]}
        elif method == "debug.fixture_page":
            result = {"ok": params.get("set") != "missing", "set": params.get("set")}
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

    def test_the_app_runs_as_under_capture_with_a_fixture_prompt(self) -> None:
        # pr-media's privacy check refused every core-tour shot for the CI Mac's name in the
        # composer's machine picker and in the zsh prompt (`cmux@<host> ~ %`). Under capture
        # (CMUX_CAPTURE_SHELL_HOME) the app names the showcase Mac and its zsh reads this home.
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        try:
            import pr_media_privacy
        finally:
            sys.path.pop(0)
        done, _ = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        entries = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        [fixture] = [entry["params"] for entry in entries if entry["method"] == "_fixture"]
        self.assertTrue(Path(fixture["shell_home"]).is_absolute())
        self.assertFalse(Path(fixture["shell_home"]).is_relative_to(self.root / "out"), "never published as media")
        # What a shot shows: the machine label, and the prompt zsh draws in the tour's home (`%1~` is `~`).
        match = re.search(r"(?m)^PROMPT='([^']*)'$", fixture["zshrc"])
        self.assertIsNotNone(match, fixture["zshrc"])
        prompt = match.group(1).replace("%1~", "~").replace("%#", "%")
        self.assertNotRegex(prompt, r"%[^ ]", "no other prompt escape (%m, %n) names the host or account")
        prompt += " echo hello from the cmux-next tour"
        # "Studio Mac": AgentTabStore.showcaseMachineName, the name the app shows under capture.
        found = pr_media_privacy.findings(["Studio Mac", prompt], list(pr_media_privacy.GENERIC_PATTERNS))
        self.assertEqual(found, [])

    def test_no_other_cmux_marker_reaches_the_app(self) -> None:
        # Any of LaunchIdentity.otherCmuxMarkers makes the app drop the tour's socket and capture home
        # as another cmux's, so a tour run from an agent's terminal would show the runner's prompt again.
        done, _ = self.run_tour(MUX_AGENT_TOKEN_FILE=str(self.root / "token"))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        entries = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([entry["params"] for entry in entries if entry["method"] == "_markers"], [{}])

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
        self.assertGreater(manifest["capture_fps"], 2)
        self.assertIn("video_fallback", manifest)
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

    def test_a_shot_no_expect_checked_is_reported_unchecked(self) -> None:
        # "ok" on a shot step only says the step ran: without an `expect` nothing read the screen it
        # shows (a palette still with an empty field passed as "the command is selected", #28323).
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "wait": 0, "shot": False},
            {"title": "Unchecked shot", "cmux": ["action", "run", "splitRight"], "wait": 0},
            {"title": "Checked shot", "wait": 0,
             "expect": {"method": "debug.layers", "fields": {"windows.0.frame": [100, 100, 800, 600]}}},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["result"], "pass")
        launch, unchecked, checked = manifest["steps"]
        self.assertEqual([step["status"] for step in manifest["steps"]], ["ok", "ok", "ok"])
        self.assertEqual([step["checked"] for step in manifest["steps"]], [False, False, True])
        self.assertNotIn("shot", launch)
        self.assertIn("shot", unchecked)
        self.assertRegex(done.stdout, r"02 unchecked +Unchecked shot")
        self.assertRegex(done.stdout, r"03 ok +Checked shot")
        self.assertRegex(done.stdout, r"01 ok +Launch")

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

    def test_an_rpc_step_sends_its_request_before_the_shot(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Fixture rows", "rpc": {"method": "debug.fixture", "params": {"count": 3}}, "wait": 0},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["result"], "pass")
        step = manifest["steps"][0]
        self.assertEqual(step["status"], "ok")
        self.assertEqual(step["rpc"], "debug.fixture")
        self.assertIn('"rows": 3', step["output"])
        methods = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        sent = [m for m in methods if m["method"] == "debug.fixture"]
        self.assertEqual(sent, [{"method": "debug.fixture", "params": {"count": 3}}])
        self.assertLess(methods.index(sent[0]),
                        max(i for i, m in enumerate(methods) if m["method"] == "debug.window_snapshot"))

    def test_an_rpc_error_fails_a_required_step_and_degrades_an_optional_one(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Required", "rpc": {"method": "debug.fixture_error"}, "wait": 0},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 1)
        self.assertEqual(manifest["steps"][0]["status"], "failed")
        self.assertIn("no Home page", manifest["steps"][0]["detail"])

        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Optional", "rpc": {"method": "debug.unknown"}, "optional": "not in this build", "wait": 0},
        ]}), encoding="utf-8")
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["result"], "degraded")
        self.assertEqual(manifest["steps"][0]["status"], "unavailable")
        self.assertIn("not in this build", manifest["steps"][0]["detail"])

    def test_rpc_needs_a_method_and_object_params(self) -> None:
        sys.path.insert(0, str(SCRIPT.parent))
        import tour
        for rpc in ({"params": {}}, {"method": "debug.x", "params": []}, {"method": "debug.x", "extra": 1}, "debug.x"):
            with self.subTest(rpc=rpc):
                self.tour.write_text(json.dumps({"title": "Demo", "steps": [{"title": "Bad", "rpc": rpc}]}), encoding="utf-8")
                with self.assertRaisesRegex(tour.TourError, "`rpc` must be"):
                    tour.load_tour(self.tour)

    def test_display_must_be_true_or_false(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "display": "yes"},
        ]}), encoding="utf-8")
        sys.path.insert(0, str(SCRIPT.parent))
        import tour
        with self.assertRaisesRegex(tour.TourError, "`display` must be true or false"):
            tour.load_tour(self.tour)

    def test_an_rpc_step_sends_its_method_and_params_to_the_app(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "wait": 1.2},
            {"title": "Fixture page", "rpc": {"method": "debug.fixture_page", "params": {"set": "tabs"}}, "wait": 0.5},
        ]}), encoding="utf-8")
        _, manifest = self.run_tour()
        step = manifest["steps"][1]
        self.assertEqual(step["status"], "ok", step)
        requests = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        self.assertIn({"method": "debug.fixture_page", "params": {"set": "tabs"}}, requests)

    def test_an_rpc_step_that_answers_ok_false_fails(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "wait": 1.2},
            {"title": "Fixture page", "rpc": {"method": "debug.fixture_page", "params": {"set": "missing"}}, "wait": 0.5},
        ]}), encoding="utf-8")
        _, manifest = self.run_tour()
        step = manifest["steps"][1]
        self.assertEqual(step["status"], "failed", step)
        self.assertIn("ok: false", step["detail"])


# The app with a floating panel open: `debug.window_list` names its windows,
# and window_snapshot takes any window's number (popovers, panels, sheets).
WINDOWS = [
    {"id": 1, "kind": "main", "visible": True, "alpha": 1, "frame": {"x": 0, "y": 0, "width": 800, "height": 600}},
    {"id": 7, "kind": "chiefPet", "class": "NSPanel", "visible": True, "alpha": 1,
     "frame": {"x": 900, "y": 40, "width": 220, "height": 90}},
    {"id": 8, "kind": "panel", "visible": False, "alpha": 1, "frame": {"x": 0, "y": 0, "width": 300, "height": 200}},
    {"id": 9, "kind": "popover", "visible": True, "alpha": 1, "frame": {"x": 0, "y": 0, "width": 4, "height": 4}},
    {"id": 10, "kind": "sheet", "visible": True, "alpha": 0, "frame": {"x": 0, "y": 0, "width": 300, "height": 200}},
    {"id": 11, "kind": "quickReply", "visible": True, "alpha": 1, "frame": {"x": 10, "y": 10, "width": 360, "height": 120}},
    # Child windows the main shot already composites: the overlay panel and a Chromium page.
    {"id": 12, "kind": "panel", "class": "OverlayHostPanel", "parent": 1, "visible": True, "alpha": 1,
     "frame": {"x": 0, "y": 0, "width": 800, "height": 600}},
    {"id": 14, "kind": "NSWindow", "parent": 1, "visible": True, "alpha": 1,
     "frame": {"x": 0, "y": 0, "width": 600, "height": 400}},
    # A sheet is not composited into its parent's shot.
    {"id": 13, "kind": "sheet", "parent": 1, "visible": True, "alpha": 1,
     "frame": {"x": 200, "y": 100, "width": 400, "height": 300}},
]
WINDOW_LIST = (
    '        if method == "debug.window_list":\n'
    '            result = {"windows": json.loads(os.environ["FAKE_WINDOWS"])}\n'
    '        elif method == "debug.layers":\n'
)


class EveryWindowCaptureTests(AppWindowCaptureTests):
    """A step shoots the main window and every other visible window of the app (floating
    panels, popovers, sheets), so a panel outside the main window is in the media."""

    def setUp(self) -> None:
        super().setUp()
        executable(self.app / "Contents/MacOS/fakeapp",
                   FAKE_APP.replace('        if method == "debug.layers":\n', WINDOW_LIST, 1))

    def run_tour(self, screen_route: bool = False, **extra: str):
        extra.setdefault("FAKE_WINDOWS", json.dumps(WINDOWS))
        return super().run_tour(screen_route, **extra)

    def test_shots_and_frames_come_from_the_app_window(self) -> None:
        # The main window's frames and shots are unchanged; the panels add images beside them.
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        out = self.root / "out/demo"
        for step in manifest["steps"]:
            self.assertRegex(step["shot"], r"^shots/\d{2}-[a-z0-9-]+\.png$")
            stem = step["shot"][: -len(".png")]
            self.assertEqual(step["windows"], [
                {"id": 7, "kind": "chiefPet", "shot": f"{stem}--w7.png"},
                {"id": 11, "kind": "quickReply", "shot": f"{stem}--w11.png"},
                {"id": 13, "kind": "sheet", "shot": f"{stem}--w13.png"},
            ])
            for window in step["windows"]:
                self.assertEqual((out / window["shot"]).read_bytes(), PNG)
        requests = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        numbered = {request["params"].get("window") for request in requests
                    if request["method"] == "debug.window_snapshot" and "window" in request["params"]}
        self.assertEqual(numbered, {7, 11, 13})

    def test_an_app_without_a_window_list_shoots_the_main_window_only(self) -> None:
        executable(self.app / "Contents/MacOS/fakeapp", FAKE_APP)
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(manifest["result"], "pass")
        for step in manifest["steps"]:
            self.assertNotIn("windows", step)
            self.assertNotIn("windows_error", step)

    def test_a_step_can_skip_the_other_windows(self) -> None:
        self.tour.write_text(json.dumps({"title": "Demo", "steps": [
            {"title": "Launch", "wait": 0, "windows": False}]}), encoding="utf-8")
        _, manifest = self.run_tour()
        self.assertNotIn("windows", manifest["steps"][0])



# The bundled CLI for --stop: logs its argv, one line per call.
LOGGING_CLI = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_LOG"], "a") as out:
    out.write(json.dumps(sys.argv[1:]) + "\n")
'''

# tour.py's CLI with a short SIGKILL grace, so a process that ignores SIGTERM costs a second.
STOP_LAUNCHER = r'''import sys
sys.path.insert(0, sys.argv[1])
import tour
tour.STOP_GRACE = 1.0
sys.exit(tour.main(sys.argv[2:]))
'''


class StopTests(unittest.TestCase):
    """--stop ends what a built app left running: its tagged daemon through the CLI, then every process whose
    executable is in the bundle (run 39199091515's chief host and acpmux daemon held cmux10s's DerivedData
    open for days), and nothing that only names the bundle in its arguments."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tour-stop-test.")
        self.root = Path(self.temp.name)
        self.log = self.root / "cli.jsonl"
        executable(self.root / "bin/stat", FAKE_TOOLS["stat"])
        self.launcher = self.root / "stop.py"
        self.launcher.write_text(STOP_LAUNCHER, encoding="utf-8")
        self.processes: list[subprocess.Popen] = []

    def tearDown(self) -> None:
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait()
        self.temp.cleanup()

    def bundle(self, path: Path, tag: str) -> Path:
        (path / "Contents").mkdir(parents=True)
        with (path / "Contents/Info.plist").open("wb") as plist:
            plistlib.dump({"CFBundleExecutable": "fakeapp", "LSEnvironment": {"CMUX_TAG": tag}}, plist)
        executable(path / "Contents/MacOS/fakeapp", "#!/bin/sh\nexit 0\n")
        executable(path / "Contents/Resources/bin/cmux", LOGGING_CLI)
        return path

    def start(self, argv: list[str], ignore_term: bool = False) -> subprocess.Popen:
        # An ignored SIGTERM survives exec, so `sleep` then needs SIGKILL.
        ignore = (lambda: signal.signal(signal.SIGTERM, signal.SIG_IGN)) if ignore_term else None
        process = subprocess.Popen(argv, start_new_session=True, preexec_fn=ignore)
        self.processes.append(process)
        return process

    def run_from(self, bundle: Path, name: str, ignore_term: bool = False) -> subprocess.Popen:
        """`sleep` started from inside the bundle, as the app starts the chief host: the command starts with
        the bundle's path. (A link, since macOS kills a copied system binary.)"""
        link = bundle / "Contents/Resources/bin" / name
        link.symlink_to(shutil.which("sleep"))
        return self.start([str(link), "600"], ignore_term)

    def leftovers(self, bundle: Path) -> tuple[subprocess.Popen, subprocess.Popen, subprocess.Popen]:
        chief = self.run_from(bundle, "optchat-chief")
        stubborn = self.run_from(bundle, "acpmux", ignore_term=True)
        bystander = self.start(["/bin/sh", "-c", f"sleep 600; : '{bundle}/Contents/Resources/bin/optchat-chief'"])
        time.sleep(0.5)
        self.assertTrue(all(process.poll() is None for process in (chief, stubborn, bystander)))
        return chief, stubborn, bystander

    def environment(self) -> dict[str, str]:
        env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
        env.update(PATH=f"{self.root / 'bin'}{os.pathsep}{env.get('PATH', '')}", FAKE_LOG=str(self.log))
        return env

    def stop(self, *bundles: Path) -> subprocess.CompletedProcess:
        argv = [sys.executable, str(self.launcher), str(SCRIPT.parent)]
        for bundle in bundles:
            argv += ["--stop", str(bundle)]
        return subprocess.run(argv, capture_output=True, text=True, timeout=120, env=self.environment())

    def calls(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def test_it_ends_the_daemon_and_everything_run_from_the_bundle(self) -> None:
        bundle = self.bundle(self.root / "cmux DEV ci-media-slot0-head.app", "ci-media-slot0-head")
        chief, stubborn, bystander = self.leftovers(bundle)
        done = self.stop(bundle)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn(["--session", "cmux-app-ci-media-slot0-head", "server", "stop", "--end-terminals"],
                      self.calls())
        self.assertIsNotNone(chief.poll(), "the chief host is still running")
        self.assertIsNotNone(stubborn.poll(), "a process that ignores SIGTERM is still running")
        self.assertIsNone(bystander.poll(), "a process that only names the bundle was ended")
        self.assertIn("nothing left running", done.stdout)

    def test_it_stops_every_bundle_it_is_given(self) -> None:
        base = self.bundle(self.root / "base/cmux DEV ci-media-slot0-base.app", "ci-media-slot0-base")
        head = self.bundle(self.root / "head/cmux DEV ci-media-slot0-head.app", "ci-media-slot0-head")
        left = [self.run_from(base, "optchat-chief"),
                self.run_from(head, "optchat-chief")]
        done = self.stop(base, head)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue(all(process.poll() is not None for process in left), done.stdout)
        sessions = [call[1] for call in self.calls() if call[:1] == ["--session"]]
        self.assertEqual(sessions, ["cmux-app-ci-media-slot0-base", "cmux-app-ci-media-slot0-head"])

    def test_a_bundle_without_its_cli_still_has_its_processes_ended(self) -> None:
        bundle = self.bundle(self.root / "cmux DEV ci-media-slot1-head.app", "ci-media-slot1-head")
        chief = self.run_from(bundle, "optchat-chief")
        (bundle / "Contents/Resources/bin/cmux").unlink()
        done = self.stop(bundle)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIsNotNone(chief.poll())

    def test_a_missing_app_is_nothing_to_stop(self) -> None:
        done = self.stop(self.root / "never built.app")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("nothing to stop", done.stdout)

    def test_tours_or_stop_are_required(self) -> None:
        done = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 2)

    def test_the_tour_job_stops_both_apps_whatever_happened(self) -> None:
        import yaml

        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-media.yml").read_text(encoding="utf-8"))
        steps = workflow["jobs"]["tour"]["steps"]
        names = [step.get("name") for step in steps]
        self.assertIn("Stop this tour's apps and daemons", names)
        index = names.index("Stop this tour's apps and daemons")
        step = steps[index]
        self.assertGreater(index, names.index("Capture before and after interactions"))
        self.assertLess(index, names.index("Keep the media for the publish job"))
        self.assertIn("always()", step["if"])
        self.assertTrue(step.get("continue-on-error"))
        home = self.root / "home"
        apps = home / "Library/Developer/Xcode/DerivedData"
        base = self.bundle(apps / "cmux-ci-media-slot0-base/Build/Products/Debug/cmux DEV ci-media-slot0-base.app",
                           "ci-media-slot0-base")
        head = self.bundle(apps / "cmux-ci-media-slot0-head/Build/Products/Debug/cmux DEV ci-media-slot0-head.app",
                           "ci-media-slot0-head")
        other = self.bundle(apps / "cmux-ci-media-slot1-head/Build/Products/Debug/cmux DEV ci-media-slot1-head.app",
                            "ci-media-slot1-head")
        mine = [self.run_from(base, "optchat-chief"),
                self.run_from(head, "optchat-chief")]
        theirs = self.run_from(other, "optchat-chief")
        env = dict(self.environment(), HOME=str(home), TOUR_TAG="ci-media-slot0", RUNNER_TEMP=str(self.root),
                   GITHUB_SHA="0" * 40)
        done = subprocess.run(["bash", "-c", step["run"]], cwd=ROOT, env=env, capture_output=True, text=True,
                              timeout=120)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue(all(process.poll() is not None for process in mine), done.stdout + done.stderr)
        self.assertIsNone(theirs.poll(), "another slot's app was ended")


class CheckedInToursTests(unittest.TestCase):
    """Every tour under scripts/cmux-next/media/tours loads: one bad file (a step key tour.py does not
    know, as #26274's "record" was) stops every pull request's tour before it starts, since the
    runner checks them all."""

    def test_every_checked_in_tour_loads(self) -> None:
        sys.path.insert(0, str(SCRIPT.parent))
        import tour
        tours = sorted((SCRIPT.parent / "tours").glob("*.json"))
        self.assertTrue(tours)
        for path in tours:
            with self.subTest(tour=path.name):
                tour.load_tour(path)


class FocusAfterCloseTests(unittest.TestCase):
    """A directional focus right after a pane close is refused at load: the close already focused a
    neighbour, and with one pane left the move fails ("no pane left of the focused pane") and fails
    the whole capture, as the main-pane tour's "Focus the chat" did on #27839."""

    def setUp(self) -> None:
        sys.path.insert(0, str(SCRIPT.parent))
        import tour
        self.tour_module = tour
        self.scratch = Path(tempfile.mkdtemp(prefix="tour-focus-close-"))
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)

    def load(self, steps: list[dict]) -> dict:
        path = self.scratch / "demo.json"
        path.write_text(json.dumps({"title": "Demo", "steps": steps}), encoding="utf-8")
        return self.tour_module.load_tour(path)

    @staticmethod
    def run_action(action: str) -> dict:
        return {"title": action, "cmux": ["action", "run", action], "shot": False}

    def test_a_directional_focus_right_after_a_close_is_refused(self) -> None:
        for focus in ("focusLeft", "focusRight", "focusUp", "focusDown"):
            with self.subTest(focus=focus), self.assertRaisesRegex(self.tour_module.TourError, "step 3 runs " + focus):
                self.load([{"title": "Launch"}, self.run_action("closePane"), self.run_action(focus)])

    def test_steps_that_open_no_pane_do_not_hide_the_close(self) -> None:
        tunable = {"title": "Tunable", "rpc": {"method": "debug.tunables", "params": {"key": "x", "value": "off"}}}
        setting = {"title": "Setting", "cmux": ["settings", "set", "sidebar.density", "compact"]}
        with self.assertRaisesRegex(self.tour_module.TourError, "step 5 runs focusLeft after closePane"):
            self.load([self.run_action("closePane"), tunable, setting, {"title": "Wait", "wait": 1},
                       self.run_action("focusLeft")])

    def test_other_focus_moves_do_not_hide_the_close(self) -> None:
        for move in ("focusPaneByNumber", "focusNextPane", "focusPreviousPane", "pane.focus",
                     "column.focusLeft", "focusHistoryBack"):
            with self.subTest(move=move), self.assertRaisesRegex(
                    self.tour_module.TourError, "step 3 runs focusLeft after closePane"):
                self.load([self.run_action("closePane"), self.run_action(move), self.run_action("focusLeft")])

    def test_a_pane_opened_after_the_close_allows_the_focus(self) -> None:
        link = {"title": "Link", "rpc": {"method": "debug.terminal.links", "params": {"agentLink": "https://example.com"}}}
        self.load([self.run_action("closePane"), link, self.run_action("focusLeft")])
        self.load([self.run_action("closePane"), self.run_action("splitRight"), self.run_action("focusLeft")])
        self.load([self.run_action("focusRight"), self.run_action("closePane"), self.run_action("focusPaneByNumber")])



class WindowVideoTests(unittest.TestCase):
    def test_compiler_failure_selects_the_still_fallback(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import tour
        with tempfile.TemporaryDirectory() as root:
            recording = tour.WindowVideo(mock.Mock(), 123, Path(root), Path(root))
            with mock.patch.object(tour.sys, "platform", "darwin"), \
                    mock.patch.object(tour.subprocess, "run", return_value=mock.Mock(returncode=1, stderr="SDK unavailable")):
                self.assertFalse(recording.start())
            self.assertIn("SDK unavailable", recording.reason)
            self.assertIsNone(recording.process)

    def test_failed_native_start_records_stills_with_measured_timing(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import tour
        with tempfile.TemporaryDirectory() as root:
            session = mock.Mock(prefix=[], capture_prefix=[], user="test")
            session.shareable.side_effect = lambda path: (path.mkdir(parents=True, exist_ok=True) or path)
            app = mock.Mock(identity={}, log_path=Path(root) / "absent")
            app.main_window_frame.return_value = [0, 0, 800, 600]
            native = mock.Mock(reason="SDK unavailable")
            native.start.return_value = False
            native.stop.return_value = False
            def step(*args):
                time.sleep(0.1)
                return {"status": "ok"}
            with mock.patch.object(tour, "App", return_value=app), \
                    mock.patch.object(tour, "WindowVideo", return_value=native), \
                    mock.patch.object(tour.Screen, "capture", return_value=None), \
                    mock.patch.object(tour, "run_step", side_effect=step), \
                    mock.patch.object(tour.signal, "signal"):
                manifest = tour.run_tour(Path(root), {"name": "demo", "title": "Demo", "steps": [{"title": "Animate"}]},
                                         Path(root), session)
            self.assertNotIn("video", manifest)
            self.assertEqual(manifest["video_fallback"], "SDK unavailable")
            self.assertGreaterEqual(len(manifest["frames"]), 2)
            self.assertGreater(manifest["capture_fps"], 2)
            self.assertAlmostEqual(manifest["frame_interval"], 1 / manifest["capture_fps"])

    def test_native_capture_stops_and_finalizes_before_the_app(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import tour
        events = []
        with tempfile.TemporaryDirectory() as root:
            session = mock.Mock(prefix=[], capture_prefix=[], user="test")
            session.shareable.side_effect = lambda path: (path.mkdir(parents=True, exist_ok=True) or path)
            app = mock.Mock(identity={}, log_path=Path(root) / "absent")
            app.main_window_frame.return_value = [0, 0, 800, 600]
            app.stop.side_effect = lambda: events.append("app-stop")
            native = mock.Mock(reason="")
            native.start.return_value = True
            native.stop.side_effect = lambda: (events.append("video-stop") or True)
            with mock.patch.object(tour, "App", return_value=app), \
                    mock.patch.object(tour, "WindowVideo", return_value=native), \
                    mock.patch.object(tour.Screen, "capture", return_value=None), \
                    mock.patch.object(tour, "run_step", return_value={"status": "ok"}), \
                    mock.patch.object(tour.signal, "signal"), \
                    mock.patch.object(tour.Recorder, "start") as stills:
                manifest = tour.run_tour(Path(root), {"name": "demo", "title": "Demo", "steps": [{"title": "Animate"}]},
                                         Path(root), session)
            self.assertEqual(manifest["video"], "capture.mov")
            self.assertEqual(events, ["video-stop", "app-stop"])
            stills.assert_not_called()

    def test_stop_times_out_and_kills_only_the_owned_recorder(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import tour as video
        with tempfile.TemporaryDirectory() as root:
            recording = video.WindowVideo(mock.Mock(), 123, Path(root), Path(root))
            process = mock.Mock(returncode=-9)
            process.communicate.side_effect = [subprocess.TimeoutExpired("recorder", 20), ("", "")]
            recording.process = process
            self.assertFalse(recording.stop())
            process.kill.assert_called_once_with()
            self.assertIsNone(recording.process)

if __name__ == "__main__":
    unittest.main()
