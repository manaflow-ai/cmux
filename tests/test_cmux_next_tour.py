#!/usr/bin/env python3
"""scripts/cmux-next/media/tour.py, run as the CLI against a fake app: with no screen
capture route, the step shots and the video frames come from the app's own window
(`debug.window_snapshot` on its control socket), and a snapshot error lands on the step."""

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
    print(json.dumps({"app": "cmux-next", "version": "0.0.0", "build": "1"}))
'''

# macOS tools the tour runs: the console user is root (no `launchctl asuser`),
# pkill finds nothing, and sips "converts" by copying.
FAKE_TOOLS = {
    "stat": "#!/bin/sh\necho root\n",
    "pkill": "#!/bin/sh\nexit 1\n",
    "sips": "#!/bin/sh\n# sips -s format jpeg IN --out OUT\ncp \"$4\" \"$6\"\n",
}


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

    def run_tour(self, **extra: str) -> tuple[subprocess.CompletedProcess, dict]:
        env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
        env.update(PATH=f"{self.root / 'bin'}{os.pathsep}{env.get('PATH', '')}", FAKE_LOG=str(self.log), **extra)
        out = self.root / "out"
        done = subprocess.run([sys.executable, str(SCRIPT), "--app", str(self.app), "--out", str(out), str(self.tour)],
                              capture_output=True, text=True, timeout=120, env=env)
        manifest = json.loads((out / "demo/manifest.json").read_text(encoding="utf-8"))
        return done, manifest

    def test_shots_and_frames_come_from_the_app_window(self) -> None:
        done, manifest = self.run_tour()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
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

    def test_a_snapshot_error_is_recorded_on_each_step(self) -> None:
        _, manifest = self.run_tour(FAKE_SNAPSHOT_ERROR="no such window")
        self.assertEqual(manifest["capture_mode"], "app window (debug.window_snapshot)")
        for step in manifest["steps"]:
            self.assertNotIn("shot", step)
            self.assertIn("no such window", step["shot_error"])
        self.assertEqual(manifest["frames"], [])
        self.assertIn("no such window", manifest["frames_error"])


if __name__ == "__main__":
    unittest.main()
