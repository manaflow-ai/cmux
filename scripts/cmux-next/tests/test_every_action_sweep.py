#!/usr/bin/env python3
"""every-action-sweep.py's own harness (deep review bench-small, 2026-10-23), against an in-memory app socket.

1. A row that closed panes gets exactly those panes back. The sweep reopens by id (`history.reopen`) the
   closed-history entries the measured input made, never the newest entry of the history (Cmd-Shift-T): the
   sweep's own cleanup closes fill that history, and a reopen lands in the store after its reply. The layout must
   then equal the base (per pane: its column and the multiset of its tab kinds), not only reach its counts.
2. A session that fails fails the run: main() exits FAILED_SESSION_EXIT, every-action.md names the failed session,
   and --merge keeps a shard's failure (and exits the same way) instead of reading its missing rows as covered.
3. STRESS has one shape or the session fails (P12): a build of another layout raises StressShapeError, and a
   mid-session rebuild or tab restore of another layout raises SessionShapeError, instead of being measured as
   `stress`; a rebuild replaces the damaged measured workspace; a lost tab comes back as the kind the builder made
   (WebKit stays WebKit). A builder step that only timed out in a restore (focus never reached a pane) is a harness
   row of that action, not a failed session, in light and STRESS alike.
4. An unreadable closed history before the input reopens nothing (older cleanup groups never come back), and an
   app that does not come back at a relaunch (LaunchError) is a failed session in the report, not a lost report.
5. The tab path keeps the builder's books true (the real perf-stress-session summary judges them): a lost first
   terminal comes back as one terminal, a lost busy terminal comes back busy under its new id. A cleanup close whose
   history entry lands after the next mark is never reopened for the next input. An interaction whose restore failed
   gets the same relaunch and build() as an action's. A failed run prints its report into the step log, and --merge
   reads it back from there.
6. The closed history is the daemon's whole list behind the app's barrier (`debug.closed_ids`), read once: a blank
   New Tab page the restore closes (Recently Closed hides it) does not cost the next input its reopen, and an input
   that moves a tab away (closes nothing) reads it once, with no wait. A relaunch checks Chromium again (rows on an
   invalid launch say so) and drops the old mark. A reopen of another shape fails the session. Expectations are by
   exact id, and a typed refusal is `refused`, not `wrong`. Tabs already back need no rebuild. A restored pane shows
   the kind of tab it showed at the build, and the Chromium context is a Chromium page. A failed run's logged report
   says which display it measured on.
7. Review 2: each entrypoint is checked against what it makes there (Cmd-I docks a chat; its CLI path opens a chat
   tab), and the restore closes what the grid's counts miss (docked columns, new workspace groups; one left fails
   STRESS). Only a typed refusal is `refused` (a not_found on the sweep's own target is wrong), in the check and in
   misses() alike. A restored pane shows the same tab it showed (by terminal or url), not the last of its kind. A
   WebKit fallback after a light restore marks the row and the launch, and only the picked tab being a CEF tab makes
   the base pane's Chromium valid. A directional focus starts from a pane with a neighbor that way.

No app, GUI or build: the module's socket helper is replaced by a model of the topology, focus and closed history.
Run: python3 -I scripts/cmux-next/tests/test_every_action_sweep.py
"""
import contextlib, copy, importlib.util, io, itertools, json, os, shutil, sys, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
OUT = tempfile.mkdtemp(prefix="every-action-test-")


