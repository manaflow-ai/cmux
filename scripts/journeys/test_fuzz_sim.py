#!/usr/bin/env python3
"""ext_fuzz.py's run against a simulated app (no fleet, no app): the oracles see what a real app's reads would say.

    python3 scripts/journeys/test_fuzz_sim.py

The simulated app answers the reads the fuzz makes (snapshot.get, debug.surfaces, debug.key, debug.focus,
debug.hangs, debug.toast, debug.desync, debug.dialog, debug.new_tab, the daemon's terminal list and screens) from a
small model of workspaces, panes and tabs. A correct app plays a seeded plan clean; each planted bug (the second Cmd-D
of a quick pair makes nothing, a new column narrows an old one, the daemon's grid differs from the app's, a stall in
cmux code, a closed terminal's PTY stays open) fails with its own oracle, and ddmin shrinks the failing plan.
"""
import itertools
import json
import os
import random
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))
import driver  # noqa: E402  (loads ext_*.py, ext_fuzz among them)
import ext_fuzz  # noqa: E402

ids = itertools.count(1)


class FakeApp:
    """A cmux-shaped app: windows have workspaces; a workspace has panes in columns; a pane has tabs."""

    def __init__(self, bugs=()):
        self.bugs = set(bugs)
        self.pid = 4242
        self.home = "/tmp"
        self.workspaces = []  # [{id, panes: [{id, column, width, tabs: [{id, kind, term}]}], focus_pane}]
        self.shown = None
        self.terms = {}  # term -> {"text": str, "open": bool}
        self.ptys = 0
        self.toasts = []
        self.hangs = []
        self.last_split = 0.0
        self.identity = {"bundle_id": "com.cmuxterm.app.debug.sim"}

    # -- model --
    def ws(self):
        return next((w for w in self.workspaces if w["id"] == self.shown), None)

    def new_term(self):
        term = f"term_{next(ids)}"
        self.terms[term] = {"text": "$ ", "open": True}
        self.ptys += 1
        return term

    def new_workspace(self, with_terminal=False):
        pane = {"id": f"pane_{next(ids)}", "column": 0, "width": 1200.0, "tabs": []}
        tab = {"id": f"tab_{next(ids)}", "kind": "terminal", "term": self.new_term()} if with_terminal else \
            {"id": f"tab_{next(ids)}", "kind": "page", "term": None}
        pane["tabs"].append(tab)
        pane["selected"] = tab["id"]
        ws = {"id": f"ws_{next(ids)}", "panes": [pane], "focus_pane": pane["id"]}
        self.workspaces.append(ws)
        self.shown = ws["id"]

    def focused_pane(self):
        ws = self.ws()
        return next((p for p in ws["panes"] if p["id"] == ws["focus_pane"]), None) if ws else None

    def close_tab_obj(self, ws, pane, tab):
        pane["tabs"].remove(tab)
        if tab["term"]:
            self.terms[tab["term"]]["open"] = False
            if "pty_leak" not in self.bugs:
                self.ptys -= 1
        if not pane["tabs"]:
            ws["panes"].remove(pane)
            if ws["panes"]:
                ws["focus_pane"] = ws["panes"][0]["id"]
            else:
                self.workspaces.remove(ws)
                self.shown = self.workspaces[-1]["id"] if self.workspaces else None
        else:
            pane["selected"] = pane["tabs"][-1]["id"]

    def key(self, key, mods):
        reply = self._key(key, mods)
        if "hold_path" in self.bugs and not mods and time.monotonic() - self.last_split < 0.3:
            return dict(reply or {}, handled_by="app")  # held by the router for the pane being made, then replayed
        return reply

    def _key(self, key, mods):
        mods = set(mods)
        pane = self.focused_pane()
        if key == "n" and mods == {"cmd"}:
            self.new_workspace()
        elif key == "`" and mods == {"control"}:
            if pane is None:
                self.new_workspace(with_terminal=True)
            else:
                tab = {"id": f"tab_{next(ids)}", "kind": "terminal", "term": self.new_term()}
                pane["tabs"].append(tab)
                pane["selected"] = tab["id"]
        elif key == "l" and mods == {"cmd", "shift"} and pane:
            if "late_close_browser" in self.bugs:
                for p in self.ws()["panes"]:
                    for tb in list(p["tabs"]):
                        if tb["kind"] == "browser" and len(p["tabs"]) > 1:
                            p["tabs"].remove(tb)
                            break
            tab = {"id": f"tab_{next(ids)}", "kind": "browser", "term": None}
            pane["tabs"].append(tab)
            pane["selected"] = tab["id"]
        elif key == "t" and mods == {"cmd"} and pane:
            tab = {"id": f"tab_{next(ids)}", "kind": "page", "term": None}
            pane["tabs"].append(tab)
            pane["selected"] = tab["id"]
        elif ((key == "d" and mods in ({"cmd"}, {"cmd", "shift"})) or (key == "l" and mods == {"control", "option", "cmd"})) and pane:
            if "second_split_lost" in self.bugs and time.monotonic() - self.last_split < 0.5:
                return {"handled_by": "keyRouter"}
            self.last_split = time.monotonic()
            if "other_toast" in self.bugs:
                self.toasts.append("The terminal could not start")
            if getattr(self, "hook", None):
                self.hook["started"] = self.hook.get("started", 0) + 1
            if "no_room" in self.bugs and getattr(self, "splits_made", 0) >= 1:
                self.toasts.append("Not enough room to split this column")
                return {"handled_by": "app"}
            self.splits_made = getattr(self, "splits_made", 0) + 1
            ws = self.ws()
            column = key == "l"  # New Column (Ctrl-Opt-Cmd-L) adds a column; Cmd-D and Cmd-Shift-D split inside one
            new = {"id": f"pane_{next(ids)}", "column": (max(p["column"] for p in ws["panes"]) + 1) if column else pane["column"],
                   "width": 600.0 if column else pane["width"],
                   "tabs": [{"id": f"tab_{next(ids)}", "kind": "terminal", "term": self.new_term()}]}
            new["selected"] = new["tabs"][0]["id"]
            if "late_close" in self.bugs and column and len(ws["panes"]) > 1:
                victim = next(p for p in ws["panes"] if p is not pane)
                for tab in list(victim["tabs"]):
                    self.close_tab_obj(ws, victim, tab)
            if "column_resize" in self.bugs and column:
                for p in ws["panes"]:
                    p["width"] -= 7
            if "split_resizes_other" in self.bugs and not column:
                for p in ws["panes"]:
                    if p["column"] != pane["column"]:
                        p["width"] -= 7
            ws["panes"].append(new)
            ws["focus_pane"] = new["id"]
            if "stall" in self.bugs:
                self.hangs.append({"sequence": len(self.hangs) + 1, "kind": "stall", "duration_ms": 180.0,
                                   "frame_details": [{"image": "cmux DEV", "symbol": "$s8CmuxNext12splitRight"}]})
        elif key == "w" and mods == {"cmd"} and pane:
            tab = next(t for t in pane["tabs"] if t["id"] == pane["selected"])
            self.close_tab_obj(self.ws(), pane, tab)
        elif key == "w" and mods == {"cmd", "shift"} and self.ws():
            self.close_workspace(self.ws()["id"])
        elif key.isdigit() and mods == {"cmd"}:
            n = int(key)
            if n <= len(self.workspaces):
                self.shown = self.workspaces[n - 1]["id"]
        elif not mods and key not in ("return",) and pane:
            tab = next(t for t in pane["tabs"] if t["id"] == pane["selected"])
            if tab["term"]:
                self.typed = getattr(self, "typed", "") + key
        elif key == "return" and pane:
            tab = next(t for t in pane["tabs"] if t["id"] == pane["selected"])
            line = getattr(self, "typed", "")
            self.typed = ""
            if "split_keys_to_last" in self.bugs and time.monotonic() - self.last_split < 0.5 and line.startswith("echo st"):
                self.held = getattr(self, "held", []) + [line]  # held while the pane is made, replayed later
                return {"handled_by": "keyRouter"}
            if tab["term"] and line.startswith("echo "):
                pane_cols = self.cols_of(pane)
                words = line[5:].replace("$(stty size)", "24 80" if "pty_mismatch" in self.bugs else f"30 {pane_cols}").split()
                self.terms[tab["term"]]["text"] += "\n" + line + "\n" + " ".join(words) + "\n$ "
        return {"handled_by": "keyRouter"}

    def close_workspace(self, wid):
        ws = next((w for w in self.workspaces if w["id"] == wid), None)
        if not ws:
            return
        for pane in list(ws["panes"]):
            for tab in list(pane["tabs"]):
                if ws in self.workspaces:
                    self.close_tab_obj(ws, pane, tab)

    # -- reads --
    def topology(self):
        wss = []
        for ws in self.workspaces:
            panes = [{"id": p["id"], "column": p["column"], "selected_tab": p["selected"],
                      "tabs": [{"id": t["id"], "kind": t["kind"], "terminal": t["term"], "terminal_key": t["term"] and "k" + t["term"],
                                "columns": self.cols_of(p) if t["term"] else None, "rows": 30 if t["term"] else None}
                               for t in p["tabs"]]} for p in ws["panes"]]
            wss.append({"id": ws["id"], "screens": [{"id": "s", "panes": panes}]})
        ws = self.ws()
        pane = self.focused_pane()
        return {"loaded": True, "daemon_state": "connected", "workspaces": wss,
                "focus": {"workspace": self.shown, "pane": pane and pane["id"], "tab": pane and pane["selected"]}}

    def cols_of(self, pane):
        return int((pane["width"] - 8) // 8)

    def surfaces(self):
        ws = self.ws()
        out = []
        xs, x = {}, 0.0
        for p in sorted(ws["panes"] if ws else [], key=lambda q: q["column"]):
            if p["column"] not in xs:
                xs[p["column"]] = x
                x += p["width"]
        for p in (ws["panes"] if ws else []):
            tab = next(t for t in p["tabs"] if t["id"] == p["selected"])
            if tab["term"]:
                cols = self.cols_of(p)
                out.append({"pane": p["id"], "terminal_id": "k" + tab["term"], "focused": p["id"] == ws["focus_pane"],
                            "visible": True, "blank": False, "text": self.terms[tab["term"]]["text"],
                            "surface": {"grid": f"{cols}x30", "fit_grid": f"{cols}x30", "drawn_grid": f"{cols}x30"},
                            "grid": {"window": "win_1", "cell_width": 8.0, "cell_height": 16.0, "origin_x": xs[p["column"]] + 4,
                                     "origin_y": 4.0, "frame_x": xs[p["column"]], "frame_y": 0.0, "frame_width": p["width"],
                                     "frame_height": 488.0}})
        return out

    def flush_held(self):
        """The planted TIP RED 1193: held lines run, all of them, in the pane focused when the hold ends."""
        held = getattr(self, "held", [])
        if held and time.monotonic() - self.last_split >= 0.5:
            pane = self.focused_pane()
            tab = next(t for t in pane["tabs"] if t["id"] == pane["selected"])
            for line in held:
                self.terms[tab["term"]]["text"] += "\n" + line + "\n" + line[5:] + "\n$ "
            self.held = []

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        self.flush_held()
        if method == "snapshot.get":
            return {"topology": self.topology()}
        if method == "debug.surfaces":
            return {"windows": [{"window": 1, "panes": self.surfaces()}]}
        if method == "debug.key":
            return self.key(params["key"], params.get("modifiers") or [])
        if method == "debug.focus":
            pane = self.focused_pane()
            return {"windows": [{"id": "win_1", "is_key": True, "consistent": True, "mismatches": [],
                                 "model": {"resolved": "terminal"},
                                 "appkit": {"first_responder": "TerminalSurfaceView",
                                            "classified": f"content:{pane['id']}" if pane else "windowOrNone"}}]}
        if method == "debug.hangs":
            return {"records": [h for h in self.hangs if h["sequence"] > int(params.get("after") or 0)]}
        if method in ("debug.creation.hold", "debug.creation.release"):
            if "hook" not in self.bugs:
                raise driver.StepError(f"{method}: {{'code': 'method_not_found'}}")
            if method.endswith("hold"):
                self.hook = {"armed": [1], "started": 0, "stand_in": list((params or {}).get("stand_in") or [])}
                return {"armed": [1], "started": 0, "held": [], "released": [], "resumed": [], "shown": [],
                        "stand_in": self.hook["stand_in"]}
            hk = getattr(self, "hook", {"started": 0})
            resumed = [1] if hk.get("started", 0) >= 1 else []
            shown = [] if "old_hook" in self.bugs else [n for n in hk.get("stand_in", []) if hk.get("started", 0) >= n]
            self.hook = {}
            return {"armed": [], "started": hk.get("started", 0), "held": [], "released": [1], "resumed": resumed,
                    "shown": shown}
        if method == "debug.toast":
            return {"refusals": list(self.toasts)}
        if method == "debug.desync":
            if "desync" in self.bugs and self.ws():
                return {"check": {"violations": [{"invariant": "W1", "detail": f"appkit content:{self.ws()['panes'][0]['id']} (PageWebView) != model agentPage"}]}}
            return {"check": {"violations": []}}
        if method == "debug.dialog":
            return {"dialogs": []}
        if method == "debug.new_tab":
            return {"focused": True, "text": ""}
        if method == "debug.crashes":
            return {"launch": {"recovery": "clean"}}
        if method == "action.run":
            if params.get("action") == "closeWorkspace":
                self.close_workspace(params["target"].split(":", 1)[1])
            elif params.get("action") == "closePane":
                pane = self.focused_pane()
                if pane:
                    for tab in list(pane["tabs"]):
                        self.close_tab_obj(self.ws(), pane, tab)
            return {"ok": True}
        return {}

    def cmux(self, *args, timeout=30):
        if args[:2] == ("terminal", "list"):
            return [{"id": t, "lifecycle": "live" if v["open"] else "exited"} for t, v in self.terms.items()]
        raise driver.StepError(f"cmux {args}")

    def screen(self, term):
        cols = 100
        for p in self.surfaces():
            if p["terminal_id"] == "k" + term:
                cols = int(p["surface"]["grid"].split("x")[0])
        if "grid_mismatch" in self.bugs:
            cols += 1
        return {"text": self.terms[term]["text"], "cols": cols, "rows": 30}

    def bundle_processes(self, pid):
        return []

    def alive(self, pid):
        return True

    def panes(self):
        return self.surfaces()


class SimJourney:
    """The parts of driver.Journey the fuzz uses, over FakeApp."""

    def __init__(self, app, out):
        self.app, self.out, self.nonce, self.deadline = app, Path(out), "424242", driver.now() + 120
        self.spec = {"options": {}}
        self.marks, self.key_window = {}, None
        self.smoke_key_ok = True  # the sim's window is key (normal mode)

    def key(self, key, mods, window=None):
        self.last_key_at = driver.now()
        return self.app.rpc("debug.key", {"key": key, "modifiers": mods})

    def topology(self):
        return self.app.rpc("snapshot.get")["topology"]

    def outwait_creation_hold(self, since):
        return 0.0

    places = staticmethod(driver.Journey.places)

    def sub(self, value):
        return value


def run(bugs=(), seq=None, seed=5, count=40, shrink=True, actions="full"):
    ext_fuzz.counts = lambda j: {"fds": 50, "processes": 2, "helpers": 0, "ptys": j.app.ptys}
    saved = (ext_fuzz.CREATE_TIMEOUT, ext_fuzz.SETTLE, ext_fuzz.LEAK_SETTLE, ext_fuzz.SPLIT_LINES_TIMEOUT)
    ext_fuzz.CREATE_TIMEOUT, ext_fuzz.SETTLE, ext_fuzz.LEAK_SETTLE, ext_fuzz.SPLIT_LINES_TIMEOUT = 0.3, 0.1, 0.1, 1.5
    try:
        j = SimJourney(FakeApp(bugs), tempfile.mkdtemp())
        weights = {"resize_window": 0, "drag_divider": 0, "relaunch": 0, "paste": 0, "open_url": 0}
        step = {"seed": seed, "count": count, "budget_s": 60, "shrink": shrink, "weights": weights, "set": actions}
        if seq is not None:
            step["sequence"] = seq
        try:
            ext_fuzz.step_fuzz_run(j, step)
        except driver.StepError as error:
            return j.fuzz_report, str(error)
        return j.fuzz_report, None
    finally:
        ext_fuzz.CREATE_TIMEOUT, ext_fuzz.SETTLE, ext_fuzz.LEAK_SETTLE, ext_fuzz.SPLIT_LINES_TIMEOUT = saved


class Sim(unittest.TestCase):
    def test_normal_mode_without_a_key_window_is_not_run(self):
        j = SimJourney(FakeApp(), tempfile.mkdtemp())
        j.smoke_key_ok = False
        with self.assertRaises(driver.NotRun):
            ext_fuzz.Fuzz(j, {"seed": 1, "count": 5})
        j.spec = {"options": {"fuzz_mode": "diagnostic"}}
        ext_fuzz.Fuzz(j, {"seed": 1, "count": 5})  # diagnostic: runs


    def test_correct_app_is_clean(self):
        for seed in (1, 2, 3):
            report, error = run(seed=seed)
            self.assertIsNone(error, json.dumps(report["log"][-3:])[:1500])
            self.assertGreater(report["played"], 20)
            self.assertTrue(report["speed"])

    def test_layout_set_is_clean_and_uses_only_layout_actions(self):
        for seed in (11, 12, 13):
            report, error = run(seed=seed, actions="layout")
            self.assertIsNone(error, json.dumps(report["log"][-3:])[:1500])
            used = {i["a"] for b in report["log"] for i in b["burst"]}
            self.assertLessEqual(used, set(ext_fuzz.SETS["layout"]) | {"close_all"})
            self.assertIn("new_column", used)

    def test_split_and_type_at_once_is_clean_on_a_correct_app(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "split_type", "t": "slow", "down": [False, True]}]
        report, error = run(seq=seq, shrink=False, actions="layout")
        self.assertIsNone(error, json.dumps(report["log"][-2:])[:1500])
        rec = report["log"][-1]["recs"][0]
        self.assertEqual(len(rec["split_lines"]), 2)

    def test_split_type_on_a_page_is_skipped_not_a_create_red(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "new_tab", "t": "slow"}, {"a": "split_type", "t": "slow"}]
        report, error = run(seq=seq, shrink=False, actions="full")
        self.assertIsNone(error, json.dumps(report["log"][-1:])[:800])
        self.assertTrue(report["log"][-1]["recs"][0].get("skipped"))

    def test_split_type_counts_the_hold_path(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "split_type", "t": "slow"}, {"a": "split_type", "t": "slow"}]
        report, error = run(seq=seq, shrink=False, actions="layout")
        self.assertIsNone(error)
        self.assertEqual({k: report["split_type"][k] for k in ("played", "hold", "red", "pass_hold", "pass_not_judged")},
                         {"played": 2, "hold": 0, "red": 0, "pass_hold": 0, "pass_not_judged": 2})
        report, error = run(bugs={"hold_path"}, seq=seq, shrink=False, actions="layout")
        self.assertIsNone(error, json.dumps(report["log"][-1:])[:800])
        self.assertEqual(report["split_type"]["hold"], 2)
        self.assertEqual(report["split_type"]["pass_hold"], 2)
        self.assertTrue(report["log"][-1]["recs"][0]["hold_path"])

    def test_a_late_close_does_not_hide_a_create(self):
        app_holder = {}
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "new_column", "t": "slow"}, {"a": "new_column", "t": "slow"}]
        report, error = run(bugs={"late_close"}, seq=seq, shrink=False, actions="layout")
        self.assertIsNone(error, json.dumps(report["log"][-1:])[:800])

    def test_creation_hold_hook_proves_the_hold_every_round(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "split_type", "t": "slow"}, {"a": "split_type", "t": "slow"}]
        report, error = run(bugs={"hook"}, seq=seq, shrink=False, actions="layout")
        self.assertIsNone(error, json.dumps(report["log"][-1:])[:800])
        st = report["split_type"]
        self.assertEqual((st["played"], st["hold"], st["creation_hold"], st["pass_hold"]), (2, 2, 2, 2))
        report, error = run(seq=seq, shrink=False, actions="layout")  # no hook: the plain variant
        self.assertEqual((report["split_type"]["creation_hold"], report["split_type"]["played"]), (0, 2))

    def test_a_hook_without_the_stand_in_is_not_a_proven_hold(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "split_type", "t": "slow"}]
        report, error = run(bugs={"hook", "old_hook"}, seq=seq, shrink=False, actions="layout")
        st = report["split_type"]
        self.assertEqual((st["creation_hold"], st["hold"], st["pass_hold"], st["pass_not_judged"]), (1, 0, 0, 1))

    def test_a_refused_split_is_not_judged(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "split_type", "t": "slow"}]
        report, error = run(bugs={"no_room"}, seq=seq, shrink=False, actions="layout")
        self.assertIsNone(error, json.dumps(report["log"][-1:])[:800])
        self.assertEqual((report["split_type"]["refused"], report["split_type"]["red"]), (1, 0))

    def test_an_unrelated_refusal_does_not_hide_a_split_type_red(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "split_type", "t": "slow"}]
        report, error = run(bugs={"split_keys_to_last", "other_toast"}, seq=seq, shrink=False, actions="layout")
        self.assertEqual(report["failure"]["oracle"], "keys", report["failure"])

    def test_a_late_browser_close_does_not_hide_a_browser_create(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "open_url", "t": "slow"}, {"a": "open_url", "t": "slow"}]
        report, error = run(bugs={"late_close_browser"}, seq=seq, shrink=False, actions="full")
        self.assertIsNone(error, json.dumps(report["log"][-1:])[:800])

    def test_split_type_red_is_counted_on_either_path(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "split_type", "t": "slow"}]
        report, error = run(bugs={"split_keys_to_last"}, seq=seq, shrink=False, actions="layout")
        self.assertEqual(report["split_type"]["red"], 1)  # a keys red
        report, error = run(bugs={"second_split_lost"}, seq=seq, shrink=False, actions="layout")
        self.assertEqual(report["failure"]["oracle"], "create")
        self.assertEqual((report["split_type"]["played"], report["split_type"]["red"]), (1, 1))  # a create red
        self.assertEqual(report["split_type"]["pass_hold"] + report["split_type"]["pass_not_judged"], 0)

    def test_both_lines_in_the_second_pane_is_a_keys_red(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "split_type", "t": "slow", "down": [False, False]}]
        report, error = run(bugs={"split_keys_to_last"}, seq=seq, shrink=False, actions="layout")
        self.assertIsNotNone(report["failure"], error)
        self.assertEqual(report["failure"]["oracle"], "keys", report["failure"])
        self.assertIn("split + type at once", report["failure"]["detail"])

    def test_second_split_lost_is_a_create_failure_and_shrinks(self):
        seq = [{"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"}, {"a": "type_line", "t": "slow"},
               {"a": "new_tab", "t": "slow"}, {"a": "split_right", "t": "pair"}, {"a": "split_right", "t": "slow"}]
        report, error = run(bugs={"second_split_lost"}, seq=seq)
        self.assertIsNotNone(error)
        self.assertEqual(report["failure"]["oracle"], "create")
        self.assertIn("split_right", json.dumps(report["shrunk"]))
        self.assertLess(len(report["shrunk"]), len(seq))

    def test_column_resize_is_r3b(self):
        report, error = run(bugs={"column_resize"}, seq=ext_fuzz.CORPUS["lawrence-column-widths"], shrink=False)
        self.assertEqual(report["failure"]["oracle"], "r3b", error)

    def test_split_inside_a_column_that_resizes_another_column_is_r3b(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "new_column", "t": "slow"}, {"a": "split_right", "t": "slow"}]
        report, error = run(bugs={"split_resizes_other"}, seq=seq, shrink=False, actions="layout")
        self.assertEqual(report["failure"]["oracle"], "r3b", error)
        self.assertIn("a split inside another column", report["failure"]["detail"])

    def test_split_alone_is_not_r3b(self):
        seq = [{"a": "new_terminal", "t": "slow"}, {"a": "new_column", "t": "slow"}, {"a": "split_right", "t": "pair"},
               {"a": "split_down", "t": "slow"}]
        report, error = run(seq=seq, shrink=False, actions="layout")
        self.assertIsNone(error)

    def test_plan_starts_a_burst_at_new_column(self):
        for burst in ext_fuzz.bursts(ext_fuzz.plan(77, 600, actions="layout")):
            for k, item in enumerate(burst):
                if item["a"] == "new_column" and k:
                    self.assertEqual(burst[k - 1]["a"], "new_column")

    def test_grid_mismatch_is_r3a(self):
        report, error = run(bugs={"grid_mismatch"}, seq=ext_fuzz.CORPUS["lawrence-cmd-d-twice"], shrink=False)
        self.assertEqual(report["failure"]["oracle"], "r3a", error)

    def test_pty_size_mismatch_is_r3a(self):
        report, error = run(bugs={"pty_mismatch"}, seq=ext_fuzz.CORPUS["lawrence-ctrl-backtick-twice"], shrink=False)
        self.assertEqual(report["failure"]["oracle"], "r3a", error)

    def test_stall_in_cmux_code_is_a_finding(self):
        report, error = run(bugs={"stall"}, seq=ext_fuzz.CORPUS["lawrence-column-widths"], shrink=False)
        self.assertIsNone(report["failure"], error)
        self.assertEqual([f["oracle"] for f in report["findings"]], ["stall"])

    def test_desync_is_recorded_once_and_the_run_goes_on(self):
        report, error = run(bugs={"desync"}, seed=3, count=40)
        self.assertIsNone(report["failure"])
        self.assertGreater(report["played"], 30)
        self.assertEqual(len(report["findings"]), 1)
        self.assertEqual(report["findings"][0]["oracle"], "desync")
        self.assertGreater(report["findings"][0]["count"], 1)

    def test_daemon_agrees_does_not_count_a_desync_finding_again(self):
        j = SimJourney(FakeApp({"desync"}), tempfile.mkdtemp())
        ext_fuzz.counts = lambda jj: {"fds": 50, "processes": 2, "helpers": 0, "ptys": jj.app.ptys}
        saved = (ext_fuzz.CREATE_TIMEOUT, ext_fuzz.SETTLE)
        ext_fuzz.CREATE_TIMEOUT, ext_fuzz.SETTLE = 0.3, 0.1
        try:
            ext_fuzz.step_fuzz_run(j, {"sequence": [{"a": "new_terminal", "t": "slow"}], "budget_s": 30})
        finally:
            ext_fuzz.CREATE_TIMEOUT, ext_fuzz.SETTLE = saved
        self.assertTrue(j.fuzz_report["findings"])
        ok, detail = ext_fuzz.cond_fuzz_daemon_agrees(j, {}, {})
        self.assertTrue(ok, detail)

    def test_pty_leak_after_close_all(self):
        seq = [{"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"}, {"a": "close_all", "t": "slow"},
               {"a": "new_workspace", "t": "slow"}, {"a": "new_terminal", "t": "slow"}, {"a": "close_all", "t": "slow"}]
        report, error = run(bugs={"pty_leak"}, seq=seq, shrink=False)
        self.assertEqual(report["failure"]["oracle"], "leak", error)


if __name__ == "__main__":
    unittest.main()
