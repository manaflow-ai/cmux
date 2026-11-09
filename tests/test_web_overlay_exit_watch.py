#!/usr/bin/env python3
"""A dev server that exits on its own sends the app back to its shipped web UI (cmux live).

`web-overlay.sh server --local` left web-dev.json naming a server that had crashed, so every page
the app opened asked a dead port first and a page loaded from it before stayed half there. Now a
watch beside the server clears `server` when it exits without `server off` (the app reloads its
pages from the shipped files) and writes `dev-server.exit` for `cmux live status`; `server off`
ends the watch with the server and leaves no such note. A fake `bun` stands in for the dev server.
"""

import json
import os
import shutil
import signal
import socket
import sys
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/web-overlay.sh"

# `bun run dev` serves agent-pane/index.html on CMUX_WEBVIEWS_DEV_PORT until its server child exits;
# every other bun command (gen-strings) does nothing. It names itself `bun` (prctl), as web-overlay.sh
# checks the program behind its pid file.
FAKE_BUN = """#!/usr/bin/env python3
import ctypes, os, subprocess, sys
ctypes.CDLL(None).prctl(15, b"bun", 0, 0, 0)
if sys.argv[1:3] == ["run", "dev"]:
    os.makedirs("agent-pane", exist_ok=True)
    open("agent-pane/index.html", "w").write("<!doctype html>")
    child = subprocess.Popen([sys.executable, "-m", "http.server", "--bind", "127.0.0.1", os.environ["CMUX_WEBVIEWS_DEV_PORT"]],
                             stderr=subprocess.DEVNULL)
    open(os.environ["FAKE_BUN_CHILD"], "w").write(str(child.pid))
    child.wait()
"""


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@unittest.skipUnless(sys.platform == "linux" and shutil.which("lsof"), "the fake bun names itself with prctl; web-overlay.sh checks the listener with lsof")
class WebOverlayExitWatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="web-overlay-exit-"))
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "bun").write_text(FAKE_BUN)
        (bin_dir / "bun").chmod(0o755)
        self.tree = self.tmp / "tree"
        (self.tree / "webviews/node_modules").mkdir(parents=True)
        (self.tree / "webviews/package.json").write_text("{}\n")
        self.state = self.tmp / "state"
        self.web_dev = self.tmp / "config/web-dev.json"
        self.port = free_port()
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "HOME": str(self.tmp / "home"),
            "CMUX_NEXT_CONFIG_FILE": str(self.tmp / "config/cmux-next.json"),
            "CMUX_WEB_SLOT_STATE_DIR": str(self.state),
            "FAKE_BUN_CHILD": str(self.tmp / "child.pid"),
        }
        self.group = None

    def tearDown(self):
        if self.group:
            try:
                os.killpg(self.group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *args: str) -> None:
        subprocess.run(["bash", str(SCRIPT), *args], env=self.env, check=True, capture_output=True, text=True,
                       stdin=subprocess.DEVNULL, timeout=90)

    def start(self) -> None:
        self.run_script("server", "--local", "--worktree", str(self.tree), "--port", str(self.port))
        self.group = int((self.state / "dev-server.pid").read_text())
        self.assertEqual(json.loads(self.web_dev.read_text())["server"], f"http://127.0.0.1:{self.port}/")

    def group_alive(self) -> bool:
        try:
            os.killpg(self.group, 0)
            return True
        except ProcessLookupError:
            return False

    def wait_for(self, done, seconds: float = 15) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if done():
                return True
            time.sleep(0.1)
        return done()

    def test_a_server_that_exits_on_its_own_sends_the_app_back_to_its_shipped_web_ui(self):
        self.start()
        os.kill(int((self.tmp / "child.pid").read_text()), signal.SIGKILL)  # the server crashes
        self.assertTrue(self.wait_for(lambda: "server" not in json.loads(self.web_dev.read_text())))
        note = (self.state / "dev-server.exit").read_text()
        self.assertIn(f"port {self.port} stopped on its own", note)
        self.assertFalse((self.state / "dev-server.pid").exists())
        self.assertTrue(self.wait_for(lambda: not self.group_alive()), "the watch ends with the server")

    def test_server_off_stops_the_watch_and_leaves_no_note(self):
        self.start()
        self.run_script("server", "off")
        self.assertTrue(self.wait_for(lambda: not self.group_alive()))
        time.sleep(2.5)  # one watch interval: nothing writes after the stop
        self.assertFalse((self.state / "dev-server.exit").exists())
        self.assertNotIn("server", json.loads(self.web_dev.read_text()))

    def test_a_server_picked_since_is_not_cleared(self):
        # A server picked with `server URL` after this one started keeps its pick when this one exits.
        self.start()
        self.run_script("server", "http://127.0.0.1:1/")
        os.kill(int((self.tmp / "child.pid").read_text()), signal.SIGKILL)
        self.assertTrue(self.wait_for(lambda: not self.group_alive()))
        self.assertEqual(json.loads(self.web_dev.read_text())["server"], "http://127.0.0.1:1/")
        self.assertFalse((self.state / "dev-server.exit").exists())

    def test_a_new_start_clears_the_last_exit_note(self):
        self.start()
        os.kill(int((self.tmp / "child.pid").read_text()), signal.SIGKILL)
        self.assertTrue(self.wait_for(lambda: (self.state / "dev-server.exit").exists()))
        self.start()
        self.assertFalse((self.state / "dev-server.exit").exists())


if __name__ == "__main__":
    unittest.main()