def load_sweep():
    argv = sys.argv
    sys.argv = ["every-action-sweep.py", "--app", "-", "--tag", "unit-test", "--out", OUT, "--repeat", "1", "--settle", "0"]
    try:
        spec = importlib.util.spec_from_file_location("every_action_sweep", os.path.join(SCRIPTS, "every-action-sweep.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.argv = argv
    return module


sweep_mod = load_sweep()
stress_mod = sweep_mod.load("perf_stress_session", "perf-stress-session.py")


class NoProcess:
    """The sweep's App as restore() reads it: no child process to have exited."""
    process = None


class FakeApp:
    """One window's workspaces, focus and closed history, as snapshot.get, action.run and history.list show them.
    A reopen lands `lag` snapshots after its reply (the store applies the daemon's reply later). A closed entry
    lands in the history `history_lag` reads (snapshot.get or history.list) after its close: the daemon's closed
    history reaches the app on its own event stream, after the topology shows the close. A reopened pane or tab
    gets new ids; its terminal keeps its process (the reopen attaches inside the reap grace)."""

    def __init__(self, lag=0, history_lag=0):
        self.ids = itertools.count(100)
        self.lag = lag
        self.history_lag = history_lag
        self.pending = []  # [snapshots left, apply]
        self.history_pending = []  # [reads left, closed entry]
        self.sent = []  # (tab id, text) of each terminal.sendText
        self.reopened_items = []  # the closed entries history.reopen brought back, in order
        self.closed = []  # newest first
        self.workspaces = []
        self.focus = {"window": "win_1"}
        self.elsewhere = None  # the pane `test.closeElsewhere` closes
        self.doomed_tab = None  # the tab `test.closeDoomedTab` closes
        self.history_errors = 0  # the next N history.list reads fail (a socket timeout under load)
        self.reopened = []  # closed ids history.reopen brought back, in order
        self.engines = {}  # tab id -> webkit or chromium (the app knows; snapshot.get says `browser` for both)
        self.reads = []  # each closed-history read (debug.closed_ids or history.list), in order
        self.deny_chat = False  # palette.newAgentChat answers the typed refusal of ACPMUX_AGENT_LAUNCH=deny
        self.moved = None  # the tab `test.moveDoomedTab` moves out of its pane (a move: nothing closes)
        self.groups = []  # the window's workspace groups ({"id"}), as topology workspace_groups lists them
        self.docked = 0  # chat docks Cmd-I opened
        self.stuck_docks = False  # closePane refuses a docked pane (a dock the restore cannot close)
        self.ran = []  # action ids the app ran since the last signpost read (key and action.run alike)
        self.cef = {}  # what debug.cef answers

    def new_id(self, prefix):
        return f"{prefix}_{next(self.ids)}"

    def pane(self, column, kinds):
        tabs = []
        for kind in kinds:
            tab = {"id": self.new_id("tab"), "kind": kind, "selected": False}
            if kind == "terminal":
                tab["terminal"] = self.new_id("term")
            tabs.append(tab)
        tabs[-1]["selected"] = True
        return {"id": self.new_id("pane"), "column": column, "tabs": tabs}

    def workspace(self, panes):
        workspace = {"id": self.new_id("ws"), "screens": [{"id": self.new_id("screen"), "panes": panes}]}
        self.workspaces.append(workspace)
        return workspace

    def focus_on(self, workspace, pane):
        self.focus.update(workspace=workspace["id"], pane=pane["id"],
                          tab=next(t["id"] for t in pane["tabs"] if t["selected"]))

    def find_pane(self, pane_id):
        for workspace in self.workspaces:
            for screen in workspace["screens"]:
                for index, pane in enumerate(screen["panes"]):
                    if pane["id"] == pane_id:
                        return workspace, screen, index
        return None

    def record(self, item):
        item["id"] = "daemon:" + self.new_id("closed")
        if self.history_lag:
            self.history_pending.append([self.history_lag, item])
        else:
            self.closed.insert(0, item)

    def tick_history(self):
        """One read of the app: closed entries whose time came land in the history (newest first)."""
        for entry in list(self.history_pending):
            entry[0] -= 1
            if entry[0] <= 0:
                self.history_pending.remove(entry)
                self.closed.insert(0, entry[1])

    def barrier(self):
        """debug.closed_ids' sync barrier: every close the daemon committed is in the store before it answers."""
        for entry in self.history_pending:
            self.closed.insert(0, entry[1])
        self.history_pending = []

    @staticmethod
    def blank(tab):
        """A tab the daemon marks `empty`: an untouched New Tab page, a chat with no session yet, a blank browser."""
        return tab["kind"] == "page" or (tab["kind"] == "browser" and not tab.get("url")) or \
            (tab["kind"] == "conversation" and not tab.get("session"))

    def recently_closed(self):
        """history.list's closed rows: HistoryService.closedEntries hides a group with only blank tabs
        (isWorthReopening) and lists a page closed again once, at its newest close (newestOnce)."""
        rows, pages = [], set()
        for item in self.closed:
            tabs = [item["tab"]] if item["kind"] == "tab" else (item["pane"]["tabs"] if item["kind"] == "pane" else
                                                                 [t for s in item["workspace"]["screens"] for p in s["panes"] for t in p["tabs"]])
            if all(self.blank(t) for t in tabs):
                continue
            if item["kind"] == "tab" and tabs[0]["kind"] == "browser" and tabs[0].get("url"):
                if tabs[0]["url"] in pages:
                    continue
                pages.add(tabs[0]["url"])
            rows.append(item)
        return rows

    def close_pane(self, pane_id):
        workspace, screen, index = self.find_pane(pane_id)
        pane = screen["panes"].pop(index)
        self.record({"kind": "pane", "workspace": workspace["id"], "screen": screen["id"], "index": index, "pane": pane})

    def close_tab(self, tab_id):
        for workspace in self.workspaces:
            for screen in workspace["screens"]:
                for pane in screen["panes"]:
                    for index, tab in enumerate(pane["tabs"]):
                        if tab["id"] == tab_id:
                            pane["tabs"].pop(index)
                            self.record({"kind": "tab", "pane": pane["id"], "index": index, "tab": tab})
                            return

    def close_workspace(self, workspace_id):
        workspace = next(w for w in self.workspaces if w["id"] == workspace_id)
        self.workspaces.remove(workspace)
        self.record({"kind": "workspace", "workspace": workspace})

    def add_tab(self, pane_id, kind, engine=None, url=None):
        workspace, screen, index = self.find_pane(pane_id)
        tabs = screen["panes"][index]["tabs"]
        tab = {"id": self.new_id("tab"), "kind": kind, "selected": True}
        if kind == "terminal":
            tab["terminal"] = self.new_id("term")
        if url:
            tab["url"] = url
        if engine:
            self.engines[tab["id"]] = engine
        for other in tabs:
            other["selected"] = False
        tabs.append(tab)

    def reopen(self, item):
        def apply():
            if item["kind"] == "pane":
                pane = copy.deepcopy(item["pane"])
                pane["id"] = self.new_id("pane")
                for tab in pane["tabs"]:
                    old, tab["id"] = tab["id"], self.new_id("tab")
                    if old in self.engines:
                        self.engines[tab["id"]] = self.engines.pop(old)
                workspace = next(w for w in self.workspaces if w["id"] == item["workspace"])
                screen = next(s for s in workspace["screens"] if s["id"] == item["screen"])
                screen["panes"].insert(item["index"], pane)
            elif item["kind"] == "tab":
                found = self.find_pane(item["pane"])
                if found:
                    workspace, screen, index = found
                    tab = dict(item["tab"], id=self.new_id("tab"))
                    if item["tab"]["id"] in self.engines:
                        self.engines[tab["id"]] = self.engines.pop(item["tab"]["id"])
                    screen["panes"][index]["tabs"].insert(item["index"], tab)
            else:
                workspace = copy.deepcopy(item["workspace"])
                workspace["id"] = self.new_id("ws")
                self.workspaces.append(workspace)
        self.pending.append([self.lag, apply])

    def topology(self):
        return {"windows": [{"id": "win_1"}], "workspaces": copy.deepcopy(self.workspaces), "focus": dict(self.focus),
                "workspace_groups": copy.deepcopy(self.groups)}

    def take_runs(self, start, end):
        """The always-on action signposts of what ran since the last read, as SignpostStream.runs gives them."""
        runs = [{"id": ident, "begin": start, "perform_ms": 0.5, "commit_end": start + 0.002, "commit_ms": 2.0} for ident in self.ran]
        self.ran = []
        return runs

    def focused_workspace(self):
        return next(w for w in self.workspaces if w["id"] == self.focus.get("workspace"))

    def cells(self):
        """Each grid pane's frame in the shown window ([x, y, w, h], top-left origin): 400 x 300 per column and row."""
        return {p["id"]: [p["column"] * 400, p.get("row", 0) * 300, 400, 300]
                for s in self.focused_workspace()["screens"] for p in s["panes"] if not p.get("dock")}

    def dock_chat(self):
        """A person's Cmd-I (DockedAgentChat.open): the workspace's one chat docked left on the focused pane's screen; a
        second Cmd-I focuses that dock."""
        workspace, screen, _ = self.find_pane(self.focus["pane"])
        dock = next((p for p in screen["panes"] if p.get("dock") and any(t["kind"] == "conversation" for t in p["tabs"])), None)
        if dock is None:
            dock = {"id": self.new_id("pane"), "column": 0, "dock": "left",
                    "tabs": [{"id": self.new_id("tab"), "kind": "conversation", "selected": True}]}
            screen["panes"].insert(0, dock)
            self.docked += 1
        self.focus_on(workspace, dock)

    def move_focus(self, direction):
        """focusLeft/Right/Up/Down: to the grid neighbor that way, or nothing (PaneHandlers.bindFocus refuses quietly)."""
        cells = self.cells()
        x, y = cells[self.focus["pane"]][:2]
        step = {"left": (-400, 0), "right": (400, 0), "up": (0, -300), "down": (0, 300)}[direction]
        target = next((pane for pane, cell in cells.items() if cell[:2] == [x + step[0], y + step[1]]), None)
        if target:
            workspace, screen, index = self.find_pane(target)
            self.focus_on(workspace, screen["panes"][index])

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method in ("snapshot.get", "history.list"):
            self.tick_history()
        if method == "snapshot.get":
            for entry in list(self.pending):
                entry[0] -= 1
                if entry[0] <= 0:
                    self.pending.remove(entry)
                    entry[1]()
            return {"topology": self.topology()}
        if method in ("history.list", "debug.closed_ids"):
            self.reads.append(method)
            if self.history_errors:
                self.history_errors -= 1
                return {"error": {"code": "timeout", "message": f"{method} missed its deadline"}}
        if method == "history.list":
            return {"entries": [{"id": "closed:" + c["id"], "kind": "closed", "closed_id": c["id"]} for c in self.recently_closed()]}
        if method == "debug.closed_ids":
            self.barrier()
            return {"closed_ids": [c["id"] for c in self.closed]}
        if method == "settings.get":
            return {"value": {}}
        if method == "debug.cef":
            return copy.deepcopy(self.cef)
        if method == "debug.pane_chrome":
            return {"windows": [{"panes": [{"pane": pane, "cell": cell} for pane, cell in self.cells().items()]}]}
        if method == "debug.key":
            if params.get("key") == "i" and params.get("modifiers") == ["cmd"]:
                self.ran.append("palette.newAgentChat")
                self.dock_chat()
                return {"handled_by": "keyRouter", "action": "palette.newAgentChat"}
            return {}
        if method == "action.describe":
            return {"action": {"available": True}}
        if method == "system.ping":
            return {"pong": True}
        if method != "action.run":
            return {}
        action, args = params.get("action"), params.get("args") or {}
        target = (params.get("target") or "").partition(":")[2]
        self.ran.append(action)
        if action == "closePane":
            found = self.find_pane(target or self.focus["pane"])
            if self.stuck_docks and found and found[1]["panes"][found[2]].get("dock"):
                return {"error": {"code": "refused", "message": "the dock stays"}}
            self.close_pane(target or self.focus["pane"])
        elif action == "closeTab":
            self.close_tab(target)
        elif action == "closeWorkspace":
            self.close_workspace(target)
        elif action == "test.closeElsewhere":
            self.close_pane(self.elsewhere)
        elif action == "test.closeDoomedTab":
            self.close_tab(self.doomed_tab)
        elif action == "newSurface":
            self.add_tab(target or self.focus["pane"], "terminal")
        elif action == "terminal.sendText":
            self.sent.append((target, args.get("text")))
        elif action in ("openBrowser.chromium", "openBrowser.webkit"):
            self.add_tab(target, "browser", engine=action.partition(".")[2], url=args.get("url"))
        elif action == "palette.newAgentChat":
            if self.deny_chat:
                return {"error": {"code": "unavailable", "message": "agent launch is denied (ACPMUX_AGENT_LAUNCH=deny)"}}
            self.add_tab(target or self.focus["pane"], "conversation")
        elif action == "test.moveDoomedTab":
            source, target_pane = self.moved
            _, screen, index = self.find_pane(source)
            tab = next(t for t in screen["panes"][index]["tabs"] if t["id"] == self.doomed_tab)
            screen["panes"][index]["tabs"].remove(tab)
            _, screen, index = self.find_pane(target_pane)
            screen["panes"][index]["tabs"].append(dict(tab, selected=False))
        elif action == "newTab.page":
            self.add_tab(target or self.focus["pane"], "page")
        elif action == "reopenClosedBrowserPanel":
            if self.closed:
                self.reopen(self.closed.pop(0))
        elif action == "history.reopen":
            item = next((c for c in self.closed if c["id"] == args.get("id")), None)
            if item is None:
                return {"error": {"code": "not_found", "message": "the entry is gone"}}
            self.closed.remove(item)
            self.reopened.append(item["id"])
            self.reopened_items.append(item)
            self.reopen(item)
        elif action == "pane.focus":
            found = self.find_pane(target)
            if found:
                self.focus.update(workspace=found[0]["id"], pane=target)
        elif action == "tab.focus":
            self.focus["tab"] = target
            for workspace in self.workspaces:
                for screen in workspace["screens"]:
                    for pane in screen["panes"]:
                        if any(t["id"] == target for t in pane["tabs"]):
                            for tab in pane["tabs"]:
                                tab["selected"] = tab["id"] == target
                            self.focus.update(workspace=workspace["id"], pane=pane["id"])
        elif action == "goToWorkspace":
            self.focus["workspace"] = args.get("workspace")
        elif action == "newWorkspaceGroup":
            # WorkspaceGroupHandlers: a new group whose member is the current workspace.
            group = {"id": self.new_id("wsg")}
            self.groups.append(group)
            self.focused_workspace()["group"] = group["id"]
        elif action == "workspaceGroup.ungroup":
            self.groups = [g for g in self.groups if g["id"] != target]
            for workspace in self.workspaces:
                if workspace.get("group") == target:
                    workspace["group"] = None
        elif action == "removeWorkspaceFromGroup":
            next(w for w in self.workspaces if w["id"] == target)["group"] = None
        elif action == "moveWorkspaceToGroup":
            next(w for w in self.workspaces if w["id"] == target)["group"] = args["group"].partition(":")[2]
        elif action in ("focusLeft", "focusRight", "focusUp", "focusDown"):
            self.move_focus(action[len("focus"):].lower())
        return {}


def layout(fake, workspace_id):
    """Per pane of `workspace_id`, in order: its column and its sorted tab kinds."""
    workspace = next((w for w in fake.workspaces if w["id"] == workspace_id), None)
    assert workspace is not None, f"workspace {workspace_id} is gone"
    return [(p["column"], sorted(t["kind"] for t in p["tabs"])) for s in workspace["screens"] for p in s["panes"]]


class ReopenTests(unittest.TestCase):
    def sweep(self, fake, base):
        sweep = sweep_mod.Sweep(NoProcess(), "light", stress_mod)
        sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
        sweep.snapshot_base(base["id"])
        return sweep

    def test_a_closed_pane_comes_back_once_by_id_when_the_reopen_lands_late(self):
        fake = FakeApp(lag=2)
        other = fake.workspace([fake.pane(None, ["terminal"])])
        measured = fake.pane(0, ["browser", "browser", "browser", "conversation", "terminal", "terminal"])
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        # An earlier row's cleanup closed a pane of the base workspace: it sits lower in the closed history.
        leftover = fake.pane(2, ["terminal", "browser"])
        base["screens"][0]["panes"].append(leftover)
        fake.close_pane(leftover["id"])
        fake.focus_on(base, measured)
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep = self.sweep(fake, base)
            want = layout(fake, base["id"])
            row = sweep.run_action({"id": "closePane", "title": "Close Pane"})
            # Anything still landing lands now: the base must stay what it was, not grow by the older entry.
            for _ in range(4):
                fake.rpc("snapshot.get")
        self.assertEqual(row.get("check"), "ok", row)
        self.assertEqual(layout(fake, base["id"]), want)
        self.assertEqual([w["id"] for w in fake.workspaces], [other["id"], base["id"]])
        # The base pane is the reopened pane at the base pane's place, and it has the focus.
        panes = next(w for w in fake.workspaces if w["id"] == base["id"])["screens"][0]["panes"]
        self.assertEqual(sweep.base["pane"], panes[0]["id"])
        self.assertEqual(fake.focus["pane"], panes[0]["id"])

    def test_an_unreadable_history_before_the_input_reopens_nothing_older(self):
        fake = FakeApp()
        measured = fake.pane(0, ["terminal", "browser", "terminal"])
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        # An earlier row's cleanup closed a pane of the base workspace: an older entry of the closed history.
        leftover = fake.pane(2, ["terminal", "browser"])
        base["screens"][0]["panes"].append(leftover)
        fake.close_pane(leftover["id"])
        older = fake.closed[0]["id"]
        fake.focus_on(base, measured)
        fake.doomed_tab = measured["tabs"][0]["id"]
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep = self.sweep(fake, base)
            want = layout(fake, base["id"])
            # history.list misses its deadline once: at the mark just before the measured input.
            fake.history_errors = 1
            row = sweep.run_action({"id": "test.closeDoomedTab", "title": "Close one tab"})
        self.assertNotIn(older, fake.reopened)
        self.assertEqual(fake.reopened, [])
        self.assertEqual(layout(fake, base["id"]), want)
        self.assertTrue(any("closed history unread" in d for d in row["drift"]), row["drift"])

    def test_a_cleanup_entry_that_lands_after_the_next_mark_is_not_the_next_inputs(self):
        # Row N adds a terminal tab; its restore closes that tab, and the close's history entry lands late (after
        # row N+1's mark under the old code). Row N+1 closes a terminal tab of the base pane. Only that tab's own
        # entry may come back: reopening the cleanup entry would put the sweep's cleanup shell in the base.
        fake = FakeApp(history_lag=3)
        measured = fake.pane(0, ["terminal", "browser", "terminal"])
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        fake.focus_on(base, measured)
        doomed = measured["tabs"][0]["id"]
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep = self.sweep(fake, base)
            want = layout(fake, base["id"])
            sweep.run_action({"id": "newSurface", "title": "New Terminal Tab"})
            fake.doomed_tab = doomed
            row = sweep.run_action({"id": "test.closeDoomedTab", "title": "Close one tab"})
            for _ in range(6):
                fake.rpc("snapshot.get")
        self.assertEqual([item["tab"]["id"] for item in fake.reopened_items], [doomed], row["drift"])
        self.assertEqual(layout(fake, base["id"]), want)
        # The cleanup entry stays in the history.
        self.assertEqual(len([c for c in fake.closed if c["kind"] == "tab"]), 1, fake.closed)

    def test_a_pane_closed_in_another_workspace_comes_back_there(self):
        fake = FakeApp()
        measured = fake.pane(0, ["terminal", "browser"])
        base = fake.workspace([measured])
        gone = fake.pane(1, ["terminal"])
        other = fake.workspace([fake.pane(0, ["browser"]), gone])
        fake.elsewhere = gone["id"]
        fake.focus_on(base, measured)
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep = self.sweep(fake, base)
            want_base, want_other = layout(fake, base["id"]), layout(fake, other["id"])
            sweep.run_action({"id": "test.closeElsewhere", "title": "Close a pane elsewhere"})
        self.assertEqual(layout(fake, other["id"]), want_other)
        self.assertEqual(layout(fake, base["id"]), want_base)
        self.assertEqual(sweep.base["pane"], measured["id"])
        self.assertEqual(fake.focus["pane"], measured["id"])


class ClosedHistoryTests(unittest.TestCase):
    """The closed history the sweep reads is the daemon's whole list behind the app's barrier (debug.closed_ids)."""

    def light(self, fake, kinds=("terminal", "browser", "terminal")):
        measured = fake.pane(0, list(kinds))
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        fake.focus_on(base, measured)
        sweep = sweep_mod.Sweep(NoProcess(), "light", stress_mod)
        sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
        sweep.snapshot_base(base["id"])
        return sweep, base, measured

    def test_a_blank_new_tab_page_the_restore_closes_does_not_cost_the_next_input_its_reopen(self):
        # Row N opens a New Tab page; its restore closes it. Recently Closed (history.list) hides that close (a blank
        # page is not worth reopening), so counting history.list entries waited for it in vain and left the next
        # mark unset. Row N+1 closes a terminal: it must come back by id, as the closed group it made.
        fake = FakeApp()
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep, base, measured = self.light(fake)
            want = layout(fake, base["id"])
            doomed = measured["tabs"][0]["id"]
            first = sweep.run_action({"id": "newTab.page", "title": "New Tab Page"})
            fake.doomed_tab = doomed
            row = sweep.run_action({"id": "test.closeDoomedTab", "title": "Close one tab"})
        self.assertEqual(first["check"], "ok", first)
        self.assertEqual([item["tab"]["id"] for item in fake.reopened_items], [doomed], row["drift"])
        self.assertFalse(any("no reopen" in d for d in row["drift"]), row["drift"])
        self.assertEqual(layout(fake, base["id"]), want)

    def test_an_input_that_moves_a_tab_away_reads_the_closed_history_once_after_it(self):
        # A move closes nothing: the restore finds no group of the input's own in one read, never a wait for an
        # entry that never comes (the 3 s bound per attempt of every move, stash and drag row).
        fake = FakeApp()
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep, base, measured = self.light(fake)
            want = layout(fake, base["id"])
            fake.doomed_tab = measured["tabs"][0]["id"]
            fake.moved = (measured["id"], base["screens"][0]["panes"][1]["id"])
            del fake.reads[:]
            row = sweep.run_action({"id": "test.moveDoomedTab", "title": "Move a tab to the other pane"})
        self.assertEqual(fake.reads, ["debug.closed_ids", "debug.closed_ids"], row["drift"])
        self.assertEqual(fake.reopened, [])
        self.assertEqual(layout(fake, base["id"]), want)


class ExpectationTests(unittest.TestCase):
    def test_each_id_is_checked_against_what_it_makes(self):
        self.assertIsNone(sweep_mod.expectation("newWorkspaceGroup"))
        self.assertIsNone(sweep_mod.expectation("nextWorkspaceGroup"))
        self.assertIsNone(sweep_mod.expectation("focusRightSidebar"))
        self.assertEqual(sweep_mod.expectation("newTab"), "workspace+")
        self.assertEqual(sweep_mod.expectation("palette.newAgentChat"), "tab+")
        self.assertEqual(sweep_mod.expectation("focusNextPane"), "focus")

    def test_a_typed_refusal_is_refused_not_wrong(self):
        fake = FakeApp()
        fake.deny_chat = True
        measured = fake.pane(0, ["terminal", "browser"])
        base = fake.workspace([measured])
        fake.focus_on(base, measured)
        with mock.patch.object(sweep_mod, "rpc", fake.rpc), mock.patch.object(sweep_mod.SIGNPOSTS, "live", False):
            sweep = sweep_mod.Sweep(NoProcess(), "light", stress_mod)
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            sweep.snapshot_base(base["id"])
            row = sweep.run_action({"id": "palette.newAgentChat", "title": "New Agent Chat"})
        self.assertEqual(row["check"], "refused", row)
        self.assertNotIn("wrong result", sweep_mod.misses(row))


def light_sweep(fake, kinds=("terminal", "browser", "terminal"), session="light"):
    """A `session` sweep over a two-pane workspace of `fake` (the measured pane of `kinds` in column 0, a terminal pane
    in column 1), the base taken. Runs inside the patch of the module's rpc."""
    measured = fake.pane(0, list(kinds))
    base = fake.workspace([measured, fake.pane(1, ["terminal"])])
    fake.focus_on(base, measured)
    sweep = sweep_mod.Sweep(NoProcess(), session, stress_mod)
    sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
    sweep.snapshot_base(base["id"])
    return sweep, base, measured


def every_pane(fake):
    return [p for w in fake.workspaces for s in w["screens"] for p in s["panes"]]


class EntrypointTests(unittest.TestCase):
    """Each entrypoint is checked against what it makes there, and the restore undoes what the grid's counts miss."""

    def patches(self, fake, repeat=1):
        return [mock.patch.object(sweep_mod, "rpc", fake.rpc), mock.patch.object(sweep_mod.SIGNPOSTS, "live", False),
                mock.patch.object(sweep_mod.SIGNPOSTS, "runs", fake.take_runs),
                mock.patch.object(sweep_mod.opts, "repeat", repeat), mock.patch.object(sweep_mod, "STORE_APPLY_S", 0.2)]

    def run_with(self, patches, body):
        with contextlib.ExitStack() as stack:
            for patch in patches:
                stack.enter_context(patch)
            return body()

    def test_cmd_i_docks_a_chat_each_repeat_and_the_restore_closes_the_dock(self):
        # The catalog shortcut through the app's key path (origin user, no target): DockedAgentChat docks the chat on
        # the left, so the grid's tab count does not move. That is `ok`, and the dock goes with the restore: every
        # repeat docks a chat again (never only focuses the dock an earlier repeat left), and no later row runs with
        # a fifth column.
        fake = FakeApp()

        def body():
            sweep, base, _ = light_sweep(fake)
            want = layout(fake, base["id"])
            row = sweep.run_action({"id": "palette.newAgentChat", "title": "New Agent Chat", "shortcut_config": "cmd+i"})
            return sweep, base, want, row
        sweep, base, want, row = self.run_with(self.patches(fake, repeat=3), body)
        self.assertEqual(row["entries"], ["key"], row)
        self.assertEqual(row["check"], "ok", row)
        self.assertEqual(fake.docked, 3)
        self.assertFalse([p for p in every_pane(fake) if p.get("dock")])
        self.assertIn("dock+", row["drift"])
        self.assertEqual(layout(fake, base["id"]), want)

    def test_the_cli_path_of_new_agent_chat_is_checked_as_a_new_tab(self):
        fake = FakeApp()

        def body():
            sweep, _, _ = light_sweep(fake)
            return sweep.run_action({"id": "palette.newAgentChat", "title": "New Agent Chat"})
        row = self.run_with(self.patches(fake), body)
        self.assertEqual(row["entries"], ["action"], row)
        self.assertEqual(row["check"], "ok", row)
        self.assertEqual(fake.docked, 0)

    def test_a_new_workspace_group_is_undone_by_the_restore(self):
        # newWorkspaceGroup puts the measured workspace in a new group on each repeat: the restore ungroups it, so the
        # rows after it measure the sidebar STRESS has.
        fake = FakeApp()

        def body():
            sweep, base, _ = light_sweep(fake)
            row = sweep.run_action({"id": "newWorkspaceGroup", "title": "New Workspace Group"})
            return base, row
        base, row = self.run_with(self.patches(fake, repeat=3), body)
        self.assertEqual(fake.groups, [])
        self.assertIsNone(next(w for w in fake.workspaces if w["id"] == base["id"]).get("group"))
        self.assertIn("group+", row["drift"])

    def test_a_dock_left_in_stress_fails_the_session(self):
        fake = FakeApp()
        fake.stuck_docks = True

        def body():
            sweep, _, _ = light_sweep(fake, session="stress")
            sweep.run_action({"id": "palette.newAgentChat", "title": "New Agent Chat", "shortcut_config": "cmd+i"})
        with self.assertRaises(sweep_mod.SessionShapeError) as raised:
            self.run_with(self.patches(fake), body)
        self.assertIn("dock", str(raised.exception))

    def test_a_dock_left_in_light_is_the_rows_drift(self):
        fake = FakeApp()
        fake.stuck_docks = True

        def body():
            sweep, _, _ = light_sweep(fake)
            return sweep.run_action({"id": "palette.newAgentChat", "title": "New Agent Chat", "shortcut_config": "cmd+i"})
        row = self.run_with(self.patches(fake), body)
        self.assertTrue(any(d.startswith("left dock") for d in row["drift"]), row["drift"])

    def test_a_directional_focus_starts_from_a_pane_with_a_neighbor_that_way(self):
        # The base pane is the top-left one: focusLeft from it has no neighbor and the app refuses quietly. The row
        # starts from the pane to its right and times the move; focusUp has no pane above anywhere in a one-row grid,
        # so it is skipped and says why, never timed as a refusal.
        fake = FakeApp()

        def body():
            sweep, base, measured = light_sweep(fake)
            left = sweep.run_action({"id": "focusLeft", "title": "Focus Left"})
            up = sweep.run_action({"id": "focusUp", "title": "Focus Up"})
            return base, measured, left, up
        base, measured, left, up = self.run_with(self.patches(fake), body)
        self.assertEqual(left["check"], "ok", left)
        self.assertEqual(left["from_pane"], [base["screens"][0]["panes"][1]["id"]])
        self.assertIn("no pane with a neighbor to the up", up.get("skipped", ""), up)
        self.assertEqual(fake.focus["pane"], measured["id"])


class RefusalTests(unittest.TestCase):
    def test_only_a_typed_refusal_is_refused(self):
        self.assertTrue(sweep_mod.refusal("unavailable: agent launch is denied"))
        self.assertTrue(sweep_mod.refusal("disabled: needs a selection"))
        self.assertTrue(sweep_mod.refusal("refused: palette.newAgentChat"))
        self.assertFalse(sweep_mod.refusal("not_found: no tab tab_7"))
        self.assertFalse(sweep_mod.refusal("invalid_params: bad target"))

    def test_a_close_that_lost_the_sweeps_own_target_is_wrong_and_a_miss(self):
        # closeTab answers not_found for the base tab the sweep aimed at: the app lost it. That is a wrong result in
        # the report, not a refusal that misses() drops.
        fake = FakeApp()

        def rpc(method, params=None, timeout=60):
            if method == "action.run" and (params or {}).get("action") == "test.closeLostTab":
                return {"error": {"code": "not_found", "message": "no tab with that id"}}
            return fake.rpc(method, params, timeout)
        with mock.patch.object(sweep_mod, "rpc", rpc), mock.patch.object(sweep_mod.SIGNPOSTS, "live", False), \
                mock.patch.dict(sweep_mod.EXPECT, {"test.closeLostTab": "tab-"}):
            sweep, _, _ = light_sweep(fake)
            row = sweep.run_action({"id": "test.closeLostTab", "title": "Close the base tab"})
        self.assertEqual(row["check"], "wrong", row)
        self.assertIn("wrong result", sweep_mod.misses(row))
        self.assertTrue(any(m.startswith("error: not_found") for m in sweep_mod.misses(row)), sweep_mod.misses(row))

    def test_a_key_refusal_is_refused_in_the_check_and_in_misses(self):
        row = {"errors": ["refused: palette.newAgentChat"], "check": "refused", "frames": {}}
        self.assertEqual(sweep_mod.misses(row), [])


class ReselectTests(unittest.TestCase):
    def test_a_restored_pane_shows_the_same_terminal_it_showed(self):
        # A STRESS pane with two terminals shows the idle one. After a tab restore selects the other (busy) terminal,
        # the pane must show the idle one again, found by its terminal, not "the last terminal".
        fake = FakeApp()
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep, base, measured = light_sweep(fake, kinds=("terminal", "browser", "terminal"))
            idle = measured["tabs"][0]
            fake.rpc("action.run", {"action": "tab.focus", "target": f"tab:{idle['id']}"})
            sweep.snapshot_base(base["id"])
            fake.rpc("action.run", {"action": "tab.focus", "target": f"tab:{measured['tabs'][2]['id']}"})
            sweep.reselect()
        shown = next(t for t in fake.find_pane(measured["id"])[1]["panes"][0]["tabs"] if t["selected"])
        self.assertEqual(shown["id"], idle["id"])
        self.assertEqual(sweep.notes, [])

    def test_a_shown_tab_that_is_gone_is_picked_by_kind_and_the_drift_says_so(self):
        fake = FakeApp()
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep, base, measured = light_sweep(fake, kinds=("terminal", "browser", "terminal"))
            fake.close_tab(measured["tabs"][2]["id"])
            sweep.reselect()
        self.assertEqual(sweep.notes, ["pane 0:0 shows another terminal tab"])


class ChromiumValidityTests(unittest.TestCase):
    def test_a_fallback_after_a_light_restore_marks_the_row_and_the_launch(self):
        fake = FakeApp()
        with mock.patch.object(sweep_mod, "rpc", fake.rpc), mock.patch.object(sweep_mod.SIGNPOSTS, "live", False):
            sweep, base, measured = light_sweep(fake)
            sweep.launches.append({"chromium_ok": True, "cef_flags": [], "fallbacks": 0})
            fake.doomed_tab = measured["tabs"][0]["id"]
            fake.history_errors = 1  # no reopen: the tab path replaces the tab
            fake.cef = {"fallback": {"count": 1, "reason": "startFailed"}}
            row = sweep.run_action({"id": "test.closeDoomedTab", "title": "Close one tab"})
            sweep.stamp(row)
        self.assertIn("chromium fallback +1", row["drift"])
        self.assertFalse(sweep.launches[-1]["chromium_ok"])
        self.assertTrue(row.get("invalid_launch"), row)

    def test_another_panes_cef_tab_does_not_make_the_base_tab_chromium(self):
        fake = FakeApp()
        measured = fake.pane(0, ["terminal"])
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        fake.focus_on(base, measured)
        with mock.patch.object(sweep_mod, "rpc", fake.rpc), mock.patch("time.sleep"):
            sweep = sweep_mod.Sweep(NoProcess(), "light", stress_mod)
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            sweep.builder.add_tab(base["id"], measured["id"], "chromium")
            sweep.snapshot_base(base["id"])
            fake.cef = {"state": "ready", "default_engine": "chromium", "ready_after_launch_s": 1.0,
                        "devtools": [{"tab": "tab_elsewhere", "url": "http://127.0.0.1:1/other"}]}
            validity = sweep.check_validity()
        self.assertFalse(validity["chromium_ok"])
        self.assertIn("the base pane's Chromium tab is not a CEF tab", validity["cef_flags"])


class RelaunchTests(unittest.TestCase):
    def test_rows_after_a_relaunch_whose_chromium_is_not_valid_say_so_and_the_old_mark_goes(self):
        launches = iter([{"chromium_ok": True, "cef_flags": []},
                         {"chromium_ok": False, "cef_flags": ["fallback {'webkit': 3}"]}])
        marks = []

        class App:
            process = None

            def relaunch(self):
                pass

        sweep = sweep_mod.Sweep(App(), "light", stress_mod)

        def run_action(action):
            marks.append(sweep.closed_mark)
            if action["id"] == "first":
                sweep.closed_mark = {"daemon:closed_of_the_old_daemon"}
                raise RuntimeError("focus never reached pane pane_7")
            return {"session": "light", "kind": "action", "id": action["id"], "errors": [], "frames": {"missed": 0}, "check": "ok"}

        # The failed builder step left another layout: the session is unfit, so it relaunches.
        with mock.patch.object(sweep, "build", lambda: None), mock.patch.object(sweep, "check_validity", lambda: next(launches)), \
                mock.patch.object(sweep, "frames_during", lambda body, settle=0.4: {"frames": {}}), \
                mock.patch.object(sweep, "run_action", run_action), mock.patch.object(sweep, "restored", lambda: False), \
                mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"pong": True}), \
                mock.patch.object(sweep_mod.opts, "no_interactions", True):
            sweep.run([{"id": "first"}, {"id": "second"}])
        self.assertEqual(len(sweep.launches), 2)
        self.assertNotIn("invalid_launch", sweep.rows[0])
        self.assertEqual(sweep.rows[1]["invalid_launch"], ["fallback {'webkit': 3}"])
        self.assertEqual(sweep.rows[1]["launch"], 1)
        self.assertEqual(marks[1], None)
        self.assertIn("second", sweep_mod.markdown({"env": ENV, "sessions": [dict(session("light", sweep.rows), launches=sweep.launches)]}))


