#!/usr/bin/env python3
"""Tests for app_reset.py (p15-oracle-189): the reset snapshot, the reset's calls, and the launch-sharing session.

Run: python3 -I scripts/cmux-next/oracle/app_reset_test.py (stdlib unittest, no app). A fake control socket keeps a
topology, settings and a closed history and applies the reset's actions to them, with bench_launch.rpc_at's reply
shapes. It refuses what the app refuses: an action not in its action.list, a target of a kind the action does not
declare (ControlRouter+Validation.target: "<action> does not take a target"), a choice it does not list.
"""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import app_reset  # noqa: E402

# The app's action.list rows the reset uses (CmuxNextActions/Catalog): targets and enumeration choices.
CATALOG = [
    {"id": "closeWindow", "targets": ["window"]},
    {"id": "closeWorkspace", "targets": ["workspace"], "destructive": True},
    {"id": "closePane", "targets": ["pane"]},
    {"id": "closeTab", "targets": ["tab"]},
    {"id": "workspaceGroup.ungroup", "targets": ["workspace-group"]},
    {"id": "removeWorkspaceFromGroup", "targets": ["workspace"]},
    {"id": "moveWorkspaceToGroup", "targets": ["workspace"]},
    {"id": "goToWorkspace", "targets": []},
    {"id": "pane.focus", "targets": ["pane"]},
    {"id": "tab.focus", "targets": ["tab"]},
    {"id": "history.reopen", "targets": []},
    {"id": "renameWorkspace", "targets": ["workspace"]},
    {"id": "palette.workspaceColor", "targets": ["workspace"],
     "arguments": [{"name": "color", "choices": [{"value": "blue"}, {"value": "red"}]}]},
    {"id": "palette.resetWorkspaceColor", "targets": ["workspace"]},
    {"id": "workspace.setIcon", "targets": ["workspace"]},
    {"id": "workspace.clearIcon", "targets": ["workspace"]},
    {"id": "toggleSplitZoom", "targets": ["pane"]},
]


def tab(tid):
    return {"id": tid, "kind": "terminal", "title": "zsh"}


def topology():
    return {
        "sequence": 4,
        "focus": {"window": "win_1", "workspace": "ws_1", "pane": "pane_1", "tab": "tab_1"},
        "windows": [{"id": "win_1", "key": "w1", "workspace": "ws_1", "workspaces": ["ws_1"], "key_window": True,
                     "visible": True, "focused_pane": "pane_1"}],
        "workspace_groups": [],
        "workspaces": [{"id": "ws_1", "key": "k1", "name": "one", "color": None, "icon": None, "group": None,
                        "unread": 0, "screens": [
            {"id": "screen_1", "zoomed_pane": None, "panes": [
                {"id": "pane_1", "dock": None, "selected_tab": "tab_1", "tabs": [tab("tab_1"), tab("tab_3")]}]}]}],
    }


