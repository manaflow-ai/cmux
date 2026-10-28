#!/usr/bin/env python3
"""session_io.py against a fake app with a real split tree (no app): the tree read from pane frames, the
export holds no user text, the validator refuses text, and export -> import into a fresh app -> export keeps
the digest, for a hand-made layout and for STRESS as perf-stress-session.py builds it.

  python3 -m unittest scripts/perf-lab/tests/test_session_io.py
"""
from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("session_io", LAB / "corpus" / "session_io.py")
session_io = importlib.util.module_from_spec(spec)
sys.modules["session_io"] = session_io
spec.loader.exec_module(session_io)
stress = session_io.load_stress()

AREA = (1600.0, 1000.0)  # the layout area, window points
DIVIDER = 4.0
PRIVATE = ("secret-title", "/Users/someone/private", "https://private.example/path", "my workspace name")


class FakeClock:
    """The builder's `time`: a sleep advances the clock, so a bounded wait that never succeeds ends at once."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 0.01)


class TreeApp:
    """Enough of the control socket for the builder and session_io, with a split tree per workspace:

    * splitRight / splitDown put the new pane right after its pane in a container of that direction (a new
      container when the pane's parent splits the other way). A shown workspace's container is sized evenly; a
      hidden one's split only halves its pane (no content controller).
    * equalizeSplits evens every container of a shown workspace and is refused for a hidden one.
    * debug.layers reports the shown workspace's pane frames with AppKit's bottom-left origin, and the engine of
      each pane whose selected tab is a browser. The topology never says a browser tab's engine.
    * Tabs carry a title, a cwd and a URL (text an export must drop).
    * `lag`: after a goToWorkspace, that many debug.layers reads give the new workspace's panes zero-size frames
      and a plane out of sync (the layout pass has not run). `unsettled`: workspaces that never lay out.
    * `chromium="webkit"`: openBrowser.chromium opens a WebKit page; `cef` is the debug.cef reply.
    * `docked`: pane ids the topology reports with a `dock`."""

    def __init__(self, chat="opens", frame=(160, 50, 1600, 1000), lag=0, chromium="cef", cef=None):
        self.clock = None
        self.chat = chat
        self.lag, self.lagging = lag, 0
        self.unsettled = set()
        self.chromium = chromium
        self.cef = cef or {"state": "ready", "unavailable": None, "fallback": None}
        self.docked = set()
        self.next = 0
        self.workspaces = []  # {"id", "name", "tree"}
        self.panes = {}  # id -> {"id", "tabs": [...], "selected": tab id}
        self.shown = None
        self.focused_pane = None
        self.frame = list(frame)
        self.sent = {}
        self.new_workspace()  # the launch workspace: one terminal, shown

    def ident(self, prefix):
        self.next += 1
        return f"{prefix}_{self.next}"

    # Model.

    def new_tab(self, kind, engine=None, page=None):
        return {"id": self.ident("tab"), "kind": kind, "engine": engine, "page": page, "title": PRIVATE[0],
                "cwd": PRIVATE[1], "url": PRIVATE[2] if kind == "browser" else None}

    def new_pane(self):
        tab = self.new_tab("terminal")
        pane = {"id": self.ident("pane"), "tabs": [tab], "selected": tab["id"]}
        self.panes[pane["id"]] = pane
        return pane

    def new_workspace(self):
        pane = self.new_pane()
        workspace = {"id": self.ident("ws"), "name": PRIVATE[3], "tree": {"pane": pane["id"], "weight": 1.0}}
        self.workspaces.append(workspace)
        self.shown, self.focused_pane = workspace["id"], pane["id"]
        return workspace

    @staticmethod
    def leaves(node):
        return [node["pane"]] if "pane" in node else [p for c in node["children"] for p in TreeApp.leaves(c)]

    def owner(self, pane_id):
        return next((w for w in self.workspaces if pane_id in self.leaves(w["tree"])), None)

    def pane_of_tab(self, tab_id):
        return next((p for p in self.panes.values() if any(t["id"] == tab_id for t in p["tabs"])), None)

    def parent(self, node, pane_id):
        for child in node.get("children") or []:
            if child.get("pane") == pane_id:
                return node
            found = self.parent(child, pane_id)
            if found:
                return found
        return None

    def split(self, workspace, pane_id, direction):
        new = self.new_pane()
        parent = self.parent(workspace["tree"], pane_id)
        if parent is None or parent["split"] != direction:
            holder = parent["children"] if parent else None
            index = next(i for i, c in enumerate(holder) if c.get("pane") == pane_id) if holder else None
            old = holder[index] if holder else workspace["tree"]
            container = {"split": direction, "weight": old["weight"],
                         "children": [{"pane": pane_id, "weight": 0.5}, {"pane": new["id"], "weight": 0.5}]}
            if holder:
                holder[index] = container
            else:
                workspace["tree"] = container
            parent = container
        else:
            index = next(i for i, c in enumerate(parent["children"]) if c.get("pane") == pane_id)
            leaf = parent["children"][index]
            leaf["weight"] /= 2
            parent["children"].insert(index + 1, {"pane": new["id"], "weight": leaf["weight"]})
        if workspace["id"] == self.shown:
            for child in parent["children"]:
                child["weight"] = 1.0 / len(parent["children"])
        return new

    def equalize(self, node):
        for child in node.get("children") or []:
            child["weight"] = 1.0 / len(node["children"])
            self.equalize(child)

    def frames(self, node, x, top, w, h, out):
        """Pane frames of `node` in the rect (x, top, w, h), top-down; written bottom-left as AppKit does."""
        if "pane" in node:
            out[node["pane"]] = [x, AREA[1] - top - h, w, h]
            return
        total = (w if node["split"] == "right" else h) - DIVIDER * (len(node["children"]) - 1)
        offset = 0.0
        for child in node["children"]:
            size = total * child["weight"]
            if node["split"] == "right":
                self.frames(child, x + offset, top, size, h, out)
            else:
                self.frames(child, x, top + offset, w, size, out)
            offset += size + DIVIDER

    # Wire.

    def topology(self):
        def tab_json(tab):
            fields = {k: v for k, v in tab.items() if k != "engine"}
            if tab["kind"] == "page":
                fields["kind"] = "page"
            return fields

        workspaces = [{"id": w["id"], "name": w["name"], "title": PRIVATE[3], "screens": [{"id": "screen_1", "zoomed_pane": None,
                       "panes": [{"id": p, "selected_tab": self.panes[p]["selected"], "column": None,
                                  "dock": "left" if p in self.docked else None,
                                  "tabs": [tab_json(t) for t in self.panes[p]["tabs"]]} for p in self.leaves(w["tree"])]}]}
                      for w in self.workspaces]
        windows = [{"id": "win_1", "key": "win_1", "workspace": self.shown, "focused_pane": self.focused_pane, "visible": True}]
        return {"topology": {"workspaces": workspaces, "windows": windows,
                             "focus": {"window": "win_1", "workspace": self.shown, "pane": self.focused_pane}}}

    def layers(self):
        workspace = next(w for w in self.workspaces if w["id"] == self.shown)
        frames = {}
        self.frames(workspace["tree"], 0.0, 0.0, AREA[0], AREA[1], frames)
        browsers = []
        for pane_id in frames:
            pane = self.panes[pane_id]
            tab = next(t for t in pane["tabs"] if t["id"] == pane["selected"])
            if tab["kind"] == "browser":
                browsers.append({"pane": pane_id, "engine": tab["engine"]})
        laid_out = not self.lagging and workspace["id"] not in self.unsettled
        self.lagging = max(self.lagging - 1, 0)
        if not laid_out:
            frames = {p: [0.0, 0.0, 0.0, 0.0] for p in frames}
        rings = [{"pane": p, "frame_in_window": f} for p, f in frames.items()]
        planes = [{"in_sync": laid_out, "rings": rings}]
        return {"windows": [{"id": "win_1", "frame": list(self.frame), "planes": planes, "browsers": browsers,
                             "divider_areas_in_window": [], "screen_visible_frame": [0, 0, 1920, 1170],
                             "screen_frame": [0, 0, 1920, 1200]}]}

    def add(self, pane, tab, beside=None):
        """`tab` after `beside` (the targeted tab), else after the selected one; it becomes selected."""
        index = next(i for i, t in enumerate(pane["tabs"]) if t["id"] == (beside or pane["selected"]))
        pane["tabs"].insert(index + 1, tab)
        pane["selected"] = tab["id"]

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "snapshot.get":
            return self.topology()
        if method == "debug.layers":
            return self.layers()
        if method == "debug.cef":
            return dict(self.cef)
        if method == "debug.screens":
            return {"windows": []}
        if method == "debug.window_frame":
            if params.get("frame"):
                self.frame = list(params["frame"])
            return {"frame": list(self.frame), "screen": "fake", "visible_frame": [0, 0, 1920, 1170], "screen_frame": [0, 0, 1920, 1200]}
        if method == "settings.set":
            return {}
        if method != "action.run":
            return {"error": {"code": "method_not_found"}}
        action, target, args = params.get("action"), params.get("target") or "", params.get("args") or {}
        if action == "workspace.newAtBottom":
            self.new_workspace()
            return {}
        if action == "goToWorkspace":
            self.shown, self.focused_pane = args["workspace"], None
            self.lagging = self.lag
            return {}
        if target.startswith("tab:"):
            pane = self.pane_of_tab(target[len("tab:"):])
        elif target.startswith("pane:"):
            pane = self.panes.get(target[len("pane:"):])
        else:
            pane = self.panes.get(self.focused_pane)
        if pane is None:
            return {"error": {"code": "not_found", "data": {"reason": f"{target} not found"}}}
        workspace = self.owner(pane["id"])
        hidden = workspace["id"] != self.shown
        beside = target[len("tab:"):] if target.startswith("tab:") else None
        if action in ("equalizeSplits", "palette.newAgentChat", "newTab.page") and hidden:
            return {"error": {"code": "not_found", "data": {"reason": f"{target} is not shown in any window."}}}
        if action == "pane.focus":
            self.focused_pane = pane["id"]
        elif action in ("splitRight", "splitDown"):
            self.split(workspace, pane["id"], "right" if action == "splitRight" else "down")
        elif action == "equalizeSplits":
            self.equalize(workspace["tree"])
        elif action == "newSurface":
            self.add(pane, self.new_tab("terminal"), beside)
        elif action in ("openBrowser", "openBrowser.chromium", "openBrowser.webkit"):
            engine = "webkit" if action.endswith("webkit") or (action.endswith("chromium") and self.chromium == "webkit") else "cef"
            self.add(pane, self.new_tab("browser", engine=engine), beside)
        elif action == "palette.newAgentChat":
            if self.chat == "refused":
                return {"error": {"code": "unavailable", "data": {"reason": "agent launch denied"}}}
            self.add(pane, self.new_tab("conversation"))
        elif action == "newTab.page":
            self.add(pane, self.new_tab("page", page="new-tab"))
        elif action == "tab.focus":
            pane["selected"] = target[len("tab:"):]
            self.shown, self.focused_pane = workspace["id"], pane["id"]
        elif action == "closeTab":
            tab = target[len("tab:"):]
            index = next(i for i, t in enumerate(pane["tabs"]) if t["id"] == tab)
            pane["tabs"].pop(index)
            if pane["selected"] == tab:
                pane["selected"] = pane["tabs"][max(index - 1, 0)]["id"]
        elif action == "terminal.sendText":
            self.sent.setdefault(target[len("tab:"):], []).append(args.get("text"))
        return {}


def fresh_app(**options):
    app = TreeApp(**options)
    app.clock = stress.time = FakeClock()  # the builder's waits end at once on the fake
    return app


def leaf(tabs, selected=None):
    return {"tabs": tabs, "selected": len(tabs) - 1 if selected is None else selected}


# A layout with both nestings: rows inside columns and columns inside a row, browsers of each engine, a chat,
# a New Tab page, a pane whose first tab is no terminal, a selected tab that is not the last one, two busy terminals.
MIXED = {
    "schema": session_io.SCHEMA, "window": [1600, 1000], "shown": 2, "focused_pane": 3,
    "busy": [[2, 0, 0], [2, 4, 1]],
    "workspaces": [
        {"tree": leaf(["terminal"]), "even": True},
        {"tree": leaf(["terminal", "chromium", "chromium"]), "even": True},
        {"even": True, "tree": {"split": "right", "children": [
            {"split": "down", "children": [leaf(["terminal", "webkit"], 0), leaf(["terminal", "chat"])]},
            leaf(["chromium", "page:new-tab"], 0),
            {"split": "down", "children": [
                {"split": "right", "children": [leaf(["terminal"]), leaf(["terminal", "terminal", "browser"], 1)]},
                leaf(["terminal", "chromium", "webkit", "chat", "terminal"]),
            ]},
        ]}},
        {"tree": leaf(["terminal", "terminal"]), "even": True},
    ],
}


class Case(unittest.TestCase):
    def setUp(self):
        self.builders = []

    def tearDown(self):
        for made in self.builders:
            made.close()

    def keep(self, made):
        self.builders.append(made)
        return made


class TreeFromFramesTests(Case):
    def test_columns_of_rows_with_a_nested_split_in_bottom_left_coordinates(self):
        # Two columns; the right one stacked top to bottom: a, then b | c side by side.
        frames = {"L": [0, 0, 800, 1000], "a": [804, 502, 796, 498], "b": [804, 0, 396, 498], "c": [1204, 0, 396, 498]}
        tree, even, order = session_io.tree_from_frames(frames, lambda pane: {"tabs": [pane], "selected": 0})
        self.assertEqual(order, ["L", "a", "b", "c"], "rows are read top first (AppKit's y grows upward)")
        self.assertEqual(tree, {"split": "right", "children": [
            {"tabs": ["L"], "selected": 0},
            {"split": "down", "children": [{"tabs": ["a"], "selected": 0},
                                           {"split": "right", "children": [{"tabs": ["b"], "selected": 0}, {"tabs": ["c"], "selected": 0}]}]}]})
        self.assertTrue(even)

    def test_uneven_shares_are_reported(self):
        frames = {"a": [0, 0, 1200, 1000], "b": [1204, 0, 396, 1000]}
        _, even, _ = session_io.tree_from_frames(frames, lambda pane: {"tabs": ["terminal"], "selected": 0})
        self.assertFalse(even)

    def test_frames_no_split_tree_makes_are_refused(self):
        # A pinwheel: no cut runs across the whole area.
        frames = {"a": [0, 0, 600, 400], "b": [600, 0, 400, 600], "c": [400, 600, 600, 400], "d": [0, 400, 400, 600],
                  "e": [400, 400, 200, 200]}
        with self.assertRaises(session_io.LayoutSnapshotError):
            session_io.tree_from_frames(frames, lambda pane: {"tabs": ["terminal"], "selected": 0})

    def test_frames_of_a_layout_pass_that_has_not_run_are_refused(self):
        cases = {
            "all zero": {"a": [0, 0, 0, 0], "b": [0, 0, 0, 0], "c": [0, 0, 0, 0]},
            "one with no width": {"a": [0, 0, 800, 1000], "b": [804, 0, 0, 1000]},
            "overlapping": {"a": [0, 0, 1000, 1000], "b": [500, 0, 1100, 1000]},
            "a gap no pane covers": {"a": [0, 0, 600, 1000], "b": [1000, 0, 600, 1000]},
            "a pane short of its column": {"a": [0, 0, 800, 1000], "b": [804, 500, 796, 500]},
            "not a frame": {"a": [0, 0, 800], "b": [804, 0, 796, 1000]},
        }
        for name, frames in cases.items():
            with self.assertRaises(session_io.LayoutSnapshotError, msg=name):
                session_io.tree_from_frames(frames, lambda pane: {"tabs": ["terminal"], "selected": 0})


class ValidateTests(Case):
    def test_the_mixed_layout_is_valid_and_importable(self):
        self.assertEqual(session_io.validate(MIXED), [])
        self.assertEqual(session_io.importable(MIXED), [])

    def test_text_payloads_are_refused(self):
        cases = {
            "a title key": lambda s: s["workspaces"][0].update(name="my workspace name"),
            "a tab kind with text": lambda s: s["workspaces"][0]["tree"].update(tabs=["terminal:ls -la"]),
            "a page with a title": lambda s: s["workspaces"][0]["tree"].update(tabs=["page:My Notes"]),
            "a url key on a pane": lambda s: s["workspaces"][1]["tree"].update(url="https://example.com"),
            "a key at the top": lambda s: s.update(cwd="/Users/someone"),
            "a string where an index belongs": lambda s: s.update(shown="ws_3"),
            "a list in a busy entry": lambda s: s.update(busy=[[0, [1], 0]]),
            "a list where the split belongs": lambda s: s["workspaces"][2]["tree"].update(split=["x"]),
        }
        for name, change in cases.items():
            snapshot = copy.deepcopy(MIXED)
            change(snapshot)
            self.assertNotEqual(session_io.validate(snapshot), [], f"{name} was accepted")
            with self.assertRaises(session_io.LayoutSnapshotError):
                session_io.check(snapshot)

    def test_a_busy_entry_must_be_a_terminal(self):
        snapshot = copy.deepcopy(MIXED)
        snapshot["busy"] = [[1, 0, 1]]  # a Chromium tab
        self.assertTrue(any("not a terminal" in p for p in session_io.validate(snapshot)))

    def test_uneven_or_other_window_snapshots_are_not_importable(self):
        snapshot = copy.deepcopy(MIXED)
        snapshot["workspaces"][2]["even"] = False
        snapshot["window"] = [1200, 800]
        problems = session_io.importable(snapshot)
        self.assertTrue(any("uneven" in p for p in problems) and any("bench window" in p for p in problems), problems)

    def test_the_file_round_trips_with_its_digest(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "layout.json")
            written = session_io.write(MIXED, path)
            self.assertEqual(session_io.digest(session_io.read(path)), written)
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                self.assertEqual(session_io.main(["digest", path]), 0)
            self.assertEqual(printed.getvalue().split()[0], written)

    def test_the_digest_is_the_sha256_of_the_file(self):
        # The corpus manifest names a blob by the sha256 of its file bytes (manifest.py blob_ref).
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "layout.json")
            written = session_io.write(MIXED, path)
            with open(path, "rb") as handle:
                self.assertEqual(hashlib.sha256(handle.read()).hexdigest(), written)
            self.assertEqual(session_io.digest(MIXED), written)


class RoundTripTests(Case):
    def test_an_import_reproduces_the_mixed_layout_and_drops_no_structure(self):
        app = fresh_app()
        made, again = session_io.roundtrip(app.rpc, MIXED, log=lambda line: None)
        self.keep(made)
        self.assertEqual(session_io.digest(again), session_io.digest(MIXED))
        self.assertEqual(again, MIXED)
        self.assertEqual(sum(len(v) for v in app.sent.values()), 2, "two busy terminals")

    def test_an_export_holds_no_user_text(self):
        app = fresh_app()
        made = self.keep(session_io.import_layout(app.rpc, MIXED, log=lambda line: None))
        text = json.dumps(session_io.export_layout(app.rpc, builder=made))
        for private in PRIVATE:
            self.assertNotIn(private, text)
        self.assertNotIn("tab_", text, "an id leaked")
        self.assertNotIn("pane_", text, "an id leaked")

    def test_an_export_puts_back_the_shown_workspace_and_its_focused_pane(self):
        app = fresh_app()
        self.keep(session_io.import_layout(app.rpc, MIXED, log=lambda line: None))
        shown, focused = app.shown, app.focused_pane
        session_io.export_layout(app.rpc)
        self.assertEqual((app.shown, app.focused_pane), (shown, focused))

    def test_an_export_without_the_builder_reads_engines_only_of_shown_browsers(self):
        app = fresh_app()
        self.keep(session_io.import_layout(app.rpc, MIXED, log=lambda line: None))
        plain = session_io.export_layout(app.rpc)
        self.assertEqual(plain["busy"], [], "busy terminals are known only to their builder")
        kinds = session_io.leaves(plain["workspaces"][1]["tree"])[0]["tabs"]
        self.assertEqual(kinds, ["terminal", "browser", "chromium"], "the selected page's engine shows in debug.layers")
        # That export round-trips too: an unknown engine opens with the app's default and stays unknown.
        made, again = session_io.roundtrip(fresh_app().rpc, plain, log=lambda line: None)
        self.keep(made)
        self.assertEqual(session_io.digest(again), session_io.digest(plain))

    def test_a_chat_the_app_refuses_fails_the_round_trip(self):
        app = fresh_app(chat="refused")
        with self.assertRaisesRegex(session_io.LayoutSnapshotError, "workspace 2"):
            made, _ = session_io.roundtrip(app.rpc, MIXED, log=lambda line: None)

    def test_an_export_waits_for_the_layout_pass_of_each_workspace_it_shows(self):
        for lag in (1, 3):
            app = fresh_app(lag=lag)
            made, again = session_io.roundtrip(app.rpc, MIXED, log=lambda line: None)
            self.keep(made)
            self.assertEqual(again, MIXED, f"lag {lag}")

    def test_a_workspace_that_never_lays_out_fails_and_the_export_puts_the_app_back(self):
        app = fresh_app()
        made = self.keep(session_io.import_layout(app.rpc, MIXED, log=lambda line: None))
        last = app.workspaces[3]
        app.rpc("action.run", {"action": "splitRight", "target": "pane:" + app.leaves(last["tree"])[0]})
        app.unsettled.add(last["id"])
        shown, focused = app.shown, app.focused_pane
        with self.assertRaisesRegex(session_io.LayoutSnapshotError, "workspace 3: debug.layers did not settle"):
            session_io.export_layout(app.rpc, builder=made)
        self.assertEqual((app.shown, app.focused_pane), (shown, focused))

    def test_a_docked_pane_is_refused_and_the_export_puts_the_app_back(self):
        app = fresh_app()
        made = self.keep(session_io.import_layout(app.rpc, MIXED, log=lambda line: None))
        app.docked.add(app.leaves(app.workspaces[3]["tree"])[0])
        shown, focused = app.shown, app.focused_pane
        with self.assertRaisesRegex(session_io.LayoutSnapshotError, "workspace 3 has a docked pane"):
            session_io.export_layout(app.rpc, builder=made)
        self.assertEqual((app.shown, app.focused_pane), (shown, focused))

    def test_a_chromium_ask_that_opens_webkit_fails_the_round_trip(self):
        fallback = {"state": "ready", "unavailable": None, "fallback": "startFailed"}
        with self.assertRaisesRegex(session_io.LayoutSnapshotError, "not Chromium"):
            session_io.roundtrip(fresh_app(chromium="webkit", cef=fallback).rpc, MIXED, log=lambda line: None)
        # debug.cef reports nothing: the engine debug.layers shows still refuses the builder's asked kind.
        with self.assertRaisesRegex(session_io.LayoutSnapshotError, "asked as chromium is a webkit page"):
            session_io.roundtrip(fresh_app(chromium="webkit").rpc, MIXED, log=lambda line: None)

    def test_chromium_that_is_not_running_fails_the_import(self):
        missing = {"state": "failed", "unavailable": "notBundled", "fallback": None}
        with self.assertRaisesRegex(session_io.LayoutSnapshotError, "notBundled"):
            session_io.roundtrip(fresh_app(cef=missing).rpc, MIXED, log=lambda line: None)

    def test_an_app_that_is_not_fresh_is_refused(self):
        app = fresh_app()
        app.rpc("action.run", {"action": "splitRight", "target": f"pane:{app.focused_pane}"})
        with self.assertRaisesRegex(session_io.LayoutSnapshotError, "fresh"):
            self.keep(session_io.import_layout(app.rpc, MIXED, log=lambda line: None))


class StressRoundTripTests(Case):
    """STRESS as perf-stress-session.py builds it, exported with its builder, imported into a fresh app."""

    def test_stress_round_trips_with_the_same_digest(self):
        for selected in ("terminal", "chromium"):
            source = fresh_app()
            builder = self.keep(stress.Stress(source.rpc, log=lambda line: None, settle=0, selected=selected,
                                              web_dev_config=os.path.join(str(LAB), "no-such-web-dev.json")))
            builder.build(check=False)
            exported = session_io.export_layout(source.rpc, builder=builder)
            self.assertEqual(len(exported["workspaces"]), stress.WORKSPACES)
            measured = exported["workspaces"][exported["shown"]]
            self.assertEqual(exported["shown"], stress.WORKSPACES - 1, "the measured workspace is last and shown")
            self.assertTrue(measured["even"])
            self.assertEqual(len(measured["tree"]["children"]), stress.COLUMNS)
            self.assertEqual([len(c["children"]) for c in measured["tree"]["children"]], [3, 4, 3, 4])
            panes = session_io.leaves(measured["tree"])
            self.assertEqual(len(panes), stress.COLUMNS * stress.ROWS + len(stress.NESTED_COLUMNS))
            want = sorted(["terminal", "terminal", "chromium", "chromium", "webkit", "chat"])
            self.assertTrue(all(sorted(p["tabs"]) == want for p in panes), panes[0])
            self.assertEqual(len(exported["busy"]), stress.BUSY_TERMINALS)
            self.assertEqual(exported["focused_pane"], 0)
            made, again = session_io.roundtrip(fresh_app().rpc, exported, log=lambda line: None)
            self.keep(made)
            self.assertEqual(session_io.digest(again), session_io.digest(exported), session_io.first_difference(exported, again))


if __name__ == "__main__":
    unittest.main()