def session(name, rows, failures=None):
    out = {"name": name, "summary": {}, "validity": {"chromium_ok": True, "cef_flags": []}, "idle": {"frames": {}},
           "rows": rows, "interactions": []}
    if failures:
        out["failed"] = failures
    return out


ENV = {"host": "cmux-test", "macos": "26.1", "sha": "a" * 40}


class UnresponsiveAppTests(unittest.TestCase):
    """The cause of "the app stopped answering" is kept before the relaunch erases it (the app-exits group had
    no cause: rows said only `Connection refused` or `the app stopped answering`)."""

    def test_an_exited_app_keeps_its_signal_and_crash_report(self):
        app = sweep_mod.App()
        app.process = mock.Mock(pid=4242, poll=mock.Mock(return_value=-11))
        with tempfile.TemporaryDirectory() as folder:
            report = os.path.join(folder, "cmux DEV-2026-10-24-0001.ips")
            with open(report, "w") as f:
                f.write('{"app_name":"cmux DEV"}\n' + json.dumps({"pid": 4242, "exception": {"type": "EXC_BAD_ACCESS"}}))
            with mock.patch.object(sweep_mod, "crash_reports", lambda since, pid=None: [report]):
                stopped = app.why_unresponsive(0)
        self.assertEqual((stopped["state"], stopped["code"], stopped["signal"]), ("exited", -11, 11))
        self.assertIn("EXC_BAD_ACCESS", stopped["summary"])
        self.assertTrue(os.path.exists(stopped["report"]), "the report was not kept in OUT/crashes")

    def test_a_stuck_app_is_sampled_and_never_signalled(self):
        app = sweep_mod.App()
        process = mock.Mock(pid=4343, poll=mock.Mock(return_value=None))
        app.process = process
        with mock.patch.object(sweep_mod.subprocess, "run") as run:
            stopped = app.why_unresponsive(0)
        self.assertEqual(stopped["state"], "alive")
        self.assertEqual(run.call_args[0][0][:3], ["/usr/bin/sample", "4343", "3"])
        process.terminate.assert_not_called()
        process.kill.assert_not_called()


