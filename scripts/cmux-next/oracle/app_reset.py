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
reopen, close_new, restore_settings, home) with the same actions, so the oracle and the sweep agree on what a
case may leave behind.

The reset snapshot is the state a case can leave that the next case would see: the windows, workspace groups,
workspaces with their screens, panes (docks among them), tabs and selection, the focus, the applied settings and
the closed history (Cmd-Shift-T and history.reopen read it). Not window key status, titles or unread counts: they
follow the OS and the shells, not the case. The reset puts back every key of it, or says it cannot
(NeedsRelaunch): then the next case gets a fresh launch and no case is blamed. Not the layout undo stacks: the
app has no read of them, so a case that undoes a layout change runs on a launch whose stack may hold an earlier
case's step (run such suites with --batch-limit 1).
"""

from __future__ import annotations

from typing import Any, Callable, Dict, FrozenSet, List, Mapping, Optional, Sequence, Tuple

# bench_launch.BenchApp.rpc(method, params) or any call with its reply shape.
Rpc = Callable[[str, Dict[str, Any]], Any]
# (action, target, args) of one action.run.
Step = Tuple[str, Optional[str], Dict[str, Any]]

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
    """A control call that was refused while resetting, or a fixture the reset could not read: the launch cannot
    be trusted. oracle.py reads two attributes: `unreachable` (the product is gone: a Crash, not a leak) and
    `relaunch` (why the reset cannot put the state back: a fresh launch, no leak)."""

    unreachable = False
    relaunch: Optional[str] = None


class ProductUnreachable(ResetError):
    """The control socket did not answer: the app quit or crashed."""

    unreachable = True


class NeedsRelaunch(ResetError):
    """The case changed state the reset has no action for (an order, a group's name, a fixture tab no reopen
    brings back); the next case needs a fresh launch. Not a leak: the reset knows what it cannot restore."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.relaunch = reason


def unreachable(reply: Any) -> bool:
    return isinstance(reply, dict) and reply.get("unreachable") is True


def refused(reply: Any) -> bool:
    return isinstance(reply, dict) and set(reply) == {"error"}


# ---------------------------------------------------------------------------------------------------------
# The reset snapshot


def panes_of(workspace: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    return [p for s in workspace.get("screens") or () for p in s.get("panes") or ()]


def projection(topology: Mapping[str, Any], settings: Any, closed: Sequence[str] = ()) -> Dict[str, Any]:
    """The reset snapshot of one `snapshot.get` topology, the `settings.get` value and the closed history
    (`debug.closed_ids`, newest first). Lists keep their order: a reordered tab or workspace is state the next
    case sees."""
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
            "settings": settings, "closed": list(closed)}


# ---------------------------------------------------------------------------------------------------------
# Back to the fixture


def lost(fixture: Mapping[str, Any], now: Mapping[str, Any]) -> List[str]:
    """`kind:id` of every fixture window, workspace, screen, pane and tab `now` no longer has."""
    out = [f"window:{w['id']}" for w in fixture["windows"] if w["id"] not in {x["id"] for x in now["windows"]}]
    after = {w["id"]: w for w in now["workspaces"]}
    for workspace in fixture["workspaces"]:
        have = after.get(workspace["id"])
        if have is None:
            out.append(f"workspace:{workspace['id']}")
            continue
        screens = {s["id"]: s for s in have["screens"]}
        for screen in workspace["screens"]:
            if screen["id"] not in screens:
                out.append(f"screen:{screen['id']}")
                continue
            panes = {p["id"]: p for p in screens[screen["id"]]["panes"]}
            for pane in screen["panes"]:
                if pane["id"] not in panes:
                    out.append(f"pane:{pane['id']}")
                    continue
                out += [f"tab:{t}" for t in pane["tabs"] if t not in panes[pane["id"]]["tabs"]]
    return out


def closes(fixture: Mapping[str, Any], now: Mapping[str, Any]) -> List[Step]:
    """(action, target, args) that close or regroup what `now` has beyond `fixture`, outermost first (a closed
    window takes its workspaces with it; Sweep.close_new's order)."""
    out: List[Step] = []
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


