#!/usr/bin/env python3
"""Seed fixtures count existing workspaces and always quit after writing the front."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("seed", Path(__file__).resolve().parents[1] / "launch-ready-seed.py")
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


class App:
    """Control socket fixture: opening a window also creates its first workspace."""
    def __init__(self):
        self.windows = {"w1": ["ws_1", "home_w1"]}
        self.workspaces = ["ws_1"]
        self.active = "w1"
        self.homes = {"w1"}
        self.home = False
        self.quit = False

    def topology(self):
        return {"loaded": True, "windows": [{"id": w, "workspaces": list(ids)} for w, ids in self.windows.items()],
                "workspaces": [{"id": w} for w in self.workspaces] + [{"id": f"home_{w}"} for w in self.homes],
                "focus": {"window": self.active, "workspace": self.windows[self.active][-1], "tab": "tab_1"},
                "panes": [{"tabs": [{"id": "tab_1", "page": "home-dock" if self.home else "terminal"}]}]}

    def create(self):
        workspace = f"ws_{len(self.workspaces) + 1}"
        self.workspaces.append(workspace)
        self.windows[self.active].append(workspace)
        return {"created": [workspace]}

    def rpc(self, path, method, params=None, timeout=60):
        if method == "snapshot.get":
            return {"topology": self.topology()}
        if method == "context.keys":
            return {"keys": {"topPage": "home" if self.home else "workspace"}}
        action = params["action"]
        if action == "newWindow":
            self.active = f"w{len(self.windows) + 1}"
            self.windows[self.active] = []
            return self.create()
        if action == "workspace.newAtBottom":
            return self.create()
        if action == "moveWorkspaceToWindow":
            workspace = params["target"].split(":", 1)[1]
            target = params["args"]["window"].split(":", 1)[1]
            for members in self.windows.values():
                if workspace in members:
                    members.remove(workspace)
            self.windows[target].append(workspace)
            self.active = target
        elif action == "home.show":
            self.home = True
            if self.active not in self.homes:
                self.windows[self.active].append(f"home_{self.active}")
            self.homes.add(self.active)
        elif action == "quitKeepSessions":
            self.quit = True
        else:
            raise AssertionError(action)
        return {}


class SeedTests(unittest.TestCase):
    def run_seed(self, app, *args):
        output = io.StringIO()
        with patch.object(seed, "rpc", app.rpc), patch.object(seed.time, "sleep"), contextlib.redirect_stdout(output):
            code = seed.main(["fixture.sock", *args])
        return code, json.loads(output.getvalue().removeprefix("LR-SEED "))

    def test_exact_totals_include_window_creation(self):
        for count, windows in ((5, 1), (120, 1), (5, 3), (6, 3), (120, 3)):
            with self.subTest(count=count, windows=windows), tempfile.TemporaryDirectory() as temp:
                app = App()
                front = Path(temp) / "front.json"
                code, row = self.run_seed(app, "--windows", str(windows), "--total-workspaces", str(count),
                                          "--front-out", str(front))
                self.assertEqual(code, 0, row)
                self.assertEqual(len(app.topology()["workspaces"]), count)
                self.assertEqual(sum(map(len, app.windows.values())), count)
                self.assertEqual(row["all_workspaces"], count)
                self.assertEqual(len(app.windows), windows)
                self.assertEqual(json.loads(front.read_text())["top_page"], "home")
                self.assertTrue(app.quit)

    def test_front_home_is_read_as_home_by_the_judge(self):
        """The seed's front file is what run1 must reopen: Home docked in the workspace is Home, not that workspace's tab."""
        with tempfile.TemporaryDirectory() as temp:
            app = App()
            front = Path(temp) / "front.json"
            code, row = self.run_seed(app, "--windows", "1", "--total-workspaces", "120", "--front-out", str(front))
            self.assertEqual(code, 0, row)
            written = json.loads(front.read_text())
            self.assertEqual((written["home"], written["page"]), (True, "home-dock"))
            judge = importlib.util.spec_from_file_location("summary", Path(__file__).resolve().parents[1] / "launch-ready-summary.py")
            summary = importlib.util.module_from_spec(judge)
            judge.loader.exec_module(summary)
            run = {"home": True, "page": "home-dock", "workspace": written["workspace"], "tab": written["tab"]}
            self.assertEqual(summary.key(written), summary.key(run))
            self.assertIsNone(summary.judge({"front": run, "marks": {}}, "last", written))

    def test_front_tab_leaves_the_last_terminal_in_front(self):
        with tempfile.TemporaryDirectory() as temp:
            app = App()
            front = Path(temp) / "front.json"
            code, row = self.run_seed(app, "--windows", "1", "--total-workspaces", "120", "--front", "tab",
                                      "--front-out", str(front))
            self.assertEqual(code, 0, row)
            self.assertEqual(len(app.topology()["workspaces"]), 120)
            self.assertFalse(app.home)
            written = json.loads(front.read_text())
            self.assertEqual(written["top_page"], "workspace")
            self.assertEqual(written["workspace"], app.windows["w1"][-1])
            self.assertTrue(app.quit)

    def test_default_keeps_additive_fixture_and_writes_front(self):
        with tempfile.TemporaryDirectory() as temp:
            app = App()
            front = Path(temp) / "front.json"
            code, row = self.run_seed(app, "--front-out", str(front))
            self.assertEqual(code, 0, row)
            self.assertEqual(len(app.workspaces), 63)
            self.assertEqual(row["ours_per_window"], [20, 20, 20])
            self.assertEqual(json.loads(front.read_text())["top_page"], "home")
            self.assertTrue(app.quit)

    def test_front_write_failure_still_quits(self):
        with tempfile.TemporaryDirectory() as temp:
            app = App()
            code, row = self.run_seed(app, "--workspaces", "3", "--front-out", temp)
            self.assertEqual(code, 1)
            self.assertIn("error", row)
            self.assertTrue(app.quit)

    def test_excess_initial_workspaces_are_preserved(self):
        app = App()
        before = list(app.workspaces)
        code, row = self.run_seed(app, "--windows", "1", "--total-workspaces", "1")
        self.assertEqual(code, 1)
        self.assertIn("error", row)
        self.assertEqual(app.workspaces, before)
        self.assertTrue(app.quit)


if __name__ == "__main__":
    unittest.main()