class HarnessFrameTests(unittest.TestCase):
    def test_a_harness_failure_names_where_it_happened(self):
        def builder_step():
            return [][0]
        try:
            builder_step()
        except IndexError as error:
            frames = sweep_mod.harness_frames(error)
        self.assertTrue(frames[-1].startswith("test_every_action_sweep.py:"), frames)
        self.assertTrue(frames[-1].endswith(" builder_step"), frames)


class HarnessRelaunchTests(unittest.TestCase):
    """A harness row relaunches only when it left the session unfit (review 2: a relaunch per harness row cost the
    fleet ~10 min each in STRESS)."""

    def sweep(self, restored, chromium_ok):
        sweep = sweep_mod.Sweep.__new__(sweep_mod.Sweep)
        sweep.session = "light"
        sweep.restored = lambda: restored
        sweep.check_validity = lambda: {"chromium_ok": chromium_ok, "cef_flags": [] if chromium_ok else ["fallback 1"]}
        sweep.check_stress_shape = lambda: None
        return sweep

    def test_an_intact_session_is_fit(self):
        self.assertIsNone(self.sweep(True, True).unfit())

    def test_a_changed_layout_or_lost_chromium_is_unfit(self):
        self.assertEqual(self.sweep(False, True).unfit(), "a layout other than the base")
        self.assertIn("fallback 1", self.sweep(True, False).unfit())