def order_changes(fixture: Mapping[str, Any], now: Mapping[str, Any]) -> List[str]:
    """What `now` (after the closes) holds in another order, or with another value, than `fixture` and no action
    puts back: the order of windows, groups, workspaces, screens, panes and tabs, a window's workspaces, a group's
    fields, a pane's dock and a workspace's session. Each is a reason for a fresh launch."""

    def order(name: str, want: Sequence[Any], have: Sequence[Any]) -> List[str]:
        shared = set(want) & set(have)
        return [f"{name} order"] if [x for x in want if x in shared] != [x for x in have if x in shared] else []

    out = order("window", [w["id"] for w in fixture["windows"]], [w["id"] for w in now["windows"]])
    after = {w["id"]: w for w in now["windows"]}
    for window in fixture["windows"]:
        if window["id"] in after:
            out += order(f"window {window['id']} workspace", window["workspaces"], after[window["id"]]["workspaces"])
    out += order("workspace group", [g["id"] for g in fixture["workspace_groups"]], [g["id"] for g in now["workspace_groups"]])
    groups = {g["id"]: g for g in now["workspace_groups"]}
    out += [f"workspace group {g['id']}" for g in fixture["workspace_groups"] if g["id"] in groups and groups[g["id"]] != g]
    out += order("workspace", [w["id"] for w in fixture["workspaces"]], [w["id"] for w in now["workspaces"]])
    spaces = {w["id"]: w for w in now["workspaces"]}
    for workspace in fixture["workspaces"]:
        have = spaces.get(workspace["id"])
        if have is None:
            continue
        if have["session"] != workspace["session"]:
            out.append(f"workspace {workspace['id']} session")
        out += order(f"workspace {workspace['id']} screen", [s["id"] for s in workspace["screens"]], [s["id"] for s in have["screens"]])
        screens = {s["id"]: s for s in have["screens"]}
        for screen in workspace["screens"]:
            if screen["id"] not in screens:
                continue
            out += order(f"screen {screen['id']} pane", [p["id"] for p in screen["panes"]], [p["id"] for p in screens[screen["id"]]["panes"]])
            panes = {p["id"]: p for p in screens[screen["id"]]["panes"]}
            for pane in screen["panes"]:
                if pane["id"] not in panes:
                    continue
                if panes[pane["id"]]["dock"] != pane["dock"]:
                    out.append(f"pane {pane['id']} dock")
                out += order(f"pane {pane['id']} tab", pane["tabs"], panes[pane["id"]]["tabs"])
    return out


def attribute_moves(fixture: Mapping[str, Any], now: Mapping[str, Any]) -> List[Step]:
    """(action, target, args) that put back each workspace's name, color and icon, each screen's zoomed pane,
    each pane's selected tab and each window's shown workspace (the focus follows in focus_moves)."""
    out: List[Step] = []
    spaces = {w["id"]: w for w in now["workspaces"]}
    for workspace in fixture["workspaces"]:
        have = spaces.get(workspace["id"])
        if have is None:
            continue
        target = f"workspace:{workspace['id']}"
        if have["name"] != workspace["name"]:
            out.append(("renameWorkspace", target, {"name": workspace["name"]}))
        if have["color"] != workspace["color"]:
            out.append(("palette.resetWorkspaceColor", target, {}) if workspace["color"] is None
                       else ("palette.workspaceColor", target, {"color": workspace["color"]}))
        if have["icon"] != workspace["icon"]:
            out.append(("workspace.clearIcon", target, {}) if workspace["icon"] is None
                       else ("workspace.setIcon", target, {"icon": workspace["icon"]}))
        screens = {s["id"]: s for s in have["screens"]}
        for screen in workspace["screens"]:
            shown = screens.get(screen["id"])
            if shown is None:
                continue
            if shown["zoomed_pane"] != screen["zoomed_pane"]:
                # Toggle Pane Zoom: off on the pane the case zoomed, then on for the fixture's.
                if shown["zoomed_pane"]:
                    out.append(("toggleSplitZoom", f"pane:{shown['zoomed_pane']}", {}))
                if screen["zoomed_pane"]:
                    out.append(("toggleSplitZoom", f"pane:{screen['zoomed_pane']}", {}))
            panes = {p["id"]: p for p in shown["panes"]}
            for pane in screen["panes"]:
                have_pane = panes.get(pane["id"])
                if have_pane and pane["selected_tab"] and have_pane["selected_tab"] != pane["selected_tab"]:
                    out.append(("tab.focus", f"tab:{pane['selected_tab']}", {}))
    windows = {w["id"]: w for w in now["windows"]}
    for window in fixture["windows"]:
        have = windows.get(window["id"])
        if have and window["workspace"] and have["workspace"] != window["workspace"]:
            out.append(("goToWorkspace", None, {"workspace": window["workspace"]}))
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


