#!/usr/bin/env python3
"""bench-startup.py finds the tag's state where the app keeps it: under the password database's home, not $HOME.

A fleet step points $HOME at its own folder, but the app resolves Application Support from
FileManager.homeDirectoryForCurrentUser (the password database's home), and its daemon makes
<that>/Library/Application Support/cmux/tags/<tag>/tui at start. bench-startup used os.path.expanduser("~"), so on the
fleet its reset, seed and marker all went to a folder the app never uses: the marker write raised FileNotFoundError
and ended --profile realistic on both measured commits (fleet jobs 67312a24fdc5aa26e7b379cd and
fa5bb1cf1306deb041f97372, 2026-10-31), and --profile empty did not empty anything. No app: the app and its daemon
are faked; the fake daemon makes the tag folder under the account home, as the real one does.
Run: python3 -I scripts/cmux-next/tests/test_bench_startup_seed_marker.py"""
import importlib.util, io, os, shutil, sys, tempfile, types, unittest
from contextlib import redirect_stderr
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "..", "bench-startup.py"))
bench_startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench_startup)


class FakeDaemon:
    """The daemon socket: each new-workspace adds one workspace with one pane."""
    def __init__(self, *args, **kwargs):
        self.spaces = {}

    def call(self, method, params=None, **kw):
        if method == "list-workspaces":
            return {"data": {"workspaces": list(self.spaces.values())}}
        if method == "new-workspace":
            wid = f"ws{len(self.spaces)}"
            self.spaces[wid] = {"id": wid, "screens": [{"panes": [{"id": f"p{wid}"}]}]}
            return {"ok": True}
        return {"ok": True}

    def close(self):
        pass


class RefusingApp:
    def call(self, method, params=None, **kw):
        return {"ok": False, "error": {"code": "unavailable", "message": "The agent chat can't be split."}}

    def close(self):
        pass


class SeedLaunch:
    """The seeding launch draws a terminal, then quits. As the real app does, its daemon makes the tag's tui folder
    under the ACCOUNT home (the password database's), whatever $HOME says."""
    account_home = None
    tag = None

    def __init__(self, *args, **kwargs):
        os.makedirs(os.path.join(self.account_home, "Library/Application Support/cmux/tags", self.tag, "tui"),
                    exist_ok=True)

    def wait_for(self, *args, **kwargs):
        return True

    def quit(self):
        pass


class SeedMarker(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="seed-step-home-")      # what a fleet step sets as $HOME
        self.account = tempfile.mkdtemp(prefix="seed-account-home-")  # what the app resolves
        self.tag = "seedtest"
        SeedLaunch.account_home, SeedLaunch.tag = self.account, self.tag

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)
        shutil.rmtree(self.account, ignore_errors=True)

    def test_the_seed_marks_the_folder_the_app_uses(self):
        fake_storm = types.ModuleType("bench_cli_storm")
        fake_storm.Client = FakeDaemon
        env = {k: v for k, v in os.environ.items() if k != "BENCH_LAUNCH_STATE_BASE"}
        env["HOME"] = self.home
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.dict(sys.modules, {"bench_cli_storm": fake_storm}), \
                mock.patch.object(bench_startup, "account_home", lambda: self.account, create=True), \
                mock.patch.object(bench_startup, "Launch", SeedLaunch), \
                mock.patch.object(bench_startup, "reset_state", lambda tag: None), \
                mock.patch.object(bench_startup, "daemon_socket", lambda tag, timeout=20: "/nonexistent.sock"), \
                mock.patch.object(bench_startup, "app_client", lambda *a, **k: RefusingApp()), \
                mock.patch.object(bench_startup, "app_tab_id", lambda *a, **k: "tab-1"):
            with redirect_stderr(io.StringIO()) as err:
                bench_startup.seed_realistic(self.tag, tempfile.mkdtemp(dir=self.home), 1)
            self.assertIn("seeding without an agent chat", err.getvalue())
            marker = bench_startup.seeded_marker(self.tag)
            self.assertTrue(marker.startswith(self.account), marker)  # the app's folder, not the step's $HOME
            self.assertTrue(os.path.exists(marker))
            self.assertFalse(bench_startup.seeded_agent(self.tag))  # the next runs wait for a terminal, not a chat
            self.assertFalse(os.path.exists(os.path.join(self.home, "Library/Application Support/cmux/tags", self.tag)))

    def test_reset_state_empties_the_folder_the_app_uses(self):
        tag_dir = os.path.join(self.account, "Library/Application Support/cmux/tags", self.tag, "tui")
        agents = os.path.join(self.account, ".acpmux/builds", "com.cmuxterm.app.debug." + self.tag)
        mux = os.path.join(self.account, ".cmux/mux/tags", self.tag)
        for d in (tag_dir, agents, mux):
            os.makedirs(d)
        env = {k: v for k, v in os.environ.items() if k != "BENCH_LAUNCH_STATE_BASE"}
        env["HOME"] = self.home
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(bench_startup, "account_home", lambda: self.account, create=True), \
                mock.patch.object(bench_startup, "stop", lambda *a, **k: None), \
                mock.patch.object(bench_startup, "tag_pids", lambda tag: []):
            bench_startup.reset_state(self.tag)
        self.assertFalse(os.path.exists(tag_dir), "--profile empty must empty the app's own state")
        self.assertFalse(os.path.exists(agents), "--profile empty must end the tag's agent sessions (acpmux)")
        self.assertFalse(os.path.exists(mux), "--profile empty must clear the tag's mux state")


if __name__ == "__main__":
    unittest.main()