class HarnessRowWithoutRelaunchTests(unittest.TestCase):
    def test_a_harness_row_on_an_intact_session_does_not_relaunch(self):
        relaunches = []

        class App:
            process = None

            def relaunch(self):
                relaunches.append(1)

        sweep = sweep_mod.Sweep(App(), "light", stress_mod)

        def run_action(action):
            raise RuntimeError("a builder step timed out after the input")

        with mock.patch.object(sweep, "build", lambda: None), \
                mock.patch.object(sweep, "check_validity", lambda: {"chromium_ok": True, "cef_flags": []}), \
                mock.patch.object(sweep, "frames_during", lambda body, settle=0.4: {"frames": {}}), \
                mock.patch.object(sweep, "run_action", run_action), mock.patch.object(sweep, "restored", lambda: True), \
                mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"pong": True}), \
                mock.patch.object(sweep_mod.opts, "no_interactions", True):
            sweep.run([{"id": "first"}, {"id": "second"}])
        self.assertEqual(relaunches, [])
        self.assertEqual([r["after_harness"] for r in sweep.rows], ["the session is intact; no relaunch"] * 2)


class FixtureTests(unittest.TestCase):
    """Preconditions the sweep generates: argument values the action accepts, directional moves from a pane with a
    neighbor, and refusals that are the action's correct answer (the wrong-or-error rows of the macOS 27 sweep)."""

    def test_browser_fit_gets_an_aspect_ratio_and_history_open_a_real_entry(self):
        fit = {"id": "browserFit", "arguments": [{"name": "fit", "kind": "string", "required": True}]}
        self.assertEqual(sweep_mod.argument_values(fit, {}), ({"fit": "16:9"}, None))
        entry = {"id": "history.open", "arguments": [{"name": "id", "kind": "string", "required": True}]}
        with mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"entries": [{"id": "h_42"}]}):
            self.assertEqual(sweep_mod.argument_values(entry, {}), ({"id": "h_42"}, None))
        with mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"entries": []}):
            self.assertEqual(sweep_mod.argument_values(entry, {}), (None, "the history is empty"))

    def test_swaps_start_from_a_pane_with_a_neighbor(self):
        for ident in ("swapPaneLeft", "swapPaneRight", "swapPaneUp", "swapPaneDown"):
            self.assertIn(ident, sweep_mod.DIRECTIONS)

    def test_a_policy_refusal_is_expected_and_another_error_is_not(self):
        self.assertTrue(sweep_mod.expected_refusal(
            "palette.disableBrowser",
            "daemon_error: browser.enabled can be changed only by you, in Settings (agents, scripts and pages cannot change it)"))
        self.assertFalse(sweep_mod.expected_refusal("palette.disableBrowser", "daemon_error: timed out"))
        self.assertFalse(sweep_mod.expected_refusal("history.open", "daemon_error: That history entry is gone"))


class CoverageTests(unittest.TestCase):
    """The derived-coverage check: the action list comes from the live catalog, and an action the sweep cannot set
    up (no fixture) that the baseline does not list fails a whole-catalog run."""

    def report(self, rows, partial=False):
        env = dict(ENV, partial=True) if partial else dict(ENV)
        return {"env": env, "sessions": [session("light", rows), session("stress", [])]}

    def baseline(self, ids):
        path = os.path.join(OUT, "gaps.json")
        with open(path, "w") as f:
            json.dump({"gaps": {i: "x" for i in ids}}, f)
        return path

    def test_a_new_action_without_a_fixture_fails_and_a_covered_one_is_listed(self):
        rows = [{"id": "new.action", "skipped": "needs context the sweep does not set up: fooFocused"},
                {"id": "old.gap", "skipped": "needs a room argument"},
                {"id": "cloud.thing", "skipped": "uses the Cloud, a remote machine, a phone or computer use"},
                {"id": "fixed.now", "errors": [], "check": "ok"}]
        checked = sweep_mod.coverage(self.report(rows), self.baseline(["old.gap", "fixed.now"]))
        self.assertEqual(list(checked["new"]), ["new.action"])
        self.assertEqual(checked["closed"], ["fixed.now"])
        with self.assertRaises(SystemExit) as raised:
            sweep_mod.fail_on_new_gaps({"coverage": checked})
        self.assertEqual(raised.exception.code, sweep_mod.NEW_GAP_EXIT)
        self.assertIn("new.action", sweep_mod.markdown(dict(self.report(rows), coverage=checked)))

    def test_an_action_one_session_ran_is_covered(self):
        report = {"env": dict(ENV), "sessions": [session("light", [{"id": "a", "errors": [], "check": "ok"}]),
                                                 session("stress", [{"id": "a", "skipped": "no chromium tab in the base pane"}])]}
        self.assertEqual(sweep_mod.gaps_of(report), {})

    def test_a_partial_run_gives_no_verdict_and_an_unreadable_baseline_fails_open(self):
        rows = [{"id": "new.action", "skipped": "needs a room argument"}]
        self.assertIsNone(sweep_mod.coverage(self.report(rows, partial=True), self.baseline([])))
        checked = sweep_mod.coverage(self.report(rows), os.path.join(OUT, "missing.json"))
        self.assertIn("error", checked)
        sweep_mod.fail_on_new_gaps({"coverage": checked})  # no exit


