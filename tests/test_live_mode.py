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
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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
        self.old_account_home = live_mode.account_home
        live_mode.account_home = lambda: str(self.home)  # the live folder and cache follow the account home
        self.apps = []

    def tearDown(self):
        for app in self.apps:
            app.close()
        live_mode.account_home = self.old_account_home
        if self.old_home is not None:
            os.environ["HOME"] = self.old_home

    def fake(self, answers):
        path = os.path.join(self.dir, "s.sock")
        self.apps.append(FakeApp(path, answers))
        return path

    def bundle(self, name, executable="cmux"):
        app = Path(self.dir) / name
        (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
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

    def test_only_an_existing_app_file_patches_in_the_rest_waits_for_the_stop_build(self):
        app, other = f"{live_mode.SOURCES}/CmuxNextApp/Home/A.swift", f"{live_mode.SOURCES}/CmuxNextDesign/B.swift"
        new = f"{live_mode.SOURCES}/CmuxNextApp/New.swift"
        built = {app: (1, "a"), other: (1, "b"), f"{live_mode.SOURCES}/CmuxNextApp/Same.swift": (1, "s")}
        now_sources = {app: (2, "a2"), other: (2, "b2"), new: (2, "n"), f"{live_mode.SOURCES}/CmuxNextApp/Same.swift": (9, "s")}
        patchable, waiting = live_mode.changed_sources(built, now_sources)
        self.assertEqual(patchable, [app])  # a touch with the same bytes is no edit
        self.assertEqual(waiting, [new, other])

    def test_the_socket_is_found_under_the_account_home_when_home_is_another(self):
        account, step = Path(self.dir) / "account", Path(self.dir) / "step"
        sock = account / ".local/state/cmux/cmux-debug-mine.sock"
        sock.parent.mkdir(parents=True)
        sock.write_text("")
        saved, home = live_mode.account_home, os.environ.get("HOME")
        live_mode.account_home, os.environ["HOME"] = (lambda: str(account)), str(step)
        try:
            self.assertEqual(live_mode.tagged_socket("mine"), str(sock))
        finally:
            live_mode.account_home = saved
            os.environ["HOME"] = home or ""

    def test_the_watcher_skips_its_build_once_a_stop_took_the_lock(self):
        root = Path(self.dir) / "cache"
        saved = live_mode.build_optimized_locked
        live_mode.build_optimized_locked = lambda *a: self.fail("built after live mode ended")
        try:
            self.assertIsNone(live_mode.build_optimized(Path(self.dir), "mine", root, "/x.app", root / "log",
                                                        wanted=lambda: False))
        finally:
            live_mode.build_optimized_locked = saved

    def test_state_is_written_whole_by_a_rename(self):
        root = Path(self.dir) / "cache" / "mine"
        live_mode.write_state(root, {"mode": "live", "binary": "b"})
        self.assertEqual(live_mode.read_state(root), {"mode": "live", "binary": "b"})
        self.assertEqual(sorted(p.name for p in root.iterdir()), ["state.json"])

    def test_the_live_folder_and_cache_follow_the_account_home_not_home(self):
        os.environ["HOME"] = str(Path(self.dir) / "step")
        self.assertEqual(live_mode.live_folder(), self.home / "Library/Caches/cmux-next/live-code")
        self.assertEqual(live_mode.cache_root("mine"), self.home / "Library/Caches/cmux-next/live-mode/mine")

    def test_a_scan_hashes_only_files_whose_mtime_moved(self):
        tree = Path(self.dir) / "tree"
        source = tree / live_mode.SOURCES / "CmuxNextApp/A.swift"
        source.parent.mkdir(parents=True)
        source.write_text("one")
        first = live_mode.swift_sources(tree)
        rel = str(source.relative_to(tree))
        stale = {rel: (first[rel][0], "remembered")}
        self.assertEqual(live_mode.swift_sources(tree, stale)[rel][1], "remembered")
        source.write_text("two")
        os.utime(source, ns=(first[rel][0] + 10**9, first[rel][0] + 10**9))
        self.assertNotEqual(live_mode.swift_sources(tree, stale)[rel][1], "remembered")

    def test_a_save_after_the_start_snapshot_patches_from_the_watch_baseline(self):
        tree = Path(self.dir) / "tree"
        source = tree / live_mode.SOURCES / "CmuxNextApp/A.swift"
        source.parent.mkdir(parents=True)
        source.write_text("one")
        baseline = Path(self.dir) / "watch-baseline.json"
        live_mode.save_sources(baseline, live_mode.swift_sources(tree))
        source.write_text("two")  # saved before the watcher's first scan
        seen = live_mode.load_sources(baseline)
        os.utime(source, ns=(seen[str(source.relative_to(tree))][0] + 10**9,) * 2)
        patchable, waiting = live_mode.changed_sources(seen, live_mode.swift_sources(tree, seen))
        self.assertEqual((patchable, waiting), ([str(source.relative_to(tree))], []))

    def test_the_tree_hash_follows_edits_and_new_files_without_touching_the_index(self):
        tree = Path(self.dir) / "repo"
        tree.mkdir()
        run = lambda *a: subprocess.run(["git", "-C", str(tree), *a], check=True, capture_output=True)  # noqa: E731
        run("init", "-q")
        (tree / "a.txt").write_text("a")
        run("add", "a.txt")
        run("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "a")
        clean = live_mode.tree_hash(tree)
        self.assertTrue(clean)
        (tree / "a.txt").write_text("b")
        edited = live_mode.tree_hash(tree)
        (tree / "new.txt").write_text("n")
        added = live_mode.tree_hash(tree)
        self.assertEqual(len({clean, edited, added}), 3)
        staged = subprocess.run(["git", "-C", str(tree), "diff", "--cached", "--name-only"], capture_output=True, text=True)
        self.assertEqual(staged.stdout, "")  # the person's index is untouched

    def test_status_without_a_tag_reads_the_recorded_live_tag(self):
        live_mode.write_state(live_mode.cache_root("older"), {"mode": "live", "tag": "older", "since": "2026-11-05T10:00:00Z"})
        live_mode.write_state(live_mode.cache_root("newer"), {"mode": "live", "tag": "newer", "since": "2026-11-05T11:00:00Z"})
        live_mode.write_state(live_mode.cache_root("off"), {"mode": "normal", "tag": "off", "since": "2026-11-05T12:00:00Z"})
        self.assertEqual(live_mode.recorded_live_tag(), "newer")

    def test_a_launch_that_fails_puts_the_old_build_back_and_starts_it(self):
        installed, live = self.bundle("cmux DEV t.app"), self.bundle("live.app")
        keep = Path(self.dir) / "before.app"
        old_inode = os.stat(installed / "Contents/MacOS/cmux").st_ino
        launched, written, calls = [], [], {"n": 0}
        saved = (live_mode.sessions, live_mode.quit_keep_sessions, live_mode.launch, live_mode.wait_ready, live_mode.answers,
                 live_mode.bundle_pids)
        live_mode.bundle_pids = lambda app: []

        def wait_ready(path):
            calls["n"] += 1
            if calls["n"] == 1:
                raise live_mode.Refused("did not answer")

        live_mode.sessions = lambda path: {"workspaces": [], "tabs": [], "terminals": [], "loaded": True}
        live_mode.quit_keep_sessions = lambda pid: None
        live_mode.launch = lambda app, bundle: launched.append(os.stat(Path(app) / "Contents/MacOS/cmux").st_ino) or "open"
        live_mode.wait_ready, live_mode.answers = wait_ready, lambda path: False
        try:
            with self.assertRaises(live_mode.Refused) as refused:
                live_mode.swap("sock", {"app_bundle_path": str(installed), "pid": 1, "bundle_id": "b"},
                               into=live, keep_as=keep, swapped=written.append)
        finally:
            (live_mode.sessions, live_mode.quit_keep_sessions, live_mode.launch, live_mode.wait_ready,
             live_mode.answers, live_mode.bundle_pids) = saved
        self.assertIn("the build that ran before is back", str(refused.exception))
        self.assertEqual(os.stat(installed / "Contents/MacOS/cmux").st_ino, old_inode)
        self.assertTrue((live / "Contents/MacOS/cmux").exists() and not keep.exists())
        self.assertEqual(launched[-1], old_inode)  # the old build is what started last
        self.assertIsNone(written[-1])  # the state says the swap did not happen

    def test_a_replacement_hung_before_its_socket_is_quit_before_the_old_build_starts(self):
        installed, live = self.bundle("cmux DEV t.app"), self.bundle("live.app")
        keep = Path(self.dir) / "before.app"
        events = []
        saved = (live_mode.quit_keep_sessions, live_mode.launch, live_mode.answers, live_mode.bundle_pids, live_mode.wait_ready)
        live_mode.answers = lambda path: False  # hung before it opened its socket
        live_mode.bundle_pids = lambda app: [4242] if Path(app) == installed else []
        live_mode.quit_keep_sessions = lambda pid: events.append(("quit", pid))
        live_mode.launch = lambda app, bundle: events.append(("launch", str(app))) or "open"
        live_mode.wait_ready = lambda path: None
        try:
            # installed is the live build that hung; keep holds the build that ran before.
            os.rename(installed, keep)
            os.rename(live, installed)
            live_mode.undo_failed_launch("sock", {"bundle_id": "b"}, installed, live, keep, None)
        finally:
            (live_mode.quit_keep_sessions, live_mode.launch, live_mode.answers, live_mode.bundle_pids,
             live_mode.wait_ready) = saved
        self.assertEqual(events, [("quit", 4242), ("launch", str(installed))])

    def test_a_replacement_that_will_not_quit_leaves_the_old_build_unstarted(self):
        installed, live = self.bundle("cmux DEV t.app"), self.bundle("live.app")
        keep = Path(self.dir) / "before.app"
        launched = []

        def stuck(pid):
            raise live_mode.Refused("did not quit")

        saved = (live_mode.quit_keep_sessions, live_mode.launch, live_mode.answers, live_mode.bundle_pids)
        live_mode.answers, live_mode.bundle_pids = (lambda path: False), (lambda app: [4242])
        live_mode.quit_keep_sessions, live_mode.launch = stuck, (lambda app, bundle: launched.append(app))
        try:
            os.rename(installed, keep)
            os.rename(live, installed)
            with self.assertRaises(live_mode.Refused) as refused:
                live_mode.undo_failed_launch("sock", {"bundle_id": "b"}, installed, live, keep, None)
        finally:
            live_mode.quit_keep_sessions, live_mode.launch, live_mode.answers, live_mode.bundle_pids = saved
        self.assertIn("not started", str(refused.exception))
        self.assertEqual(launched, [])
        self.assertTrue((installed / "Contents/MacOS/cmux").exists() and (live / "Contents/MacOS/cmux").exists())

    def test_an_app_that_answers_but_never_loads_is_a_failed_start(self):
        saved = (live_mode.answers, live_mode.sessions, live_mode.time.sleep)
        live_mode.answers = lambda path: True
        live_mode.sessions = lambda path: {"workspaces": [], "tabs": [], "terminals": [], "loaded": False}
        live_mode.time.sleep = lambda seconds: None
        try:
            with self.assertRaises(live_mode.Refused):
                live_mode.wait_ready("/tmp/sock", timeout_answer=1, timeout_loaded=0)
        finally:
            live_mode.answers, live_mode.sessions, live_mode.time.sleep = saved

    def test_a_second_start_or_stop_is_refused_while_one_runs(self):
        root = live_mode.cache_root("t")
        with live_mode.SwapLock(root):
            with self.assertRaises(live_mode.Refused) as refused:
                with live_mode.SwapLock(root):
                    pass
        self.assertIn("another live mode start or stop runs", str(refused.exception))
        with live_mode.SwapLock(root):  # free again once the first ends
            pass

    def test_a_failed_swap_puts_labs_live_code_back(self):
        writes, saved = [], live_mode.live_code_setting
        live_mode.live_code_setting = lambda path, on: writes.append(on)

        def failing():
            raise live_mode.Refused("did not answer")

        try:
            with self.assertRaises(live_mode.Refused):
                live_mode.with_setting_back("sock", True, True, failing)
            with self.assertRaises(live_mode.Refused):
                live_mode.with_setting_back("sock", True, False, failing)  # unchanged: nothing to undo
            self.assertEqual(live_mode.with_setting_back("sock", True, True, lambda: "ok"), "ok")
        finally:
            live_mode.live_code_setting = saved
        self.assertEqual(writes, [False])

    def live_build(self, root, commit, tree):
        """A cached live code build of `commit` that compiled `tree` as it is now, held by the tag's
        live derived data."""
        entry = root / commit[:12]
        (entry / "live.app").mkdir(parents=True)
        (entry / "build").mkdir()
        (entry / "build/xcodebuild.log").write_text("")
        live_mode.save_sources(entry / "sources.json", live_mode.swift_sources(tree))
        (entry / "reusable").write_text(commit + "\n")
        (root / "derived-data.commit").write_text(commit + "\n")
        return entry

    def app_tree(self):
        """A git checkout with one CmuxNextApp file and one shared-package file, committed."""
        tree = Path(self.dir) / "tree"
        source = tree / live_mode.SOURCES / "CmuxNextApp/A.swift"
        source.parent.mkdir(parents=True)
        source.write_text("one")
        shared = tree / "Packages/Shared/Kit/Sources/Kit/K.swift"
        shared.parent.mkdir(parents=True)
        shared.write_text("k")
        run = lambda *a: subprocess.run(["git", "-C", str(tree), *a], check=True, capture_output=True)  # noqa: E731
        run("init", "-q")
        run("add", "-A")
        run("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "base")
        return tree, source

    def commit_of(self, tree):
        return subprocess.run(["git", "-C", str(tree), "rev-parse", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()

    def test_the_last_live_build_is_reused_when_everything_since_patches_in(self):
        tree, source = self.app_tree()
        root = live_mode.cache_root("t")
        built = self.commit_of(tree)
        entry = self.live_build(root, built, tree)
        source.write_text("two")  # a pull or an edit inside an existing CmuxNextApp file
        reused = live_mode.reusable_build(root, tree)
        self.assertEqual(reused, (entry, built, [str(source.relative_to(tree))]))

    def test_any_other_build_input_that_changed_builds_instead(self):
        tree, source = self.app_tree()
        root = live_mode.cache_root("t")
        self.live_build(root, self.commit_of(tree), tree)
        source.write_text("two")
        for other, text in [("Packages/Shared/Kit/Sources/Kit/K.swift", "k2"),  # a shared package
                            ("webviews/src/x.ts", "x"),  # untracked: a new file anywhere
                            (f"{live_mode.SOURCES}/CmuxNextApp/Resources/en.xcstrings", "{}")]:
            path = tree / other
            path.parent.mkdir(parents=True, exist_ok=True)
            before = path.read_text() if path.exists() else None
            path.write_text(text)
            self.assertIsNone(live_mode.reusable_build(root, tree), other)
            path.write_text(before) if before is not None else path.unlink()
        self.assertIsNotNone(live_mode.reusable_build(root, tree))
        (root / "derived-data.commit").write_text("f" * 40 + "\n")  # a commit git does not know
        (root / ("f" * 12) / "live.app").mkdir(parents=True)
        (root / ("f" * 12) / "build").mkdir()
        (root / ("f" * 12) / "build/xcodebuild.log").write_text("")
        live_mode.save_sources(root / ("f" * 12) / "sources.json", live_mode.swift_sources(tree))
        (root / ("f" * 12) / "reusable").write_text("f" * 40 + "\n")
        self.assertIsNone(live_mode.reusable_build(root, tree))

    def test_a_change_that_cannot_patch_in_builds_instead(self):
        tree, _ = self.app_tree()
        root = live_mode.cache_root("t")
        self.assertIsNone(live_mode.reusable_build(root, tree))  # no live build yet
        entry = self.live_build(root, self.commit_of(tree), tree)
        new = tree / live_mode.SOURCES / "CmuxNextApp/New.swift"
        new.write_text("new")  # a new file waits for a build, so the build is not reused
        self.assertIsNone(live_mode.reusable_build(root, tree))
        new.unlink()
        (root / "derived-data.commit").unlink()  # a build that stopped half way: its intermediates are gone
        self.assertIsNone(live_mode.reusable_build(root, tree))
        self.assertTrue(entry.is_dir())

    def start_with(self, tree, fresh, head="2222222222222222222222222222222222222222"):
        """start_locked with a fake app at abcdef12 and the checkout at `head`, the swap, setting and
        patch compile stubbed; what it returned, and whether it built."""
        app = self.bundle("cmux DEV t.app")  # CMUXCommit abcdef1234567890
        root = live_mode.cache_root("t")
        built, applied = [], []
        stubs = {
            "git": lambda tree_, *argv: head,
            "build_live": lambda *a: built.append(a) or 1.0,
            "live_code_setting": lambda *a: "set",
            "swap": lambda path, ident, into, keep_as, swapped=None: {
                "binary": "1:1", "restart_s": 1, "quit_s": 0, "launch_s": 1, "into_was": str(into),
                "sessions": {"workspaces": "1/1", "tabs": "1/1", "terminals": "1/1", "all": True, "lost": []}},
            "apply_edits": lambda tree_, entry, files: applied.append(files) or {"files": files, "exit": 0},
            "detach": lambda *a, **k: "log",
        }
        saved = {name: getattr(live_mode, name) for name in stubs}
        for name, stub in stubs.items():
            setattr(live_mode, name, stub)
        try:
            args = live_mode.argparse.Namespace(tree=tree, fresh=fresh, setting_done=False)
            ident = {"app_bundle_path": str(app), "bundle_id": "com.cmuxterm.app.debug.t", "pid": 1}
            return live_mode.start_locked(args, "sock", ident, "t", root), built, applied
        finally:
            for name, original in saved.items():
                setattr(live_mode, name, original)

    def test_a_build_of_a_checkout_with_another_uncommitted_edit_is_never_reused(self):
        tree, source = self.app_tree()
        root = live_mode.cache_root("t")
        shared = tree / "Packages/Shared/Kit/Sources/Kit/K.swift"
        shared.write_text("dirty")  # compiled into the build, then reverted
        entry = self.live_build(root, self.commit_of(tree), tree)
        (entry / "reusable").unlink()  # start marks only a build of a checkout dirty in CmuxNextApp Swift alone
        self.assertFalse(live_mode.only_app_swift_changed(tree, self.commit_of(tree)))
        shared.write_text("k")
        source.write_text("two")
        self.assertIsNone(live_mode.reusable_build(root, tree))

    def test_start_marks_a_clean_build_reusable_and_a_dirty_one_not(self):
        tree, _ = self.app_tree()
        head = self.commit_of(tree)
        saved = live_mode.git
        live_mode.git = lambda tree_, *argv: head
        try:
            for dirty, expect in [(False, True), (True, False)]:
                shared = tree / "Packages/Shared/Kit/Sources/Kit/K.swift"
                shared.write_text("dirty" if dirty else "k")
                root = live_mode.cache_root("t")
                (root / "derived-data.commit").unlink(missing_ok=True)
                built = []
                stubs = {"build_live": lambda *a: built.append(a) or 1.0, "live_code_setting": lambda *a: "set",
                         "swap": lambda *a, **k: {"binary": "1:1", "restart_s": 1, "quit_s": 0, "launch_s": 1,
                                                  "sessions": {"all": True}},
                         "apply_edits": lambda *a: {"files": [], "exit": 0}, "detach": lambda *a, **k: "log"}
                originals = {name: getattr(live_mode, name) for name in stubs}
                for name, stub in stubs.items():
                    setattr(live_mode, name, stub)
                try:
                    app = self.bundle("cmux DEV t.app")
                    with open(app / "Contents/Info.plist", "wb") as f:
                        live_mode.plistlib.dump({"CFBundleExecutable": "cmux", "CMUXCommit": head}, f)
                    args = live_mode.argparse.Namespace(tree=tree, fresh=True, setting_done=False)
                    live_mode.start_locked(args, "sock", {"app_bundle_path": str(app)}, "t", root)
                finally:
                    for name, original in originals.items():
                        setattr(live_mode, name, original)
                self.assertEqual(len(built), 1)
                self.assertEqual((root / head[:12] / "reusable").is_file(), expect, dirty)
        finally:
            live_mode.git = saved

    def test_start_reuses_the_last_live_build_with_no_build_and_patches_the_difference(self):
        tree, source = self.app_tree()
        root = live_mode.cache_root("t")
        built_commit = self.commit_of(tree)
        entry = self.live_build(root, built_commit, tree)
        source.write_text("two")
        result, built, applied = self.start_with(tree, fresh=False)
        self.assertEqual(built, [])  # no build: the app at abcdef12 need not be HEAD 22222222
        self.assertEqual(result["into_was"], str(entry / "live.app"))
        self.assertEqual(applied, [[str(source.relative_to(tree))]])
        self.assertEqual((result["built_commit"], result["commit"][:4]), (built_commit, "2222"))
        self.assertIsNone(result["built_s"])
        text = live_mode.summary("start", result)
        self.assertIn(f"live code build of {built_commit[:12]}, patched up to 222222222222", text)
        self.assertIn("no build", text)
        self.assertEqual(live_mode.read_state(root)["built_commit"], built_commit)

    def test_start_fresh_keeps_the_commit_check_and_builds(self):
        tree, _ = self.app_tree()
        self.live_build(live_mode.cache_root("t"), self.commit_of(tree), tree)
        with self.assertRaises(live_mode.Refused) as refused:
            self.start_with(tree, fresh=True)  # building HEAD: the app must be at HEAD, as before
        self.assertIn("check that commit out", str(refused.exception))

    def test_start_fresh_builds_even_when_heads_own_build_is_cached(self):
        tree, _ = self.app_tree()
        head = "abcdef1234567890abcdef1234567890abcdef12"  # the app's commit, so the commit check passes
        self.live_build(live_mode.cache_root("t"), head, tree)
        _, built, _ = self.start_with(tree, fresh=False, head=head)
        self.assertEqual(built, [])  # cached: a restart and a patch
        _, built, _ = self.start_with(tree, fresh=True, head=head)
        self.assertEqual(len(built), 1)

    def test_heads_own_cached_build_is_rebuilt_when_it_was_not_marked_reusable(self):
        tree, _ = self.app_tree()
        head = "abcdef1234567890abcdef1234567890abcdef12"  # the app's commit, so the commit check passes
        entry = self.live_build(live_mode.cache_root("t"), head, tree)
        (entry / "reusable").unlink()  # built while another input was uncommitted
        _, built, _ = self.start_with(tree, fresh=False, head=head)
        self.assertEqual(len(built), 1)

    def test_status_line_says_what_the_reused_build_was_patched_up_to(self):
        line = live_mode.line({"mode": "live", "tag": "t", "commit": "2222222222222222", "since": "now",
                               "built_commit": "1111111111111111"})
        self.assertIn("live code build of 111111111111, patched up to 222222222222 since now", line)
        same = live_mode.line({"mode": "live", "tag": "t", "commit": "2222222222222222", "since": "now",
                               "built_commit": "2222222222222222"})
        self.assertIn("live code build of 222222222222 since now", same)

    def test_status_with_no_app_running(self):
        args = live_mode.argparse.Namespace(socket=os.path.join(self.dir, "none.sock"), tag="t", tree=ROOT)
        self.assertEqual(live_mode.line(live_mode.status(args)), "Swift live mode: off (cmux DEV t is not running)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
