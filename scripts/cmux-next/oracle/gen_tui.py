#!/usr/bin/env python3
"""The tui corpus (tests/oracle/corpus/tui/): one case per inventory action the TUI's default key map reaches.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite `tui`: the 50 tui_actions and the menu
actions of cmux-tui/spec/inventory.json) and task 234. Stdlib only, Python 3.9+, safe under `python3 -I`.
driver_tui.py runs the cases (`oracle.py run --product tui --suite tui`).

Each case is a list of `tui.key` steps: keystrokes into `cmux-tui attach` on the driver's PTY. A step that
leaves the frontend in pane input mode settles (driver_tui.py's barrier) and records its settled checkpoint; a
step that leaves a prompt, menu, overlay or the sidebar focused records only its before checkpoint, proves it
drew with a waitFor on /tui/screenSha256, and the next step closes it. waitFor on a daemon pointer waits for the
action's mutation (a count of tabs, panes, screens or workspaces, or a change of a layout or name); selection
and focus are the frontend's own view, not session state, so those cases wait on the screen. Setups (a second
tab, pane, screen or workspace) go through the resource API, so every run starts the action from one state.

coverage.json names, for each inventory action, the cases that press it or the reason none can: a menu action
whose route the keyboard reaches through the same Action (app/menu_action.rs keyboard_action_for_menu) lists
that action's case; the rest are reached only by a mouse right-click, a machine provider or a browser host, which
the hermetic case does not have. Its `nondeterministic` map (RACES) names each case whose settled checkpoints
differ between runs of one build, with the cause found.

Usage:
  gen_tui.py --write     write tests/oracle/corpus/tui from CASES
  gen_tui.py --check     exit 1 when the checked-in corpus differs (stale or extra files)
  gen_tui.py --coverage  how many inventory actions have cases and reasons
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CORPUS = REPO / "tests" / "oracle" / "corpus" / "tui"
COVERAGE_FILE = CORPUS / "coverage.json"
INVENTORY = REPO / "cmux-tui" / "spec" / "inventory.json"
TASK = "p15-oracle-234"
TUI_CAPABILITY = "tui"
PREFIX = "ctrl+b"
# Prefixed chords the frontend's config gives the actions with no default chord (cmux-tui config/keys.rs
# Keys::default binds none of them; each is free in the default map).
SELECT_TAB_0_KEY = "i"
RENAME_TAB_KEY = "y"
USER_COMMAND_KEY = "a"
# The config driver_tui.py gives the frontend (its own CMUX_TUI_CONFIG; the daemon keeps the case's): motion off
# (spec 3B: the default run mode has no animation), and the chords above. The user command opens a shell tab.
TUI_CONFIG: Dict[str, Any] = {
    "viewport": {"animation": False},
    "keys": {"select-tab-0": SELECT_TAB_0_KEY, "rename-tab": RENAME_TAB_KEY},
    "commands": [{"id": "oracle-shell", "name": "Oracle shell", "run": ["/bin/sh"], "keys": USER_COMMAND_KEY}],
}


def keys_step(step_id: str, keys: Sequence[str], *, wait: Optional[Mapping[str, Any]] = None,
              checkpoint: Sequence[str] = ("settled",), note: Optional[str] = None) -> Dict[str, Any]:
    step: Dict[str, Any] = {
        "id": step_id, "op": "tui.key", "target": {"session": "current"}, "args": {"keys": list(keys)},
        "expect": {"outcome": "ok", "noReceiptReason": "a key press has no receipt: its effect is the settled "
                                                       "daemon facet and screen"},
        "checkpoint": list(checkpoint),
    }
    if wait is not None:
        step["waitFor"] = dict(wait)
    if note:
        step["note"] = note
    return step


def count(pointer: str, value: int, max_ms: int = 10000) -> Dict[str, Any]:
    return {"pointer": pointer, "predicate": {"op": "lengthEquals", "value": value}, "maxMs": max_ms}


def changed(pointer: str, max_ms: int = 10000) -> Dict[str, Any]:
    return {"pointer": pointer, "predicate": "changed", "maxMs": max_ms}


TABS = "/daemon/session/tabs"
PANES = "/daemon/session/panes"
SCREENS = "/daemon/session/screens"
WORKSPACES = "/daemon/session/workspaces"
SIDEBAR = "/daemon/session/extra/state/sidebar"
SCREEN_HASH = "/tui/screenSha256"


def prefixed(key: str) -> List[str]:
    return [PREFIX, key]


SELECTORS = {"machine": "current", "session": "current"}
FIXTURE_PANE = "$step:fixture#/panes/0/id"


def resource_step(step_id: str, method: str, params: Mapping[str, Any], wait: Mapping[str, Any],
                  target: Optional[Mapping[str, str]] = None) -> Dict[str, Any]:
    """A daemon mutation through the resource API: what another client does, so the frontend only follows it."""
    return {
        "id": step_id, "op": "resource.call", "target": {**SELECTORS, **(target or {})},
        "args": {"method": method, "params": dict(params), "idempotencyKey": f"tui.{step_id}.{method}"},
        "expect": {"outcome": "ok", "receipt": "mutation_result"}, "waitFor": dict(wait),
    }


# The fixture's ids, read once: `$step:fixture#/panes/0/id` is the fixture pane.
FIXTURE = {"id": "fixture", "op": "resource.call", "readOnly": True,
           "args": {"method": "session.snapshot", "params": {}}, "expect": {"outcome": "ok"}}


def split_setup(direction: str) -> Tuple[Dict[str, Any], ...]:
    """The fixture pane split in `direction`. The frontend keeps its own selection, the fixture pane."""
    return (FIXTURE, resource_step("setup", "pane.split", {"direction": direction}, count(PANES, 2),
                                   {"pane": FIXTURE_PANE}))


# Steps that set up a case before the action under test come from the resource API, not from the TUI's own
# keys: whether the TUI selects a pane, screen or workspace it created itself races (RACES below), and a setup
# must leave every run in one state.
SPLIT = split_setup("right")
SPLIT_DOWN = split_setup("down")
NEW_TAB = (FIXTURE, resource_step("setup", "tab.create_terminal", {}, count(TABS, 2), {"pane": FIXTURE_PANE}))
NEW_SCREEN = (resource_step("setup", "screen.create", {"name": "second"}, count(SCREENS, 2)),)
NEW_WORKSPACE = (resource_step("setup", "workspace.create", {"initial_content": "terminal", "name": "second"},
                               count(WORKSPACES, 2)),)


@dataclass(frozen=True)
class TuiCase:
    name: str
    title: str
    actions: Tuple[str, ...]
    steps: Tuple[Dict[str, Any], ...]
    menu: Tuple[str, ...] = ()


def action(name: str, title: str, keys: Sequence[str], *, setup: Sequence[Dict[str, Any]] = (),
           wait: Optional[Mapping[str, Any]] = None, actions: Sequence[str] = (), menu: Sequence[str] = (),
           after: Sequence[Dict[str, Any]] = (), checkpoint: Sequence[str] = ("settled",)) -> TuiCase:
    steps = (*setup, keys_step("act", keys, wait=wait, checkpoint=checkpoint), *after)
    return TuiCase(name, title, tuple(actions or (name,)), steps, tuple(menu))


def prompted(name: str, title: str, keys: Sequence[str], wait: Mapping[str, Any], *, menu: Sequence[str] = (),
             actions: Sequence[str] = ()) -> TuiCase:
    """An action that opens a prompt: the first step opens it and waits until it is drawn (keys typed before
    the prompt exists would reach the pane), the second types the name and submits it."""
    return TuiCase(name, title, tuple(actions or (name,)), (
        keys_step("open", keys, wait=changed(SCREEN_HASH), checkpoint=("before",)),
        keys_step("act", ["o", "k", "return"], wait=wait),
    ), tuple(menu))


def modal(name: str, title: str, keys: Sequence[str], close: Sequence[str], *, actions: Sequence[str] = (),
          menu: Sequence[str] = (), setup: Sequence[Dict[str, Any]] = ()) -> TuiCase:
    """An action that leaves the frontend out of pane input mode: the step proves it drew (the screen hash
    changed), records its before checkpoint, and the next step closes it and settles."""
    return action(name, title, keys, setup=setup, wait=changed(SCREEN_HASH), actions=actions, menu=menu,
                  checkpoint=("before",), after=(keys_step("close", close),))


# Selection and focus (tabs, panes, screens, workspaces) are this client's view, not session state: the daemon
# facet does not move, so those cases wait for the screen. Undo reverts a resize or swap, not a split.
CASES: Tuple[TuiCase, ...] = (
    action("send-prefix", "the prefix pressed twice sends Ctrl-b to the shell", [PREFIX, PREFIX]),
    action("new-tab", "prefix t opens a terminal tab", prefixed("t"), wait=count(TABS, 2), menu=("NewTab",)),
    action("new-pane-smart", "prefix N opens a pane", prefixed("shift+n"), wait=count(PANES, 2),
           menu=("NewPaneSmart",)),
    action("new-pane-smart-alt", "Alt-n opens a pane without the prefix", ["alt+n"], wait=count(PANES, 2),
           actions=("new-pane-smart",)),
    action("next-tab", "prefix Tab selects the next tab", prefixed("tab"), setup=NEW_TAB, wait=changed(SCREEN_HASH)),
    action("prev-tab", "prefix Shift-Tab selects the previous tab", prefixed("shift+tab"), setup=NEW_TAB,
           wait=changed(SCREEN_HASH)),
    action("select-tab", "prefix i (the oracle config's select-tab-0) selects tab 0", prefixed(SELECT_TAB_0_KEY),
           setup=[*NEW_TAB, keys_step("next", prefixed("tab"), wait=changed(SCREEN_HASH))], wait=changed(SCREEN_HASH),
           actions=("select-tab-{number}",)),
    action("split-right", "prefix % splits right", prefixed("shift+5"), wait=count(PANES, 2), menu=("SplitRight",)),
    action("split-down", "prefix \" splits down", prefixed("shift+'"), wait=count(PANES, 2), menu=("SplitDown",)),
    action("close-tab", "prefix x closes the active tab", prefixed("x"), setup=NEW_TAB, wait=count(TABS, 1),
           menu=("CloseTab",)),
    action("close-pane", "prefix X closes the active pane", prefixed("shift+x"), setup=SPLIT, wait=count(PANES, 1),
           menu=("ClosePane",)),
    prompted("rename-tab", "prefix y (the oracle config's rename-tab) renames the tab through its prompt",
             prefixed(RENAME_TAB_KEY), changed(TABS), menu=("RenameTab",)),
    prompted("rename-screen", "prefix , renames the screen through its prompt", prefixed(","), changed(SCREENS),
             menu=("RenameScreen",)),
    prompted("rename-workspace", "prefix $ renames the workspace through its prompt", prefixed("shift+4"),
             changed(WORKSPACES), menu=("RenameWorkspace",)),
    action("close-screen", "prefix & closes the active screen", prefixed("shift+7"), setup=NEW_SCREEN,
           wait=count(SCREENS, 1), menu=("CloseScreen",)),
    action("prev-screen", "prefix p selects the previous screen", prefixed("p"), setup=NEW_SCREEN,
           wait=changed(SCREEN_HASH)),
    action("next-screen", "prefix n selects the next screen", prefixed("n"),
           setup=[*NEW_SCREEN, keys_step("prev", prefixed("p"), wait=changed(SCREEN_HASH))], wait=changed(SCREEN_HASH)),
    action("select-screen", "prefix 1 selects screen 1", prefixed("1"), setup=NEW_SCREEN,
           wait=changed(SCREEN_HASH), actions=("select-screen-{number}",)),
    action("new-screen", "prefix c opens a screen", prefixed("c"), wait=count(SCREENS, 2)),
    action("prev-workspace", "prefix ( selects the previous workspace", prefixed("shift+9"), setup=NEW_WORKSPACE,
           wait=changed(SCREEN_HASH)),
    action("next-workspace", "prefix w selects the next workspace", prefixed("w"), setup=NEW_WORKSPACE,
           wait=changed(SCREEN_HASH)),
    action("new-workspace", "prefix W opens a workspace", prefixed("shift+w"), wait=count(WORKSPACES, 2)),
    action("close-workspace", "prefix D closes the active workspace", prefixed("shift+d"), setup=NEW_WORKSPACE,
           wait=count(WORKSPACES, 1), menu=("CloseWorkspace",)),
    action("toggle-sidebar", "prefix s hides the sidebar", prefixed("s"), menu=("ToggleSidebar",)),
    action("toggle-sidebar-compact", "prefix m makes the sidebar compact", prefixed("m"),
           menu=("ToggleSidebarCompact",)),
    action("toggle-sidebar-view", "prefix e shows the next sidebar view", prefixed("e")),
    modal("focus-sidebar", "prefix S focuses the sidebar; Escape returns to the pane", prefixed("shift+s"),
          ["escape"], menu=("FocusSidebar",)),
    TuiCase("pin-workspace", "p in the focused workspace rail pins the workspace; Escape returns to the pane",
            ("focus-sidebar",), (
                keys_step("pin", [*prefixed("shift+s"), "p"], wait=changed(SIDEBAR), checkpoint=("before",)),
                keys_step("close", ["escape"]),
            ), ("PinWorkspace",)),
    action("new-pane-right", "prefix g opens a pane to the right", prefixed("g"), wait=count(PANES, 2)),
    action("undo-layout", "prefix U undoes a resize", prefixed("shift+u"),
           setup=[*SPLIT, keys_step("grow", prefixed("plus"), wait=changed(SCREENS))], wait=changed(SCREENS)),
    action("focus-right", "prefix l focuses the right pane", prefixed("l"), setup=SPLIT, wait=changed(SCREEN_HASH)),
    action("focus-left", "prefix h focuses the left pane", prefixed("h"),
           setup=[*SPLIT, keys_step("right", prefixed("l"), wait=changed(SCREEN_HASH))], wait=changed(SCREEN_HASH)),
    action("focus-down", "prefix j focuses the lower pane", prefixed("j"), setup=SPLIT_DOWN,
           wait=changed(SCREEN_HASH)),
    action("focus-up", "prefix k focuses the upper pane", prefixed("k"),
           setup=[*SPLIT_DOWN, keys_step("down", prefixed("j"), wait=changed(SCREEN_HASH))], wait=changed(SCREEN_HASH)),
    action("focus-next-pane", "prefix o focuses the next pane", prefixed("o"), setup=SPLIT,
           wait=changed(SCREEN_HASH)),
    action("swap-pane-prev", "prefix { swaps with the previous pane", prefixed("shift+["), setup=SPLIT,
           wait=changed(SCREENS)),
    action("swap-pane-next", "prefix } swaps with the next pane", prefixed("shift+]"), setup=SPLIT,
           wait=changed(SCREENS)),
    action("zoom-pane", "prefix z zooms the active pane", prefixed("z"), setup=SPLIT, wait=changed(PANES),
           menu=("TogglePaneZoom",)),
    action("resize-grow", "prefix + grows the active pane", prefixed("plus"), setup=SPLIT, wait=changed(SCREENS)),
    action("resize-shrink", "prefix - shrinks the active pane", prefixed("-"), setup=SPLIT, wait=changed(SCREENS)),
    action("scroll-up", "prefix [ scrolls the viewport up", prefixed("[")),
    action("scroll-down", "prefix PageDown scrolls the viewport down", prefixed("pagedown")),
    action("clear-history", "Cmd-k clears the terminal history", ["cmd+k"]),
    action("browser-back", "prefix < on a terminal tab goes to the terminal", prefixed("shift+,"),
           menu=("BrowserBack",)),
    action("browser-forward", "prefix > on a terminal tab goes to the terminal", prefixed("shift+."),
           menu=("BrowserForward",)),
    action("browser-reload", "prefix r on a terminal tab goes to the terminal", prefixed("r"),
           menu=("BrowserReload",)),
    action("browser-edit-url", "prefix u on a terminal tab goes to the terminal", prefixed("u"),
           menu=("BrowserEditUrl",)),
    modal("show-shortcuts", "prefix ? shows the shortcut overlay; Escape closes it", prefixed("shift+/"),
          ["escape"], menu=("ShowShortcuts",)),
    action("user-command", "prefix a (the oracle config's user command) opens its shell tab",
           prefixed(USER_COMMAND_KEY), wait=count(TABS, 2), actions=("user-command-{index}",)),
    action("detach", "prefix d detaches the frontend (it exits 0); the daemon keeps the session", prefixed("d"),
           wait={"pointer": "/tui/exit", "equals": 0, "maxMs": 10000}),
)

# Cases whose settled checkpoints differ between runs of one build, and why. oracle.py reports them flaky and
# leaves them out of a base/head comparison; each is a finding for its owner, not a driver race (observed on the
# VM: 10 repeats of the suite, 40 to 60 runs of each case). coverage.json lists them.
SELECTION_RACE = "cmux-tui: the frontend selects a surface it created when the creation's completion arrives, and " \
                 "only if its tree already holds the surface (app/session_apply.rs select_completed_surface, " \
                 "tab_locations); when the remote tree refresh lands after the completion, the old pane or screen " \
                 "stays selected (1 to 3 runs in 20 on the VM). The daemon facet is the same; the screen differs"
UNSEEDED_IDS = "two workspaces: session.snapshot orders screens by workspace id (workspace_registry " \
               "resource_store/topology_load.rs load_screens, ORDER BY workspace_id), and ids are random until " \
               "p15-oracle-185 seeds them, so the canonical labels swap in about half the runs; the daemon-ops " \
               "suite's two-workspace cases show the same"
RACES: Dict[str, str] = {
    "new-screen": SELECTION_RACE,
    "new-pane-smart": SELECTION_RACE,
    "split-right": SELECTION_RACE,
    "split-down": SELECTION_RACE,
    "new-pane-right": SELECTION_RACE,
    "new-workspace": UNSEEDED_IDS,
    "close-workspace": UNSEEDED_IDS,
    "prev-workspace": UNSEEDED_IDS,
    "next-workspace": UNSEEDED_IDS,
}

# Inventory actions with no case, and why.
MOUSE_MENU = "is reached only from a context menu, which opens on a mouse right-click (app/menu_build.rs " \
             "open_context_menu); a tui.key step sends keys only"
PROVIDER = "needs a machine provider (--machine-provider); the hermetic case has none"
NO_BROWSER = "opens a browser tab whose engine never starts in the hermetic case (no browser host): the tab " \
             "shows `starting browser...` until the start times out, so neither its screen nor its daemon state " \
             "settles"
TUI_REASONS: Dict[str, str] = {
    "provider-menu": f"provider-menu {PROVIDER}",
    "new-browser-tab": f"new-browser-tab {NO_BROWSER}",
}
MENU_REASONS: Dict[str, str] = {
    **{name: f"{name} {PROVIDER}" for name in (
        "RenameManagedMachine", "DeleteManagedMachine", "RestoreManagedMachine", "PurgeManagedMachine",
        "RenameManagedWorkspace", "DeleteManagedWorkspace", "RestoreManagedWorkspace", "PurgeManagedWorkspace",
        "SelectProviderScope", "InvokeProviderAction")},
    **{name: f"{name} {MOUSE_MENU}" for name in (
        "RenameClientMachine", "CopyWorkspaceId", "RenameSurface", "CopyTabId", "CopyPaneId", "CopyStatusMessage",
        "ActivateSidebarProfile", "SetSidebarViewVisible", "SetClientSizing", "UseClientSize",
        "RestoreAllClientSizing", "DisconnectClient", "SetSizeMode", "SetSizeCounts", "DisconnectSizeParticipant",
        "CreateMachineFrom", "ConnectMachineTarget", "ConnectOtherMachine", "RunConfigured", "MoveTabToWorkspace")},
    "BrowserCopyUrl": f"BrowserCopyUrl {MOUSE_MENU}, on a browser tab the hermetic daemon cannot open",
    "BrowserActivate": f"BrowserActivate {MOUSE_MENU}, on a browser tab the hermetic daemon cannot open",
    "NewBrowserTab": f"NewBrowserTab {NO_BROWSER}",
}


def case_json(case: TuiCase) -> Dict[str, Any]:
    return {
        "$schema": "../../../../schemas/oracle/case-v1.schema.json",
        "corpusVersion": 1, "id": case.name, "suite": "tui", "title": case.title, "surface": "cmux-tui",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"}, "environment": {},
        "fixture": {"seed": f"tui-{case.name}", "network": "offline", "clock": "fixed"},
        "preconditions": ["cmux-tui attach on a PTY owned by driver_tui.py"],
        "requires": sorted({TUI_CAPABILITY, *(["resource_api"] if any(step["op"] == "resource.call"
                                                                        for step in case.steps) else [])}),
        "platforms": ["linux"],
        "steps": [dict(step) for step in case.steps],
        "invariants": [], "teardown": ["hang up the TUI's terminal", "stop the case daemon"],
    }


def load_inventory(path: Path = INVENTORY) -> Tuple[List[str], List[str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return [a["key"] for a in data["tui_actions"]], [a["variant"] for a in data["menu_actions"]]


def coverage(cases: Sequence[TuiCase] = CASES, inventory: Path = INVENTORY) -> Dict[str, Any]:
    """Each inventory action: the cases that press it, or the reason none can. Unknown names are an error."""
    tui_actions, menu_actions = load_inventory(inventory)
    by_action: Dict[str, List[str]] = {}
    by_menu: Dict[str, List[str]] = {}
    for case in cases:
        for name in case.actions:
            by_action.setdefault(name, []).append(case.name)
        for name in case.menu:
            by_menu.setdefault(name, []).append(case.name)
    problems = [f"tui action {name} is not in the inventory" for name in sorted(set(by_action) - set(tui_actions))]
    problems += [f"menu action {name} is not in the inventory" for name in sorted(set(by_menu) - set(menu_actions))]
    problems += [f"reason for {name}, which is not in the inventory" for name in
                 sorted((set(TUI_REASONS) - set(tui_actions)) | (set(MENU_REASONS) - set(menu_actions)))]
    out: Dict[str, Any] = {"generator": "scripts/cmux-next/oracle/gen_tui.py", "suite": "tui", "task": TASK,
                           "inventory": "cmux-tui/spec/inventory.json", "total": len(tui_actions) + len(menu_actions),
                           "covered": 0, "excluded": {}, "missing": [], "tui_actions": {}, "menu_actions": {}}
    for kind, names, cased, reasons in (("tui_actions", tui_actions, by_action, TUI_REASONS),
                                        ("menu_actions", menu_actions, by_menu, MENU_REASONS)):
        for name in names:
            if name in cased and name in reasons:
                problems.append(f"{name} has both cases and a reason")
            elif name in cased:
                out[kind][name] = {"cases": sorted(cased[name])}
                out["covered"] += 1
            elif name in reasons:
                out[kind][name] = {"reason": reasons[name]}
                out["excluded"][f"{kind}/{name}"] = reasons[name]
            else:
                out["missing"].append(f"{kind}/{name}")
    problems += [f"{name} has neither a case nor a reason" for name in out["missing"]]
    names = {case.name for case in cases}
    problems += [f"RACES names {name}, which is not a case" for name in sorted(set(RACES) - names)]
    out["nondeterministic"] = {name: RACES[name] for name in sorted(RACES) if name in names}
    if problems:
        raise ValueError("; ".join(problems))
    return out


def corpus_files(cases: Sequence[TuiCase] = CASES) -> Dict[str, str]:
    files = {f"{case.name}.json": json.dumps(case_json(case), indent=1, ensure_ascii=False) + "\n" for case in cases}
    files[COVERAGE_FILE.name] = json.dumps(coverage(cases), indent=1, ensure_ascii=False) + "\n"
    return files


def cmd_corpus(args: argparse.Namespace) -> int:
    files = corpus_files()
    present = {path.name for path in CORPUS.glob("*.json")} if CORPUS.is_dir() else set()
    if args.write:
        CORPUS.mkdir(parents=True, exist_ok=True)
        for name in present - set(files):
            (CORPUS / name).unlink()
        for name, text in files.items():
            (CORPUS / name).write_text(text, encoding="utf-8")
        print(f"wrote {len(files)} files to {CORPUS.relative_to(REPO)}")
        return 0
    stale = sorted(name for name, text in files.items()
                   if not (CORPUS / name).is_file() or (CORPUS / name).read_text(encoding="utf-8") != text)
    stale += sorted(present - set(files))
    if stale:
        print(f"tests/oracle/corpus/tui is stale ({', '.join(stale)}): run gen_tui.py --write",
              file=sys.stderr)
        return 1
    print(f"tests/oracle/corpus/tui matches CASES ({len(files) - 1} cases)")
    return 0


def cmd_coverage(_args: argparse.Namespace) -> int:
    report = coverage()
    summary = {kind: {"cases": sum(1 for v in report[kind].values() if "cases" in v),
                      "reasons": sum(1 for v in report[kind].values() if "reason" in v)}
               for kind in ("tui_actions", "menu_actions")}
    print(json.dumps(summary, indent=1, sort_keys=True))
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write tests/oracle/corpus/tui")
    mode.add_argument("--check", action="store_true", help="exit 1 when the corpus is stale")
    mode.add_argument("--coverage", action="store_true", help="the inventory coverage summary")
    args = parser.parse_args(argv)
    try:
        return cmd_coverage(args) if args.coverage else cmd_corpus(args)
    except ValueError as error:
        print(f"gen_tui.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