class FailedSessionTests(unittest.TestCase):
    def test_a_session_that_fails_fails_the_run_and_the_report_says_so(self):
        class App:
            process = None

            def launch(self):
                pass

            def relaunch(self):
                pass

            def stop(self):
                pass

        class Failing(sweep_mod.Sweep):
            def run(self, actions):
                raise RuntimeError("socket timeout while the light session was built")

        def rpc(method, params=None, timeout=60):
            return {"actions": []} if method == "action.list" else {}

        signposts = sweep_mod.SIGNPOSTS
        with mock.patch.object(sweep_mod, "App", App), mock.patch.object(sweep_mod, "Sweep", Failing), \
                mock.patch.object(sweep_mod, "rpc", rpc), mock.patch.object(signposts, "live", False), \
                mock.patch.object(signposts, "start", lambda module: setattr(signposts, "live", True)), \
                mock.patch.object(sweep_mod.opts, "sessions", "light"), mock.patch.object(sweep_mod.opts, "keep", True), \
                mock.patch.dict(os.environ, {"CMUX_CI_SHA": "b" * 40}):
            with self.assertRaises(SystemExit) as raised:
                sweep_mod.main()
        self.assertEqual(raised.exception.code, sweep_mod.FAILED_SESSION_EXIT)
        self.assertNotEqual(sweep_mod.FAILED_SESSION_EXIT, 0)
        with open(os.path.join(OUT, "every-action.json")) as f:
            report = json.load(f)
        self.assertEqual([f["name"] for f in report["failed_sessions"]], ["light"])
        with open(os.path.join(OUT, "every-action.md")) as f:
            md = f.read()
        self.assertIn("light", md)
        self.assertIn("socket timeout while the light session was built", md)

    def run_main(self, sessions, sweep_class, relaunch=None):
        """main() over `sessions` with `sweep_class` as Sweep and an app whose relaunch calls `relaunch`; returns
        the SystemExit code, the report and the markdown."""
        class App:
            process = None

            def launch(self):
                pass

            def relaunch(self):
                if relaunch:
                    relaunch()

            def stop(self):
                pass

        def rpc(method, params=None, timeout=60):
            return {"actions": []} if method == "action.list" else {}

        signposts = sweep_mod.SIGNPOSTS
        with mock.patch.object(sweep_mod, "App", App), mock.patch.object(sweep_mod, "Sweep", sweep_class), \
                mock.patch.object(sweep_mod, "rpc", rpc), mock.patch.object(signposts, "live", False), \
                mock.patch.object(signposts, "start", lambda module: setattr(signposts, "live", True)), \
                mock.patch.object(sweep_mod.opts, "sessions", sessions), mock.patch.object(sweep_mod.opts, "keep", True), \
                mock.patch.dict(os.environ, {"CMUX_CI_SHA": "b" * 40}):
            with self.assertRaises(SystemExit) as raised:
                sweep_mod.main()
        with open(os.path.join(OUT, "every-action.json")) as f:
            report = json.load(f)
        with open(os.path.join(OUT, "every-action.md")) as f:
            md = f.read()
        return raised.exception.code, report, md

    def test_an_app_that_does_not_come_back_mid_session_is_a_failed_session_in_the_report(self):
        class Sweep(sweep_mod.Sweep):
            def run(self, actions):
                self.validity, self.idle, self.summary = {"chromium_ok": True}, {"frames": {}}, {}
                if self.session == "light":
                    # Sweep.run relaunched after the app stopped answering, and the app crashed at launch.
                    self.rows.append({"session": "light", "kind": "action", "id": "closePane",
                                      "errors": ["the app stopped answering"], "frames": {"missed": None}, "check": "n/a"})
                    raise sweep_mod.LaunchError("crash", {"detail": "EXC_BAD_ACCESS (SIGSEGV) at launch", "log_tail": ""})
                return self

        code, report, md = self.run_main("light,stress", Sweep)
        self.assertEqual(code, sweep_mod.FAILED_SESSION_EXIT)
        self.assertEqual([(f["name"], f["rows"]) for f in report["failed_sessions"]], [("light", 1)])
        # The light rows before the crash are kept, and the next session still ran on a fresh launch.
        self.assertEqual([s["name"] for s in report["sessions"]], ["light", "stress"])
        self.assertEqual([r["id"] for r in report["sessions"][0]["rows"]], ["closePane"])
        self.assertIn("FAILED", md)
        self.assertIn("EXC_BAD_ACCESS (SIGSEGV) at launch", md)

    def test_an_app_that_does_not_come_back_between_sessions_is_a_failed_session_in_the_report(self):
        class Sweep(sweep_mod.Sweep):
            def run(self, actions):
                self.validity, self.idle, self.summary = {"chromium_ok": True}, {"frames": {}}, {}
                return self

        def relaunch():
            raise sweep_mod.LaunchError("crash", {"detail": "the app exited at launch (code -11)", "log_tail": ""})

        code, report, md = self.run_main("light,stress", Sweep, relaunch=relaunch)
        self.assertEqual(code, sweep_mod.FAILED_SESSION_EXIT)
        self.assertEqual([f["name"] for f in report["failed_sessions"]], ["stress"])
        self.assertEqual([s["name"] for s in report["sessions"]], ["light"])
        self.assertIn("FAILED", md)
        self.assertIn("the app exited at launch (code -11)", md)

    def test_a_failed_run_prints_its_report_into_the_step_log_and_merge_reads_it_back(self):
        # The controller returns --artifact files only when the step passes: a run that exits FAILED_SESSION_EXIT
        # must still give back the finished light session's rows and the failed STRESS session's, from its log.
        class Sweep(sweep_mod.Sweep):
            def run(self, actions):
                self.validity, self.idle, self.summary = {"chromium_ok": True}, {"frames": {"refresh_ms": 8.33}}, {}
                self.rows.append({"session": self.session, "kind": "action", "id": f"{self.session}.splitRight",
                                  "frames": {"missed": 0}, "check": "ok"})
                if self.session == "stress":
                    raise sweep_mod.SessionShapeError("STRESS session has the wrong shape: 11 panes, not 14")
                return self

        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            code, report, md = self.run_main("light,stress", Sweep)
        self.assertEqual(code, sweep_mod.FAILED_SESSION_EXIT)
        self.assertIn("11 panes, not 14", log.getvalue())
        folder = tempfile.mkdtemp(prefix="every-action-log-", dir=OUT)
        path = os.path.join(folder, "step.log")
        with open(path, "w") as f:
            # The log store puts its own prefix before every line.
            f.write("".join(f"2026-10-24T03:00:00Z [step] {line}\n" for line in log.getvalue().splitlines()))
        # The perf cron reads display.refresh_ms, which split-spring.sh adds only to a step it returns.
        self.assertEqual(sweep_mod.report_from(path)["display"]["refresh_ms"], 8.33)
        out = os.path.join(folder, "every-action.json")
        with self.assertRaises(SystemExit) as raised:
            sweep_mod.merge(out, [path])
        self.assertEqual(raised.exception.code, sweep_mod.FAILED_SESSION_EXIT)
        with open(out) as f:
            merged = json.load(f)
        self.assertEqual([s["name"] for s in merged["sessions"]], ["light", "stress"])
        self.assertEqual([[r["id"] for r in s["rows"]] for s in merged["sessions"]], [["light.splitRight"], ["stress.splitRight"]])
        self.assertEqual([f["name"] for f in merged["failed_sessions"]], ["stress"])

    def test_a_step_log_without_a_whole_report_is_an_error(self):
        folder = tempfile.mkdtemp(prefix="every-action-log-", dir=OUT)
        path = os.path.join(folder, "step.log")
        with open(path, "w") as f:
            f.write("every-action: FAILED\nEVERY-ACTION-REPORT 1/2 H4sIAAAA\n")
        with self.assertRaises(SystemExit) as raised:
            sweep_mod.report_from(path)
        self.assertIn("not a step log with one whole report", str(raised.exception.code))

    def test_a_session_that_failed_partway_is_marked_in_the_markdown(self):
        failure = {"name": "stress", "error": "RuntimeError('the app exited (code -11)')", "rows": 1}
        report = {"env": ENV, "sessions": [session("stress", [{"id": "closePane"}], [failure])], "failed_sessions": [failure]}
        md = sweep_mod.markdown(report)
        stress = md[md.index("## stress"):]
        self.assertIn("the app exited (code -11)", stress)

    def test_merge_keeps_a_shards_failure(self):
        folder = tempfile.mkdtemp(prefix="every-action-merge-", dir=OUT)
        failure = {"name": "stress", "error": "RuntimeError('the app exited (code -11)')", "rows": 1}
        shards = [{"env": dict(ENV, shard="1/2"), "sessions": [session("stress", [{"id": "a"}])]},
                  {"env": dict(ENV, shard="2/2"), "sessions": [session("stress", [{"id": "b"}], [failure])],
                   "failed_sessions": [failure]}]
        paths = []
        for index, shard in enumerate(shards):
            paths.append(os.path.join(folder, f"shard{index}.json"))
            with open(paths[-1], "w") as f:
                json.dump(shard, f)
        out = os.path.join(folder, "every-action.json")
        with self.assertRaises(SystemExit) as raised:
            sweep_mod.merge(out, paths)
        self.assertEqual(raised.exception.code, sweep_mod.FAILED_SESSION_EXIT)
        with open(out) as f:
            merged = json.load(f)
        self.assertEqual([(f["name"], f.get("shard")) for f in merged["failed_sessions"]], [("stress", "2/2")])
        self.assertTrue(merged["sessions"][0].get("failed"))
        with open(os.path.join(folder, "every-action.md")) as f:
            self.assertIn("the app exited (code -11)", f.read())


