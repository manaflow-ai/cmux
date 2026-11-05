#!/usr/bin/env python3
"""scripts/live-code/live-mode.py: the parts that need no app build.

A fake control socket answers like a tagged app (system.identify, snapshot.get), so these check
the NIGHTLY refusal, the status line, the session comparison across a restart, the commit match,
the bundle swap's renames and the patch count from the live folder's log.

  python3 tests/test_live_mode.py
"""
import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("live_mode", ROOT / "scripts/live-code/live-mode.py")
live_mode = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(live_mode)


class FakeApp:
    """A unix socket answering one JSON line per connection from `answers` by method."""

    def __init__(self, path, answers):
        self.path, self.answers = path, answers
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
                return
            with conn:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                request = json.loads(data)
                result = self.answers.get(request["method"], {})
                conn.sendall((json.dumps({"id": request["id"], "result": result}) + "\n").encode())

    def close(self):
        self.server.close()


def topology(workspaces):
    """`snapshot.get`'s topology: {workspace: [(tab, terminal, dead)]}."""
    return {"loaded": True, "workspaces": [
        {"id": ws, "screens": [{"panes": [{"tabs": [{"id": t, "terminal": term, "dead": dead} for t, term, dead in tabs]}]}]}
        for ws, tabs in workspaces.items()]}


class LiveModeTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="lm-", dir="/tmp")  # a unix socket path stays short
        self.home = Path(self.dir) / "home"
        self.home.mkdir()
        self.old_home = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)
        self.apps = []

    def tearDown(self):
        for app in self.apps:
            app.close()
        if self.old_home is not None:
            os.environ["HOME"] = self.old_home

    def fake(self, answers):
        path = os.path.join(self.dir, "s.sock")
        self.apps.append(FakeApp(path, answers))
        return path

    def bundle(self, name, executable="cmux"):
        app = Path(self.dir) / name
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS" / executable).write_text(name)
        import plistlib
        with open(app / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleExecutable": executable, "CMUXCommit": "abcdef1234567890"}, f)
        return app

    def test_slug_matches_reload_sh(self):
        self.assertEqual(live_mode.slug("My Tag_2"), "my-tag-2")
        self.assertEqual(live_mode.slug("--x--y--"), "x-y")

    def test_same_commit_takes_full_or_abbreviated_names(self):
        self.assertTrue(live_mode.same_commit("abcdef1", "abcdef1234567890"))
        self.assertFalse(live_mode.same_commit("abcdef2", "abcdef1234567890"))
        self.assertFalse(live_mode.same_commit("abc", "abcdef1234567890"))  # too short to name one
        self.assertFalse(live_mode.same_commit("", "abcdef1234567890"))

    def test_a_nightly_is_refused_with_what_it_can_and_cannot_do(self):
        path = self.fake({"system.ping": {}, "system.identify": {
            "bundle_id": "com.cmuxterm.app.nightly-next", "app_bundle_path": "/Applications/cmux NIGHTLY.app", "pid": 1}})
        with self.assertRaises(live_mode.Refused) as refused:
            live_mode.identify(path)
        text = str(refused.exception)
        self.assertIn("tagged DEV build", text)
        self.assertIn("cmux#13742", text)
        self.assertIn("try-pr.sh", text)

    def test_sessions_kept_counts_workspaces_tabs_and_running_terminals(self):
        before = live_mode.topology_sessions(topology({"ws_1": [("tab_1", "term_1", False), ("tab_2", "term_2", False)]}))
        same = live_mode.topology_sessions(topology({"ws_1": [("tab_1", "term_1", False), ("tab_2", "term_2", False)]}))
        self.assertEqual(live_mode.kept(before, same),
                         {"workspaces": "1/1", "tabs": "2/2", "terminals": "2/2", "all": True, "lost": []})
        dead = live_mode.topology_sessions(topology({"ws_1": [("tab_1", "term_1", False), ("tab_2", "term_2", True)]}))
        result = live_mode.kept(before, dead)
        self.assertFalse(result["all"])
        self.assertEqual(result["terminals"], "1/2")
        self.assertEqual(result["lost"], ["term_2"])
        gone = live_mode.topology_sessions(topology({}))
        self.assertEqual(live_mode.kept(before, gone)["workspaces"], "0/1")

    def test_move_renames_a_bundle_and_replaces_the_target(self):
        source = self.bundle("live.app")
        target = Path(self.dir) / "installed" / "cmux DEV t.app"
        target.mkdir(parents=True)
        (target / "old").write_text("old")
        inode = os.stat(source / "Contents/MacOS/cmux").st_ino
        live_mode.move(source, target)
        self.assertFalse(source.exists())
        self.assertFalse((target / "old").exists())
        self.assertEqual(os.stat(target / "Contents/MacOS/cmux").st_ino, inode)  # a rename, not a copy

    def test_status_line_says_live_with_the_commit_and_patches(self):
        app = self.bundle("cmux DEV t.app")
        root = live_mode.cache_root("t")
        live_mode.write_state(root, {"mode": "live", "commit": "abcdef1234567890", "since": "2026-11-05T12:00:00Z",
                                     "binary": live_mode.binary_id(app), "entry": str(root / "abcdef123456")})
        folder = live_mode.live_folder()
        folder.mkdir(parents=True)
        (folder / "live-code.log").write_text("\n".join([
            "live code: watching /x", "live code: applied patch-1.dylib functions=3",
            "live code: watching /x", "live code: applied patch-2.dylib functions=1",
            "live code: applied patch-3.dylib functions=1", "live code: patch-4.dylib refused: size",
            "live code: rolled back undo-1.rollback functions=1"]) + "\n")
        path = self.fake({"system.ping": {}, "system.identify": {
            "bundle_id": "com.cmuxterm.app.debug.t", "tag": "t", "app_bundle_path": str(app), "pid": 1}})
        args = live_mode.argparse.Namespace(socket=path, tag="t", tree=ROOT)
        result = live_mode.status(args)
        self.assertEqual(result["mode"], "live")
        self.assertEqual((result["applied"], result["refused"]), (1, 1))  # since the last start, less the undo
        line = live_mode.line(result)
        self.assertIn("Swift live mode: on", line)
        self.assertIn("abcdef123456", line)
        self.assertEqual((root.parent / "tree").read_text().strip(), str(live_mode.TREE))

    def test_status_is_off_when_the_installed_binary_is_not_the_live_one(self):
        app = self.bundle("cmux DEV t.app")
        root = live_mode.cache_root("t")
        live_mode.write_state(root, {"mode": "live", "commit": "abcdef1234567890", "binary": "0:0"})
        path = self.fake({"system.ping": {}, "system.identify": {
            "bundle_id": "com.cmuxterm.app.debug.t", "tag": "t", "app_bundle_path": str(app), "pid": 1}})
        result = live_mode.status(live_mode.argparse.Namespace(socket=path, tag="t", tree=ROOT))
        self.assertEqual(result["mode"], "normal")  # a reload replaced it: live mode is not on
        self.assertEqual(live_mode.line(result), "Swift live mode: off, cmux DEV t runs its normal build")

    def test_status_with_no_app_running(self):
        args = live_mode.argparse.Namespace(socket=os.path.join(self.dir, "none.sock"), tag="t", tree=ROOT)
        self.assertEqual(live_mode.line(live_mode.status(args)), "Swift live mode: off (cmux DEV t is not running)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