def focus_moves(fixture: Mapping[str, Any], now: Mapping[str, Any]) -> List[Step]:
    """(action, target, args) that put the focus back on the fixture's workspace, pane and tab (Sweep.home)."""
    want, have = fixture["focus"], now["focus"]
    if want == have:
        return []
    out: List[Step] = []
    if want.get("workspace"):
        out.append(("goToWorkspace", None, {"workspace": want["workspace"]}))
    if want.get("pane"):
        out.append(("pane.focus", f"pane:{want['pane']}", {}))
    if want.get("tab"):
        out.append(("tab.focus", f"tab:{want['tab']}", {}))
    return out


class Catalog:
    """What `action.list` says the reset may send: each action's target kinds, its destructive flag and its
    enumeration arguments' choices. An action, target kind or choice it does not list is never sent: the reset
    asks for a fresh launch instead of a refusal it could predict."""

    def __init__(self, listed: Any):
        self.targets: Dict[str, FrozenSet[str]] = {}
        self.choices: Dict[Tuple[str, str], FrozenSet[str]] = {}
        destructive = []
        for action in (listed or {}).get("actions") or ():
            ident = action.get("id")
            if not isinstance(ident, str):
                continue
            self.targets[ident] = frozenset(action.get("targets") or ())
            if action.get("destructive"):
                destructive.append(ident)
            for argument in action.get("arguments") or ():
                if argument.get("choices"):
                    self.choices[(ident, argument.get("name"))] = frozenset(c.get("value") for c in argument["choices"])
        self.destructive = frozenset(destructive)

    def why_not(self, action: str, target: Optional[str], args: Mapping[str, Any]) -> Optional[str]:
        """None when `action.list` lists `action` with `target`'s kind and every choice in `args`; else why not."""
        if action not in self.targets:
            return f"{action} is not in action.list"
        if target:
            kind = target.partition(":")[0]
            if kind not in self.targets[action]:
                return f"{action} does not take a {kind} target"
        for name, value in args.items():
            allowed = self.choices.get((action, name))
            if allowed is not None and value not in allowed:
                return f"{action} has no {name} {value!r}"
        return None


