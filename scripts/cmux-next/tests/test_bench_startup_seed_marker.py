#!/usr/bin/env python3
"""bench-startup.py's realistic seed records its outcome even when the app made no tag folder.

When the seeded agent chat never loads, or cannot be placed ("The agent chat can't be split."), the app may quit before
it saved anything, so <Application Support>/cmux/tags/<tag> does not exist. The seed then wrote its marker into that
missing folder, raised FileNotFoundError and ended the whole launch bench (--profile realistic) on both measured
commits (fleet jobs 67312a24fdc5aa26e7b379cd and fa5bb1cf1306deb041f97372, 2026-10-31). No app: the seed's launch,
daemon and app clients are faked, and every app action is refused, as the fleet runs saw.
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
    """The seeding launch draws a terminal, then quits; it saves nothing, so no tag folder exists."""
    def __init__(self, *args, **kwargs):
        pass

    def wait_for(self, *args, **kwargs):
        return True

    def quit(self):
        pass


class SeedMarker(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="seed-home-")
        self.tag = "seedtest"

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def test_a_seed_with_no_tag_folder_records_a_terminals_only_seed(self):
        fake_storm = types.ModuleType("bench_cli_storm")
        fake_storm.Client = FakeDaemon
        with mock.patch.dict(os.environ, {"HOME": self.home}), mock.patch.dict(sys.modules, {"bench_cli_storm": fake_storm}), \
                mock.patch.object(bench_startup, "Launch", SeedLaunch), \
                mock.patch.object(bench_startup, "reset_state", lambda tag: None), \
                mock.patch.object(bench_startup, "daemon_socket", lambda tag, timeout=20: "/nonexistent.sock"), \
                mock.patch.object(bench_startup, "app_client", lambda *a, **k: RefusingApp()), \
                mock.patch.object(bench_startup, "app_tab_id", lambda *a, **k: "tab-1"):
            tag_dir = bench_startup.state_directories(self.tag)[0]
            self.assertFalse(os.path.exists(tag_dir))
            with redirect_stderr(io.StringIO()) as err:
                bench_startup.seed_realistic(self.tag, tempfile.mkdtemp(dir=self.home), 1)
            self.assertIn("seeding without an agent chat", err.getvalue())
            self.assertTrue(os.path.exists(bench_startup.seeded_marker(self.tag)))
            self.assertFalse(bench_startup.seeded_agent(self.tag))  # the next runs wait for a terminal, not a chat


if __name__ == "__main__":
    unittest.main()