class FakeApp:
    """A control socket over one topology and closed history: closes add entries, history.reopen brings a tab back
    under its id, debug.closed_forget deletes entries."""

    def __init__(self, ignore=(), refuse=(), lost=False, catalog=CATALOG, reopen_keeps_ids=True):
        self.topology = topology()
        self.settings = {"ui": {"animations": {"enabled": False}}, "appearance": {"backgroundOpacity": 1}}
        self.closed = ["daemon:old_1"]  # newest first; the fixture's own history
        self.archive = {}  # closed id -> (pane id, tab)
        self.calls = []
        self.ignore = set(ignore)  # actions that answer ok and change nothing
        self.refuse = set(refuse)  # methods that answer a ControlError
        self.lost = lost
        self.catalog = {a["id"]: a for a in catalog}
        self.reopen_keeps_ids = reopen_keeps_ids
        self.counter = 0
        self.stopped = 0

    def workspace(self, wid):
        return next(w for w in self.topology["workspaces"] if w["id"] == wid)

    def panes(self):
        return [p for w in self.topology["workspaces"] for s in w["screens"] for p in s["panes"]]

    def screens(self):
        return [s for w in self.topology["workspaces"] for s in w["screens"]]

    def record_close(self, pane=None, closed_tab=None):
        self.counter += 1
        ident = f"daemon:closed_{self.counter}"
        self.closed.insert(0, ident)
        if closed_tab is not None:
            self.archive[ident] = (pane, closed_tab)

    def refusal(self, params):
        """The app's refusal of an action.run, or None (ControlRouter+Validation, ActionArgument choices)."""
        action = self.catalog.get(params["action"])
        if action is None:
            return f"unknown action {params['action']}"
        target = params.get("target")
        if target and not action["targets"]:
            return f"{params['action']} does not take a target"
        if target and target.partition(":")[0] not in action["targets"]:
            return f"{params['action']} takes a target of kind {'|'.join(action['targets'])}"
        for argument in action.get("arguments") or ():
            value = (params.get("args") or {}).get(argument["name"])
            if value is not None and value not in {c["value"] for c in argument["choices"]}:
                return f"{argument['name']} {value!r} is not a choice"
        return None

    def rpc(self, method, params):
        self.calls.append((method, copy.deepcopy(params)))
        if self.lost:
            return {"error": "[Errno 61] Connection refused", "unreachable": True}
        if method in self.refuse:
            return {"error": {"code": "not_found", "message": "no"}}
        if method == "snapshot.get":
            return {"topology": copy.deepcopy(self.topology)}
        if method == "settings.get":
            return {"value": copy.deepcopy(self.settings)}
        if method == "debug.closed_ids":
            return {"closed_ids": list(self.closed), "sequence": 1}
        if method == "debug.closed_forget":
            self.closed = [i for i in self.closed if i not in set(params["ids"])]
            return {"closed_ids": list(self.closed), "sequence": 2}
        if method == "action.list":
            return {"actions": copy.deepcopy(list(self.catalog.values()))}
        if method == "settings.set":
            node = self.settings
            *head, last = params["path"]
            for key in head:
                node = node.setdefault(key, {})
            node[last] = params["value"]
            return {}
        if method == "settings.unset":
            node = self.settings
            *head, last = params["path"]
            for key in head:
                node = node[key]
            node.pop(last, None)
            return {}
        if method == "debug.key":
            return {"error": {"code": "no_target", "message": "nothing open"}} if "target" in params else {}
        if method == "action.run":
            refusal = self.refusal(params)
            if refusal:
                return {"error": {"code": "invalid_params", "message": refusal}}
            self.apply(params)
            return {"ok": True}
        return {}

    def apply(self, params):
        action, target = params["action"], params.get("target", "")
        args = params.get("args") or {}
        if action in self.ignore:
            return
        kind, _, ident = target.partition(":")
        if action == "closeTab":
            for pane in self.panes():
                gone = [t for t in pane["tabs"] if t["id"] == ident]
                if gone:
                    self.record_close(pane["id"], gone[0])
                pane["tabs"] = [t for t in pane["tabs"] if t["id"] != ident]
                if pane["selected_tab"] == ident:
                    pane["selected_tab"] = pane["tabs"][0]["id"] if pane["tabs"] else None
        elif action == "closePane":
            for s in self.screens():
                if any(p["id"] == ident for p in s["panes"]):
                    self.record_close()
                s["panes"] = [p for p in s["panes"] if p["id"] != ident]
        elif action == "closeWorkspace":
            self.record_close()
            self.topology["workspaces"] = [w for w in self.topology["workspaces"] if w["id"] != ident]
            for window in self.topology["windows"]:
                window["workspaces"] = [w for w in window["workspaces"] if w != ident]
        elif action == "closeWindow":
            self.record_close()
            self.topology["windows"] = [w for w in self.topology["windows"] if w["id"] != ident]
        elif action == "history.reopen":
            item = args["id"]
            self.closed.remove(item)
            pane, closed_tab = self.archive.pop(item)
            reopened = dict(closed_tab) if self.reopen_keeps_ids else {**closed_tab, "id": closed_tab["id"] + "_new"}
            next(p for p in self.panes() if p["id"] == pane)["tabs"].append(reopened)
        elif action == "renameWorkspace":
            self.workspace(ident)["name"] = args["name"]
        elif action == "palette.workspaceColor":
            self.workspace(ident)["color"] = args["color"]
        elif action == "palette.resetWorkspaceColor":
            self.workspace(ident)["color"] = None
        elif action == "workspace.setIcon":
            self.workspace(ident)["icon"] = args["icon"]
        elif action == "workspace.clearIcon":
            self.workspace(ident)["icon"] = None
        elif action == "toggleSplitZoom":
            screen = next(s for s in self.screens() if any(p["id"] == ident for p in s["panes"]))
            screen["zoomed_pane"] = None if screen["zoomed_pane"] == ident else ident
        elif action == "goToWorkspace":
            self.topology["focus"]["workspace"] = args["workspace"]
        elif action == "pane.focus":
            self.topology["focus"]["pane"] = ident
        elif action == "tab.focus":
            self.topology["focus"]["tab"] = ident
            for pane in self.panes():
                if any(t["id"] == ident for t in pane["tabs"]):
                    pane["selected_tab"] = ident

    def stop(self):
        self.stopped += 1

    # What a case does.

    def new_tab(self, pane="pane_1", tid="tab_2"):
        pane = next(p for p in self.panes() if p["id"] == pane)
        pane["tabs"].append(tab(tid))
        pane["selected_tab"] = tid
        self.topology["focus"]["tab"] = tid

    def new_workspace(self, wid="ws_2"):
        self.topology["workspaces"].append({"id": wid, "key": "k2", "name": "two", "color": None, "icon": None,
                                            "group": None, "screens": [
            {"id": "screen_2", "zoomed_pane": None, "panes": [{"id": "pane_9", "dock": None, "selected_tab": "tab_9",
                                                               "tabs": [tab("tab_9")]}]}]})
        self.topology["windows"][0]["workspaces"].append(wid)
        self.topology["focus"].update(workspace=wid, pane="pane_9", tab="tab_9")

    def new_window(self, wid="win_2"):
        self.topology["windows"].append({"id": wid, "key": "w2", "workspace": None, "workspaces": []})

    def close_tab(self, tid):
        self.apply({"action": "closeTab", "target": f"tab:{tid}"})


