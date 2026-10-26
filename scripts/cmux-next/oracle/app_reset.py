#!/usr/bin/env python3
"""The app driver's reset between cases (p15-oracle-189): back to the launch's fixture, then the reset snapshot.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3G ("App driver: reset check before each case
(relaunch and LeakedState on mismatch), --batch-limit K, --shuffle --seed N") and task 189. Stdlib only, safe
under `python3 -I`. oracle.py owns the check (it compares each reset snapshot with the fixture and records
LeakedState); this file owns what "back to the fixture" means for the app, through one seam: `rpc(method,
params)`, one control-socket call that answers as bench_launch.rpc_at does (the result, {"error": <ControlError>}
for a refusal, or {"error": <text>, "unreachable": true}). driver_app.py (p15-oracle-047) gives its launch-sharing
session `reset_state = AppReset(bench.rpc).reset`.

Chrome reference (chromium/src): base/test/test_suite.cc keeps one process for a batch of tests and resets the
state a test may change between them (ResetCommandLineBetweenTests, the FeatureList and field trial resets in
TestSuite), then CheckForLeakedGlobals fails the test whose global state is still not the one before it. The
reset here is the every-action sweep's restore (scripts/cmux-next/every-action-sweep.py: Sweep.restore,
close_new, restore_settings, home) with the same actions, so the oracle and the sweep agree on what a case may
leave behind.

The reset snapshot is the state a case can leave that the next case would see: the windows, workspace groups,
workspaces with their screens, panes (docks among them), tabs and selection, the focus, and the applied settings.
Not window key status, titles or unread counts: they follow the OS and the shells, not the case.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, FrozenSet, List, Mapping, Optional, Tuple

# bench_launch.BenchApp.rpc(method, params) or any call with its reply shape.
Rpc = Callable[[str, Dict[str, Any]], Any]

# Overlays a case can leave open: two escapes (a palette's nested page, then the palette) and the palette target,
# as Sweep.restore sends them.
DISMISS_KEYS: Tuple[Dict[str, Any], ...] = (
    {"key": "escape"},
    {"key": "escape"},
    {"key": "escape", "target": "palette"},
)
WORKSPACE_KEYS = ("name", "color", "icon", "group", "session")
GROUP_KEYS = ("id", "name", "color", "collapsed")


class ResetError(Exception):
    """A control call that did not answer or was refused while resetting: the launch cannot be trusted."""


def unreachable(reply: Any) -> bool:
    return isinstance(reply, dict) and reply.get("unreachable") is True


def refused(reply: Any) -> bool:
    return isinstance(reply, dict) and set(reply) == {"error"}


# ---------------------------------------------------------------------------------------------------------
# The reset snapshot


def panes_of(workspace: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    return [p for s in workspace.get("screens") or () for p in s.get("panes") or ()]


def projection(topology: Mapping[str, Any], settings: Any) -> Dict[str, Any]:
    """The reset snapshot of one `snapshot.get` topology and the `settings.get` value. Lists keep their order:
    a reordered tab or workspace is state the next case sees."""
    windows = [
        {"id": w.get("id"), "workspace": w.get("workspace"), "workspaces": list(w.get("workspaces") or ())}
        for w in topology.get("windows") or ()
    ]
    groups = [{k: g.get(k) for k in GROUP_KEYS} for g in topology.get("workspace_groups") or ()]
    workspaces = []
    for w in topology.get("workspaces") or ():
        screens = []
        for s in w.get("screens") or ():
            panes = [
                {"id": p.get("id"), "dock": p.get("dock"), "selected_tab": p.get("selected_tab"),
                 "tabs": [t.get("id") for t in p.get("tabs") or ()]}
                for p in s.get("panes") or ()
            ]
            screens.append({"id": s.get("id"), "zoomed_pane": s.get("zoomed_pane"), "panes": panes})
        workspaces.append({"id": w.get("id"), **{k: w.get(k) for k in WORKSPACE_KEYS}, "screens": screens})
    focus = dict(topology.get("focus") or {})
    return {"windows": windows, "workspace_groups": groups, "workspaces": workspaces, "focus": focus,
            "settings": settings}


# ---------------------------------------------------------------------------------------------------------
# Back to the fixture


def closes(fixture: Mapping[str, Any], now: Mapping[str, Any]) -> List[Tuple[str, str, Dict[str, Any]]]:
    """(action, target, args) that close or regroup what `now` has beyond `fixture`, outermost first (a closed
    window takes its workspaces with it; Sweep.close_new's order)."""
    out: List[Tuple[str, str, Dict[str, Any]]] = []
    windows = {w["id"] for w in fixture["windows"]}
    out += [("closeWindow", f"window:{w['id']}", {}) for w in now["windows"] if w["id"] not in windows]
    before = {w["id"]: w for w in fixture["workspaces"]}
    for workspace in now["workspaces"]:
        old = before.get(workspace["id"])
        if old is None:
            out.append(("closeWorkspace", f"workspace:{workspace['id']}", {}))
            continue
        old_panes = {p["id"]: p for p in panes_of(old)}
        for pane in panes_of(workspace):
            if pane["id"] not in old_panes:
                out.append(("closePane", f"pane:{pane['id']}", {}))
                continue
            kept = set(old_panes[pane["id"]]["tabs"])
            out += [("closeTab", f"tab:{tab}", {}) for tab in pane["tabs"] if tab not in kept]
    group_ids = {g["id"] for g in fixture["workspace_groups"]}
    made = [g["id"] for g in now["workspace_groups"] if g["id"] not in group_ids]
    out += [("workspaceGroup.ungroup", f"workspace-group:{g}", {}) for g in made]
    for workspace in now["workspaces"]:
        old = before.get(workspace["id"])
        if old is None:
            continue
        group = None if workspace["group"] in made else workspace["group"]
        if group == old["group"]:
            continue
        if old["group"] is None:
            out.append(("removeWorkspaceFromGroup", f"workspace:{workspace['id']}", {}))
        else:
            out.append(("moveWorkspaceToGroup", f"workspace:{workspace['id']}", {"group": f"workspace-group:{old['group']}"}))
    return out


def settings_writes(fixture: Any, now: Any, path: Tuple[str, ...] = ()) -> List[Tuple[str, Dict[str, Any]]]:
    """(method, params) that put the fixture's settings back (Sweep.restore_settings): settings.set for a changed
    or removed leaf, settings.unset for a key the case added."""
    if isinstance(fixture, dict) and isinstance(now, dict):
        out: List[Tuple[str, Dict[str, Any]]] = []
        for key in sorted(set(fixture) | set(now)):
            if key not in fixture:
                out.append(("settings.unset", {"path": [*path, key]}))
            elif key not in now:
                out.append(("settings.set", {"path": [*path, key], "value": fixture[key]}))
            else:
                out += settings_writes(fixture[key], now[key], (*path, key))
        return out
    if fixture != now or type(fixture) is not type(now):
        return [("settings.set", {"path": list(path), "value": fixture})]
    return []


def focus_moves(fixture: Mapping[str, Any], now: Mapping[str, Any]) -> List[Tuple[str, Optional[str], Dict[str, Any]]]:
    """(action, target, args) that put the focus back on the fixture's workspace, pane and tab (Sweep.home)."""
    want, have = fixture["focus"], now["focus"]
    if want == have:
        return []
    out: List[Tuple[str, Optional[str], Dict[str, Any]]] = []
    if want.get("workspace"):
        out.append(("goToWorkspace", None, {"workspace": want["workspace"]}))
    if want.get("pane"):
        out.append(("pane.focus", f"pane:{want['pane']}", {}))
    if want.get("tab"):
        out.append(("tab.focus", f"tab:{want['tab']}", {}))
    return out


class AppReset:
    """One launch's reset: the first call reads the fixture, every later call brings the app back to it.

    Each call returns the reset snapshot read behind the app's read barrier (`snapshot.get {after: "sync"}`: every
    write the daemon committed before it, the closes among them, is in it). Actions run with `wait: true`, so a
    reply comes after the store applied the action; nothing here polls or sleeps.
    """

    def __init__(self, rpc: Rpc):
        self.raw = rpc
        self.fixture: Optional[Dict[str, Any]] = None
        self.destructive: FrozenSet[str] = frozenset()

    def rpc(self, method: str, params: Dict[str, Any]) -> Any:
        """The result of one call; a refusal or an unreachable socket raises ResetError."""
        reply = self.raw(method, params)
        if unreachable(reply) or refused(reply):
            raise ResetError(f"{method}: {reply['error']}")
        return reply

    def dismiss(self) -> None:
        """Escapes for overlays a case left open. A refusal is fine (nothing was open); a lost socket is not."""
        for params in DISMISS_KEYS:
            reply = self.raw("debug.key", dict(params))
            if unreachable(reply):
                raise ResetError(f"debug.key: {reply['error']}")

    def snapshot(self) -> Dict[str, Any]:
        topology = self.rpc("snapshot.get", {"after": "sync"})
        settings = self.rpc("settings.get", {"path": []})
        if not isinstance(topology, dict):
            raise ResetError(f"snapshot.get answered {type(topology).__name__}, not an object")
        value = settings.get("value") if isinstance(settings, dict) and "value" in settings else settings
        return projection(topology.get("topology") or {}, value)

    def act(self, action: str, target: Optional[str], args: Mapping[str, Any], *, focus: bool = False) -> None:
        call: Dict[str, Any] = {"action": action, "origin": "script", "wait": True}
        if target:
            call["target"] = target
        merged = dict(args)
        if action in self.destructive:
            merged["confirm"] = True  # a socket caller confirms a destructive action (ControlRouter+ActionRun)
        if merged:
            call["args"] = merged
        if focus:
            call["focus"] = True
        self.rpc("action.run", call)

    def reset(self) -> Dict[str, Any]:
        if self.fixture is None:
            listed = self.rpc("action.list", {})
            self.destructive = frozenset(a["id"] for a in (listed or {}).get("actions") or () if a.get("destructive"))
            self.fixture = self.snapshot()
            return self.fixture
        self.dismiss()
        now = self.snapshot()
        for action, target, args in closes(self.fixture, now):
            self.act(action, target, args)
        for method, params in settings_writes(self.fixture["settings"], now["settings"]):
            self.rpc(method, params)
        now = self.snapshot()
        for action, target, args in focus_moves(self.fixture, now):
            self.act(action, target, args, focus=True)
        return self.snapshot()


# ---------------------------------------------------------------------------------------------------------
# The launch-sharing session (oracle.py driver protocol)


class SharedLaunchSession:
    """One app launch that runs a batch of cases, with the reset between them (oracle.py's driver protocol).

    Two seams, so driver_app.py (p15-oracle-047) keeps its launch and its steps: `launch()` returns the launched
    app (it has `rpc(method, params)` with bench_launch.rpc_at replies and `stop()`, as bench_launch.BenchApp), and
    `run_case(app, case, ctx)` runs one case on it and returns the result dict. oracle.py calls `reset_state`
    once after the launch (the fixture) and after every case; on a mismatch it closes this session (stop: the
    app and the tag's daemons, TagTeardown) and the next case gets a new launch.
    """

    def __init__(self, launch: Callable[[], Any], run_case: Callable[[Any, Dict[str, Any], Dict[str, Any]], Dict[str, Any]],
                 reset: Callable[[Rpc], AppReset] = AppReset):
        self.app = launch()
        self.runner = run_case
        self.resetter = reset(self.app.rpc)

    def run_case(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]:
        return self.runner(self.app, case, case_ctx)

    def reset_state(self) -> Dict[str, Any]:
        return self.resetter.reset()

    def close(self) -> None:
        self.app.stop()