# What perf-stress-session's summary() gives for the STRESS shape (Stress.check accepts it).
STRESS_OK = {"workspaces": 60, "shown_columns": 4, "window": [80, 40, 1600, 1000], "measured_panes": 14,
             "measured_tabs": {"terminal": 28, "browser": 42, "conversation": 14}, "refusals": [],
             "busy_terminals": stress_mod.BUSY_TERMINALS, "pane_problems": [], "chromium_unavailable": [],
             "background_chromium": [stress_mod.CHROMIUM_PER_WORKSPACE] * stress_mod.CHROMIUM_WORKSPACES}
# What a host where only three columns fit builds.
STRESS_NARROW = dict(STRESS_OK, shown_columns=3, measured_panes=11, measured_tabs={"terminal": 22, "browser": 33, "conversation": 11})


class StressShapeTests(unittest.TestCase):
    def stress_app(self):
        fake = FakeApp()
        measured = fake.pane(0, ["terminal", "browser"])
        base = fake.workspace([measured])
        fake.workspace([fake.pane(0, ["terminal"])])
        fake.focus_on(base, measured)
        return fake, base

    def patched(self, fake, summary):
        """The STRESS builder's slow halves stubbed over `fake`; `summary` replaces Stress.summary, or None keeps the
        real summary (the per-pane mix and the busy count from the builder's own books)."""
        def build_measured(builder):
            pane = fake.pane(0, ["terminal", "browser"])
            workspace = fake.workspace([pane])
            fake.focus_on(workspace, pane)
            builder.measured = workspace["id"]
            return workspace["id"]
        patches = [mock.patch.object(sweep_mod, "rpc", fake.rpc),
                   mock.patch.object(stress_mod.Stress, "build_background", lambda builder, *a, **k: []),
                   mock.patch.object(stress_mod.Stress, "build_measured", build_measured),
                   # The window is STRESS's size: the build gets to its shape check.
                   mock.patch.object(stress_mod.Stress, "size_window", lambda builder: {"frame": [0, 0, *stress_mod.WINDOW_SIZE]}),
                   mock.patch("time.sleep")]
        if summary is not None:
            patches.append(mock.patch.object(stress_mod.Stress, "summary", lambda builder: dict(summary)))
        return patches

    def real_summary(self, fake, checked):
        """patched() with the real Stress.summary; Stress.check only keeps each summary in `checked` (the one-pane
        model is not 60 workspaces): a test reads the pane mix and the busy count the check would judge."""
        return self.patched(fake, None) + [
            mock.patch.object(stress_mod.Stress, "check", staticmethod(lambda summary: checked.append(summary)))]

    def tabs_of(self, fake, pane_id):
        _, screen, index = fake.find_pane(pane_id)
        return screen["panes"][index]["tabs"]

    def run_patched(self, patches, body):
        for patch in patches:
            patch.start()
        try:
            return body()
        finally:
            for patch in reversed(patches):
                patch.stop()

    def test_a_stress_build_of_another_shape_fails_the_session(self):
        fake, _ = self.stress_app()
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)
        with self.assertRaises(stress_mod.StressShapeError):
            self.run_patched(self.patched(fake, STRESS_NARROW), sweep.build)

    def test_a_stress_rebuild_of_another_shape_fails_the_session(self):
        fake, base = self.stress_app()
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)

        def body():
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            sweep.snapshot_base(base["id"])
            # The measured pane is gone with no closed group of the input's own: only a rebuild is exact.
            fake.close_pane(base["screens"][0]["panes"][0]["id"])
            sweep.rebuild({"panes": 1})
        with self.assertRaises(sweep_mod.SessionShapeError):
            self.run_patched(self.patched(fake, STRESS_NARROW), body)

    def webkit_pane(self, fake):
        """A STRESS-like measured pane the builder made in `fake` (terminal, then Chromium, Chromium, WebKit, chat,
        terminal) and the sweep's base on it; returns the sweep and the pane id. Runs inside ``patched(fake, ...)``."""
        pane = fake.pane(0, ["terminal"])
        base = fake.workspace([pane])
        fake.workspace([fake.pane(0, ["terminal"])])
        fake.focus_on(base, pane)
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)
        sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
        for kind in ["chromium", "chromium", "webkit", "chat", "terminal"]:
            sweep.builder.add_tab(base["id"], pane["id"], kind)
        sweep.builder.measured = base["id"]
        sweep.snapshot_base(base["id"])
        return sweep, pane["id"]

    def engines(self, fake, pane_id):
        _, screen, index = fake.find_pane(pane_id)
        return sorted(fake.engines.get(t["id"], t["kind"]) for t in screen["panes"][index]["tabs"])

    def test_a_lost_webkit_tab_comes_back_as_webkit_and_the_tab_path_checks_the_shape(self):
        fake = FakeApp()
        checked = []
        patches = self.real_summary(fake, checked)

        def body():
            sweep, pane = self.webkit_pane(fake)
            want = self.engines(fake, pane)
            webkit = next(tab for kind, tab, *_ in sweep.builder.made[pane] if kind == "webkit")
            # The tab is gone with no closed entry of the input's own (moved out, or its entry came too late):
            # the tab path runs.
            fake.close_tab(webkit)
            sweep.rebuild({"tabs": 1})
            return sweep, pane, want
        sweep, pane, want = self.run_patched(patches, body)
        self.assertEqual(self.engines(fake, pane), want)
        self.assertEqual(sorted(kind for kind, *_ in sweep.builder.made[pane]),
                         ["chat", "chromium", "chromium", "terminal", "webkit"])
        self.assertEqual(len(checked), 1)
        self.assertEqual(checked[0]["pane_problems"], [])

    def test_a_lost_first_terminal_comes_back_as_one_terminal(self):
        # The pane's first terminal is the one tab the builder has no entry for (summary() counts it by itself).
        # Its replacement must not count as a third terminal on a pane that has its 6 tabs again.
        fake = FakeApp()
        checked = []

        def body():
            sweep, pane = self.webkit_pane(fake)
            recorded = {tab for _, tab, *_ in sweep.builder.made[pane]}
            first = next(t["id"] for t in self.tabs_of(fake, pane) if t["id"] not in recorded)
            fake.close_tab(first)
            sweep.rebuild({"tabs": 1})
            return sweep, pane
        sweep, pane = self.run_patched(self.real_summary(fake, checked), body)
        self.assertEqual(sorted(t["kind"] for t in self.tabs_of(fake, pane)),
                         ["browser", "browser", "browser", "conversation", "terminal", "terminal"])
        self.assertEqual(len(checked), 1)
        self.assertEqual(checked[0]["pane_problems"], [])

    def test_a_lost_busy_terminal_comes_back_busy_under_a_new_id(self):
        # The mark before the input is unreadable, so nothing is reopened and the tab path brings the busy terminal
        # back: as a busy terminal (BUSY_COMMAND sent, its id in the builder's busy list), never as an idle shell
        # while the dead id still counts as busy.
        fake = FakeApp()
        checked = []

        def body():
            sweep, pane = self.webkit_pane(fake)
            busy = next(tab for kind, tab, *_ in reversed(sweep.builder.made[pane]) if kind == "terminal")
            sweep.builder.busy = [busy]
            sweep.snapshot_base(sweep.base["workspace"])
            fake.doomed_tab = busy
            fake.history_errors = 1
            row = sweep.run_action({"id": "test.closeDoomedTab", "title": "Close the busy terminal"})
            return sweep, pane, busy, row
        sweep, pane, busy, row = self.run_patched(self.real_summary(fake, checked), body)
        self.assertTrue(any("no reopen" in d for d in row["drift"]), row["drift"])
        self.assertEqual(len(sweep.builder.busy), 1)
        new = sweep.builder.busy[0]
        self.assertNotEqual(new, busy)
        self.assertIn(new, [t["id"] for t in self.tabs_of(fake, pane)])
        self.assertIn((new, stress_mod.BUSY_COMMAND), fake.sent)
        self.assertEqual(len(sweep.base["busy"]), 1)
        self.assertEqual([c["busy_terminals"] for c in checked], [1])
        self.assertEqual(checked[0]["pane_problems"], [])

    def test_a_tab_restore_of_another_shape_fails_the_session(self):
        fake = FakeApp()
        wrong = dict(STRESS_OK, pane_problems=["pane pane_1: 6 tabs, made {'terminal': 2, 'chromium': 3, 'webkit': 0, 'chat': 1}"])

        def body():
            sweep, pane = self.webkit_pane(fake)
            fake.close_tab(next(tab for kind, tab, *_ in sweep.builder.made[pane] if kind == "webkit"))
            sweep.rebuild({"tabs": 1})
        with self.assertRaises(sweep_mod.SessionShapeError):
            self.run_patched(self.patched(fake, wrong), body)

    def test_a_reopened_pane_keeps_the_kind_the_builder_made_each_tab(self):
        fake = FakeApp()

        def body():
            sweep, pane = self.webkit_pane(fake)
            asked = sorted(kind for kind, *_ in sweep.builder.made[pane])
            row = sweep.run_action({"id": "closePane", "title": "Close Pane"})
            return sweep, pane, asked, row
        sweep, pane, asked, row = self.run_patched(self.patched(fake, STRESS_OK), body)
        self.assertEqual(row["check"], "ok", row)
        new = fake.topology()["workspaces"][0]["screens"][0]["panes"][0]
        self.assertNotEqual(new["id"], pane)
        self.assertNotIn(pane, sweep.builder.made)
        made = sweep.builder.made[new["id"]]
        self.assertEqual(sorted(kind for kind, *_ in made), asked)
        ids = {t["id"] for t in new["tabs"]}
        self.assertTrue(all(tab in ids for _, tab, *_ in made), made)
        # Each page entry points at the reopened tab of its own engine.
        for kind, tab, *_ in made:
            if kind in ("webkit", "chromium"):
                self.assertEqual(fake.engines.get(tab), kind)

    def test_a_reopen_of_another_shape_fails_the_session(self):
        # The pane comes back by id with every tab kind in place (restored() is satisfied), but the shape check says
        # a reopened Chromium page is WebKit now: the session fails at this row, not later at an unrelated one.
        fake = FakeApp()
        wrong = dict(STRESS_OK, chromium_unavailable=["WebKit fallbacks: {'reopened': 1}"])

        def body():
            sweep, pane = self.webkit_pane(fake)
            sweep.run_action({"id": "closePane", "title": "Close Pane"})
        with self.assertRaises(sweep_mod.SessionShapeError):
            self.run_patched(self.patched(fake, wrong), body)

    def test_tabs_that_are_back_need_no_rebuild(self):
        fake = FakeApp()

        def body():
            sweep, pane = self.webkit_pane(fake)
            before = copy.deepcopy(fake.workspaces)
            sweep.rebuild({"tabs": 1})
            return before
        patches = self.patched(fake, STRESS_OK) + [
            mock.patch.object(stress_mod.Stress, "build_measured", lambda builder: self.fail("rebuilt a base that is whole"))]
        before = self.run_patched(patches, body)
        self.assertEqual(fake.workspaces, before)

    def test_a_tab_restore_leaves_each_pane_showing_what_it_showed(self):
        # A replaced tab is selected when it opens: STRESS shows each pane's terminal, so the restored pane must
        # show its terminal again, not the new WebKit page.
        fake = FakeApp()

        def body():
            sweep, pane = self.webkit_pane(fake)
            shown = next(t["kind"] for t in self.tabs_of(fake, pane) if t["selected"])
            fake.close_tab(next(tab for kind, tab, *_ in sweep.builder.made[pane] if kind == "webkit"))
            sweep.rebuild({"tabs": 1})
            return pane, shown
        pane, shown = self.run_patched(self.patched(fake, STRESS_OK), body)
        self.assertEqual(shown, "terminal")
        self.assertEqual([t["kind"] for t in self.tabs_of(fake, pane) if t["selected"]], ["terminal"])

    def test_the_chromium_context_shows_a_chromium_page_when_the_webkit_page_comes_first(self):
        fake = FakeApp()

        def body():
            pane = fake.pane(0, ["terminal"])
            base = fake.workspace([pane])
            fake.focus_on(base, pane)
            sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            for kind in ["webkit", "chromium", "terminal"]:
                sweep.builder.add_tab(base["id"], pane["id"], kind)
            sweep.snapshot_base(base["id"])
            self.assertTrue(sweep.show("chromium"))
        self.run_patched(self.patched(fake, STRESS_OK), body)
        self.assertEqual(fake.engines.get(fake.focus["tab"]), "chromium")

    def test_a_stress_rebuild_replaces_the_damaged_measured_workspace(self):
        fake, base = self.stress_app()
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)
        before = len(fake.workspaces)

        def body():
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            sweep.snapshot_base(base["id"])
            fake.close_pane(base["screens"][0]["panes"][0]["id"])
            sweep.rebuild({"panes": 1})
        self.run_patched(self.patched(fake, STRESS_OK), body)
        self.assertNotIn(base["id"], [w["id"] for w in fake.workspaces])
        self.assertEqual(len(fake.workspaces), before)
        self.assertEqual(sweep.base["workspace"], fake.workspaces[-1]["id"])

    def test_a_row_whose_restore_rebuilt_another_shape_fails_the_session(self):
        # A row's restore() rebuilt the measured workspace into another layout: the session fails there. It is not
        # a harness row of that action followed by a relaunch and more rows under `stress`.
        relaunches = []

        class App:
            process = None

            def relaunch(self):
                relaunches.append(1)

        sweep = sweep_mod.Sweep(App(), "stress", stress_mod)

        def run_action(action):
            raise sweep_mod.SessionShapeError("STRESS session has the wrong shape: 11 panes, not 14")

        def rpc(method, params=None, timeout=60):
            return {"pong": True} if method == "system.ping" else {}

        with mock.patch.object(sweep, "build", lambda: None), mock.patch.object(sweep, "check_validity", lambda: {}), \
                mock.patch.object(sweep, "frames_during", lambda body, settle=0.4: {"frames": {}}), \
                mock.patch.object(sweep, "run_action", run_action), mock.patch.object(sweep_mod, "rpc", rpc), \
                mock.patch.object(sweep_mod.opts, "no_interactions", True):
            with self.assertRaises(sweep_mod.SessionShapeError):
                sweep.run([{"id": "closePane"}, {"id": "splitRight"}])
        self.assertEqual(relaunches, [])
        self.assertEqual(sweep.rows, [])

    def focus_timeout_session(self, session):
        """A `session` sweep over [a tab close, a no-op] whose restore of the first row times out on focus
        (perf-stress-session's focus_pane raises StressShapeError for that); returns the sweep and its relaunches."""
        fake = FakeApp()
        measured = fake.pane(0, ["terminal", "browser", "terminal"])
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        fake.focus_on(base, measured)
        fake.doomed_tab = measured["tabs"][0]["id"]
        relaunches = []

        class App:
            process = None

            def relaunch(self):
                relaunches.append(1)

        sweep = sweep_mod.Sweep(App(), session, stress_mod)

        def build():
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            sweep.snapshot_base(base["id"])

        def focus_pane(builder, pane_id):
            raise stress_mod.StressShapeError(f"focus never reached pane {pane_id}")

        with mock.patch.object(sweep_mod, "rpc", fake.rpc), mock.patch.object(sweep, "build", build), \
                mock.patch.object(sweep, "check_validity", lambda: {}), \
                mock.patch.object(sweep, "frames_during", lambda body, settle=0.4: {"frames": {}}), \
                mock.patch.object(stress_mod.Stress, "focus_pane", focus_pane), \
                mock.patch.object(sweep_mod.opts, "no_interactions", True):
            sweep.run([{"id": "test.closeDoomedTab", "title": "Close one tab"}, {"id": "test.noop", "title": "Nothing"}])
        return sweep, relaunches

    def test_a_focus_timeout_in_a_light_restore_is_a_harness_row_and_the_session_goes_on(self):
        sweep, relaunches = self.focus_timeout_session("light")
        self.assertEqual([r["id"] for r in sweep.rows], ["test.closeDoomedTab", "test.noop"])
        self.assertTrue(sweep.rows[0]["errors"][0].startswith("harness:"), sweep.rows[0])
        self.assertIn("focus never reached pane", sweep.rows[0]["errors"][0])
        self.assertEqual(relaunches, [1])

    def test_a_focus_timeout_in_a_stress_restore_is_a_harness_row_and_the_session_goes_on(self):
        sweep, relaunches = self.focus_timeout_session("stress")
        self.assertEqual([r["id"] for r in sweep.rows], ["test.closeDoomedTab", "test.noop"])
        self.assertIn("focus never reached pane", sweep.rows[0]["errors"][0])
        self.assertEqual(relaunches, [1])

    def test_an_interaction_whose_restore_times_out_on_focus_relaunches_and_builds_the_session(self):
        # The same recovery as after an action's restore: the row keeps the error, then a relaunch and build()
        # (whose shape check fails a session that does not come back as STRESS). The next interaction never runs
        # on a half-restored layout.
        events = []

        class App:
            process = None

            def relaunch(self):
                events.append("relaunch")

        sweep = sweep_mod.Sweep(App(), "stress", stress_mod)

        def restore(action_id, toggled):
            raise stress_mod.StressShapeError("focus never reached pane pane_7")
        with mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"entries": []}), \
                mock.patch.object(sweep, "restore", restore), mock.patch.object(sweep, "build", lambda: events.append("build")), \
                mock.patch.object(sweep, "check_validity", lambda: events.append("validity") or {"chromium_ok": True}):
            sweep.interaction("click.pane", lambda: {"commit_ms": 4.0})
        self.assertIn("focus never reached pane", sweep.interactions[0]["restore_error"])
        self.assertEqual(events, ["relaunch", "build", "validity"])

    def test_an_interaction_whose_rebuild_after_a_failed_restore_is_not_stress_fails_the_session(self):
        class App:
            process = None

            def relaunch(self):
                pass

        sweep = sweep_mod.Sweep(App(), "stress", stress_mod)

        def restore(action_id, toggled):
            raise stress_mod.StressShapeError("focus never reached pane pane_7")

        def build():
            raise stress_mod.StressShapeError("STRESS session has the wrong shape: 11 panes, not 14")
        with mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"entries": []}), \
                mock.patch.object(sweep, "restore", restore), mock.patch.object(sweep, "build", build):
            with self.assertRaises(stress_mod.StressShapeError):
                sweep.interaction("click.pane", lambda: {"commit_ms": 4.0})

    def test_an_interaction_whose_restore_rebuilt_another_shape_fails_the_session(self):
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)

        def restore(action_id, toggled):
            raise sweep_mod.SessionShapeError("STRESS session has the wrong shape: 11 panes, not 14")
        with mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"entries": []}), \
                mock.patch.object(sweep, "restore", restore):
            with self.assertRaises(sweep_mod.SessionShapeError):
                sweep.interaction("click.pane", lambda: {"commit_ms": 4.0})


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        shutil.rmtree(OUT, ignore_errors=True)
        shutil.rmtree(sweep_mod.SCRATCH, ignore_errors=True)