def actions(app):
    return [(p["action"], p.get("target")) for m, p in app.calls if m == "action.run"]


class ProjectionTests(unittest.TestCase):
    def test_volatile_window_and_title_fields_are_not_state(self):
        a = app_reset.projection(topology(), {})
        changed = topology()
        changed["sequence"] = 99
        changed["windows"][0]["key_window"] = False
        changed["workspaces"][0]["unread"] = 3
        changed["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["title"] = "vim"
        self.assertEqual(a, app_reset.projection(changed, {}))

    def test_tab_order_selection_focus_settings_and_closed_history_are_state(self):
        base = app_reset.projection(topology(), {"a": 1}, ["c1"])
        for mutate in (
            lambda t: t["workspaces"][0]["screens"][0]["panes"][0].update(selected_tab=None),
            lambda t: t["focus"].update(pane="pane_x"),
            lambda t: t["workspaces"][0].update(name="renamed"),
            lambda t: t["workspaces"][0]["screens"][0].update(zoomed_pane="pane_1"),
        ):
            changed = topology()
            mutate(changed)
            self.assertNotEqual(base, app_reset.projection(changed, {"a": 1}, ["c1"]))
        self.assertNotEqual(base, app_reset.projection(topology(), {"a": 2}, ["c1"]))
        self.assertNotEqual(base, app_reset.projection(topology(), {"a": 1}, ["c2", "c1"]))


class ResetTests(unittest.TestCase):
    def fresh(self, **kwargs):
        app = FakeApp(**kwargs)
        reset = app_reset.AppReset(app.rpc)
        return app, reset, reset.reset()

    def test_first_reset_is_the_fixture_and_sends_no_change(self):
        app, _, fixture = self.fresh()
        self.assertEqual(fixture, app_reset.projection(topology(), app.settings, ["daemon:old_1"]))
        self.assertEqual(actions(app), [])
        self.assertEqual([m for m, _ in app.calls if m.startswith("settings.s")], [])

    def test_reset_closes_what_the_case_made_and_restores_settings_focus_and_history(self):
        app, reset, fixture = self.fresh()
        app.new_tab()
        app.new_workspace()
        app.settings["ui"]["animations"]["enabled"] = True
        app.settings["sidebar"] = {"width": 300}
        del app.settings["appearance"]
        self.assertEqual(reset.reset(), fixture)
        sent = actions(app)
        self.assertIn(("closeTab", "tab:tab_2"), sent)
        self.assertIn(("closeWorkspace", "workspace:ws_2"), sent)
        self.assertIn(("goToWorkspace", None), sent)
        writes = [(m, p["path"]) for m, p in app.calls if m in ("settings.set", "settings.unset")]
        self.assertEqual(sorted(writes), [("settings.set", ["appearance"]), ("settings.set", ["ui", "animations", "enabled"]),
                                          ("settings.unset", ["sidebar"])])
        close = next(p for m, p in app.calls if m == "action.run" and p["action"] == "closeWorkspace")
        self.assertEqual(close["args"], {"confirm": True})  # action.list marks it destructive
        self.assertTrue(close["wait"])
        self.assertEqual(close["origin"], "script")
        # The reset's own closes went into the closed history; it forgot them, and kept the fixture's entry.
        self.assertEqual(app.closed, ["daemon:old_1"])

    def test_a_window_the_case_opened_closes_through_its_window_target(self):
        app, reset, fixture = self.fresh()
        app.new_window()
        self.assertEqual(reset.reset(), fixture)
        self.assertIn(("closeWindow", "window:win_2"), actions(app))

    def test_an_action_that_takes_no_target_is_never_sent_one(self):
        # The app before closeWindow took a window target: the reset asks for a fresh launch, it is no leak.
        catalog = [a if a["id"] != "closeWindow" else {"id": "closeWindow", "targets": []} for a in CATALOG]
        app, reset, _ = self.fresh(catalog=catalog)
        app.new_window()
        with self.assertRaises(app_reset.NeedsRelaunch) as caught:
            reset.reset()
        self.assertIn("closeWindow does not take a window target", str(caught.exception))
        self.assertNotIn("closeWindow", [a for a, _ in actions(app)])

    def test_a_tab_that_an_earlier_case_closed_is_not_reopened_by_the_next(self):
        # Two cases in one launch: the first opens and closes a tab, the second reopens the last closed item.
        app, reset, fixture = self.fresh()
        app.new_tab(tid="tab_7")
        app.close_tab("tab_7")
        self.assertEqual(reset.reset(), fixture)
        self.assertEqual(app.closed, ["daemon:old_1"], "the next case's Cmd-Shift-T would reopen tab_7")

    def test_a_case_that_reopens_a_fixture_entry_needs_a_relaunch(self):
        app, reset, _ = self.fresh()
        app.closed.remove("daemon:old_1")
        with self.assertRaises(app_reset.NeedsRelaunch):
            reset.reset()

    def test_a_rename_a_recolor_an_icon_and_a_zoom_go_back(self):
        app, reset, fixture = self.fresh()
        workspace = app.workspace("ws_1")
        workspace.update(name="renamed", color="red", icon="star")
        workspace["screens"][0]["zoomed_pane"] = "pane_1"
        self.assertEqual(app_reset.closes(fixture, reset.snapshot()), [])
        self.assertEqual(reset.reset(), fixture)
        sent = actions(app)
        for step in (("renameWorkspace", "workspace:ws_1"), ("palette.resetWorkspaceColor", "workspace:ws_1"),
                     ("workspace.clearIcon", "workspace:ws_1"), ("toggleSplitZoom", "pane:pane_1")):
            self.assertIn(step, sent)

    def test_a_color_the_catalog_does_not_offer_needs_a_relaunch(self):
        app = FakeApp()
        app.workspace("ws_1")["color"] = "#123456"
        reset = app_reset.AppReset(app.rpc)
        reset.reset()
        app.workspace("ws_1")["color"] = None
        with self.assertRaises(app_reset.NeedsRelaunch):
            reset.reset()

    def test_another_selected_tab_goes_back(self):
        app, reset, fixture = self.fresh()
        app.panes()[0]["selected_tab"] = "tab_3"
        self.assertEqual(reset.reset(), fixture)
        self.assertIn(("tab.focus", "tab:tab_1"), actions(app))

    def test_a_tab_reorder_needs_a_relaunch(self):
        app, reset, _ = self.fresh()
        app.panes()[0]["tabs"].reverse()
        with self.assertRaises(app_reset.NeedsRelaunch) as caught:
            reset.reset()
        self.assertIn("pane pane_1 tab order", str(caught.exception))

    def test_a_closed_fixture_tab_is_reopened_by_its_closed_id(self):
        app, reset, fixture = self.fresh()
        app.close_tab("tab_3")
        self.assertEqual(reset.reset(), fixture)
        reopen = [p for m, p in app.calls if m == "action.run" and p["action"] == "history.reopen"]
        self.assertEqual([p["args"] for p in reopen], [{"id": "daemon:closed_1"}])
        self.assertEqual(app.closed, ["daemon:old_1"])

    def test_a_fixture_tab_that_comes_back_under_another_id_needs_a_relaunch(self):
        app, reset, _ = self.fresh(reopen_keeps_ids=False)
        app.close_tab("tab_3")
        with self.assertRaises(app_reset.NeedsRelaunch) as caught:
            reset.reset()
        self.assertIn("tab:tab_3", str(caught.exception))

    def test_a_reset_that_cannot_close_returns_the_leaked_state(self):
        app, reset, fixture = self.fresh(ignore={"closeTab"})
        app.new_tab()
        self.assertNotEqual(reset.reset(), fixture)

    def test_a_lost_socket_is_unreachable_and_a_refused_read_is_not(self):
        app, reset, _ = self.fresh()
        app.lost = True
        with self.assertRaises(app_reset.ProductUnreachable) as caught:
            reset.reset()
        self.assertTrue(caught.exception.unreachable)
        refused = FakeApp(refuse={"snapshot.get"})
        with self.assertRaises(app_reset.ResetError) as caught:
            app_reset.AppReset(refused.rpc).reset()
        self.assertFalse(caught.exception.unreachable)
        self.assertIsNone(caught.exception.relaunch)

    def test_a_build_without_the_closed_history_read_has_no_fixture(self):
        with self.assertRaises(app_reset.ResetError):
            app_reset.AppReset(FakeApp(refuse={"debug.closed_ids"}).rpc).reset()

    def test_a_refused_escape_is_not_a_failure(self):
        app, reset, fixture = self.fresh()
        self.assertEqual(reset.reset(), fixture)
        self.assertEqual(sum(1 for m, _ in app.calls if m == "debug.key"), 3)

    def test_closes_are_outermost_first_and_groups_go_back(self):
        fixture = app_reset.projection(topology(), {})
        changed = topology()
        changed["workspace_groups"] = [{"id": "grp_new", "name": "g", "color": None, "collapsed": False}]
        changed["workspaces"][0]["group"] = "grp_new"
        changed["windows"].append({"id": "win_2", "workspaces": []})
        changed["workspaces"][0]["screens"][0]["panes"].append({"id": "pane_2", "dock": "right", "selected_tab": None,
                                                                "tabs": []})
        plan = app_reset.closes(fixture, app_reset.projection(changed, {}))
        self.assertEqual([a for a, _, _ in plan], ["closeWindow", "closePane", "workspaceGroup.ungroup"])


class SessionTests(unittest.TestCase):
    def test_shared_launch_session_runs_cases_on_one_launch_and_stops_it_on_close(self):
        app = FakeApp()
        launches = []

        def launch():
            launches.append(app)
            return app

        def run(target, case, ctx):
            target.new_tab(tid="tab_" + case["id"])
            return {"status": "Pass", "checkpoints": []}

        session = app_reset.SharedLaunchSession(launch, run)
        fixture = session.reset_state()
        for cid in ("a", "b", "c"):
            session.run_case({"id": cid}, {})
            self.assertEqual(session.reset_state(), fixture)
        session.close()
        self.assertEqual((len(launches), app.stopped), (1, 1))


if __name__ == "__main__":
    unittest.main()