class AppReset:
    """One launch's reset: the first call reads the fixture, every later call brings the app back to it.

    Each call returns the reset snapshot read behind the app's read barriers (`snapshot.get {after: "sync"}` and
    `debug.closed_ids`: every write the daemon committed before it, the closes among them, is in it). Actions run
    with `wait: true`, so a reply comes after the store applied the action; nothing here polls or sleeps.
    """

    def __init__(self, rpc: Rpc):
        self.raw = rpc
        self.fixture: Optional[Dict[str, Any]] = None
        self.catalog = Catalog({})

    def rpc(self, method: str, params: Dict[str, Any]) -> Any:
        """The result of one call; an unreachable socket raises ProductUnreachable, a refusal ResetError."""
        reply = self.raw(method, params)
        if unreachable(reply):
            raise ProductUnreachable(f"{method}: {reply['error']}")
        if refused(reply):
            raise ResetError(f"{method}: {reply['error']}")
        return reply

    def dismiss(self) -> None:
        """Escapes for overlays a case left open. A refusal is fine (nothing was open); a lost socket is not."""
        for params in DISMISS_KEYS:
            reply = self.raw("debug.key", dict(params))
            if unreachable(reply):
                raise ProductUnreachable(f"debug.key: {reply['error']}")

    def snapshot(self) -> Dict[str, Any]:
        topology = self.rpc("snapshot.get", {"after": "sync"})
        settings = self.rpc("settings.get", {"path": []})
        closed = self.rpc("debug.closed_ids", {})
        if not isinstance(topology, dict):
            raise ResetError(f"snapshot.get answered {type(topology).__name__}, not an object")
        ids = closed.get("closed_ids") if isinstance(closed, dict) else None
        if not isinstance(ids, list):
            raise ResetError("debug.closed_ids answered no closed_ids list (a DEV build answers it)")
        value = settings.get("value") if isinstance(settings, dict) and "value" in settings else settings
        return projection(topology.get("topology") or {}, value, [i for i in ids if isinstance(i, str)])

    def act(self, action: str, target: Optional[str], args: Mapping[str, Any], *, focus: bool = False) -> None:
        why = self.catalog.why_not(action, target, args)
        if why:
            raise NeedsRelaunch(why)
        call: Dict[str, Any] = {"action": action, "origin": "script", "wait": True}
        if target:
            call["target"] = target
        merged = dict(args)
        if action in self.catalog.destructive:
            merged["confirm"] = True  # a socket caller confirms a destructive action (ControlRouter+ActionRun)
        if merged:
            call["args"] = merged
        if focus:
            call["focus"] = True
        self.rpc("action.run", call)

    def reopen(self, now: Dict[str, Any]) -> Dict[str, Any]:
        """Reopens what the case closed of the fixture by closed-history id (`history.reopen {id}`, newest first:
        the undo order, Sweep.reopen), never the newest entry of the whole history. A reopened tab keeps its id
        (durable-links-DESIGN.md); an object that comes back under another id stays lost: a fresh launch."""
        assert self.fixture is not None
        made = [i for i in now["closed"] if i not in set(self.fixture["closed"])]
        for item in made:
            if not lost(self.fixture, now):
                break
            self.act("history.reopen", None, {"id": item})
            now = self.snapshot()
        gone = lost(self.fixture, now)
        if gone:
            raise NeedsRelaunch(f"the case closed fixture objects no reopen brings back: {', '.join(gone[:5])}")
        return now

    def forget(self, now: Dict[str, Any]) -> Dict[str, Any]:
        """Deletes the closed-history entries made since the fixture (the case's closes and this reset's), so the
        next case reopens what the fixture holds (`debug.closed_forget`)."""
        assert self.fixture is not None
        kept = set(self.fixture["closed"])
        if [i for i in self.fixture["closed"] if i not in set(now["closed"])]:
            raise NeedsRelaunch("the case took entries out of the fixture's closed history")
        made = [i for i in now["closed"] if i not in kept]
        if not made:
            return now
        self.rpc("debug.closed_forget", {"ids": made})
        return self.snapshot()

    def reset(self) -> Dict[str, Any]:
        if self.fixture is None:
            self.catalog = Catalog(self.rpc("action.list", {}))
            self.fixture = self.snapshot()
            return self.fixture
        self.dismiss()
        now = self.snapshot()
        if lost(self.fixture, now):
            now = self.reopen(now)
        for action, target, args in closes(self.fixture, now):
            self.act(action, target, args)
        now = self.forget(self.snapshot())
        changed = order_changes(self.fixture, now)
        if changed:
            raise NeedsRelaunch(f"no action puts back the {', '.join(changed[:5])}")
        for action, target, args in attribute_moves(self.fixture, now):
            self.act(action, target, args, focus=action in ("tab.focus", "goToWorkspace"))
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
