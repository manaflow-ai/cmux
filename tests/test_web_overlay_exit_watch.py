#!/usr/bin/env python3
"""A dev server that exits on its own sends the app back to its shipped web UI (cmux live).

`web-overlay.sh server --local` left web-dev.json naming a server that had crashed, so every page
the app opened asked a dead port first and a page loaded from it before stayed half there. Now a
watch beside the server clears `server` when it exits without `server off` (the app reloads its
pages from the shipped files) and writes `dev-server.exit` for `cmux live status`; `server off`
ends the watch with the server and leaves no such note. A fake `bun` stands in for the dev server.
"""

import fcntl
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
if sys.argv[1:2] == ["install"] and os.path.exists(os.environ["FAKE_BUN_FAIL"]):
    sys.exit(1)  # an install that fails
if sys.argv[1:3] == ["run", "dev"] and os.path.exists(os.environ["FAKE_BUN_FAIL"]):
    import time; time.sleep(float(open(os.environ["FAKE_BUN_FAIL"]).read() or 0))
    sys.exit(1)  # a server that dies before it serves
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
            "FAKE_BUN_FAIL": str(self.tmp / "fail"),
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
        self.assertIn(f"it served port {self.port}", note)
        self.assertFalse((self.state / "dev-server.pid").exists())
        self.assertTrue(self.wait_for(lambda: not self.group_alive()), "the watch ends with the server")

    def test_server_off_stops_the_watch_and_leaves_no_note(self):
        self.start()
        self.run_script("server", "off")
        # The watch runs in the server's process group, so once the group is gone nothing is left
        # that could write a note or web-dev.json.
        self.assertTrue(self.wait_for(lambda: not self.group_alive()))
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

    def test_a_pick_made_while_the_watch_waits_for_the_lock_is_kept(self):
        # The watch checks that web-dev.json still names its server and clears it in one locked
        # update, so a pick written in between (`server URL`, another start) is never lost.
        self.start()
        with open(self.web_dev.parent / ".web-dev.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            os.kill(int((self.tmp / "child.pid").read_text()), signal.SIGKILL)
            # The watch saw the exit: it drops the pid file just before its locked write, which
            # now waits on this lock.
            self.assertTrue(self.wait_for(lambda: not (self.state / "dev-server.pid").exists()))
            data = json.loads(self.web_dev.read_text())
            self.assertIn("server", data, "the watch wrote web-dev.json while another writer held it")
            data.update(server="http://127.0.0.1:1/", token="b" * 48)
            self.web_dev.write_text(json.dumps(data))
        # The watch and its locked write run in the server's group: a gone group has finished writing.
        self.assertTrue(self.wait_for(lambda: not self.group_alive()))
        self.assertEqual(json.loads(self.web_dev.read_text())["server"], "http://127.0.0.1:1/")
        self.assertFalse((self.state / "dev-server.exit").exists())

    def test_a_replacement_that_does_not_start_leaves_no_dead_pick(self):
        # The new server dies before it is picked: web-dev.json must not keep naming the old one,
        # which the new start stopped.
        self.start()
        old_group = self.group
        (self.tmp / "fail").write_text("")
        other = free_port()
        result = subprocess.run(["bash", str(SCRIPT), "server", "--local", "--worktree", str(self.tree), "--port", str(other)],
                                env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        self.assertNotEqual(result.returncode, 0)
        self.group = old_group
        self.assertNotIn("server", json.loads(self.web_dev.read_text()))
        self.assertIn(f"did not start on port {other}", (self.state / "dev-server.exit").read_text())

    def test_a_failed_start_keeps_a_pick_made_while_it_waited(self):
        # Start A stops the old server and waits; meanwhile start B picks its own server (a new
        # token). A's failure clears only the pick it stopped, never B's.
        self.start()
        old_group = self.group
        (self.tmp / "fail").write_text("3")
        other = free_port()
        a = subprocess.Popen(["bash", str(SCRIPT), "server", "--local", "--worktree", str(self.tree), "--port", str(other)],
                             env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        self.assertTrue(self.wait_for(lambda: not self.group_alive_of(old_group)))
        data = json.loads(self.web_dev.read_text())
        data.update(server="http://127.0.0.1:2/", token="c" * 48)  # B's point_at
        self.web_dev.write_text(json.dumps(data))
        (self.state / "dev-server.token").write_text("c" * 48 + "\n")
        self.assertNotEqual(a.wait(timeout=120), 0)
        self.group = old_group
        self.assertEqual(json.loads(self.web_dev.read_text())["server"], "http://127.0.0.1:2/")

    def test_a_failed_install_leaves_no_dead_pick(self):
        self.start()
        old_group = self.group
        (self.tmp / "fail").write_text("")
        other_tree = self.tmp / "tree2"
        (other_tree / "webviews").mkdir(parents=True)  # no node_modules: the start installs
        (other_tree / "webviews/package.json").write_text("{}\n")
        result = subprocess.run(["bash", str(SCRIPT), "server", "--local", "--worktree", str(other_tree), "--port", str(free_port())],
                                env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        self.assertNotEqual(result.returncode, 0)
        self.group = old_group
        self.assertNotIn("server", json.loads(self.web_dev.read_text()))
        self.assertIn("did not start", (self.state / "dev-server.exit").read_text())

    def group_alive_of(self, group: int) -> bool:
        try:
            os.killpg(group, 0)
            return True
        except ProcessLookupError:
            return False


if __name__ == "__main__":
    unittest.main()
