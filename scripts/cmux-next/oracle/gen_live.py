#!/usr/bin/env python3
"""Generate the live suite: the scripts/cmux-next/*-live(-check).py checks as oracle cases, or why each one is not.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite `live`, golden) and task 225 (machine queue
MQ-live: `ls scripts/cmux-next | grep -E -- '-live(-check)?\\.py$'`, 8 batches). Stdlib only, Python 3.9+, safe
under `python3 -I`. `oracle.py gen --suite live` runs it with `--out <corpus>/live`.

Chrome reference (chromium/src): a browser test that once lived as a manual check becomes an interactive UI test
(chrome/test/interaction/README.md, Kombucha): its scenario is a list of Action, WaitForState and Check verbs and
the shared harness owns launch, waits and teardown. Here a live script's scenario becomes case-v1 steps (action.run,
key, cli, mcp, settle, snapshot, each wait a `waitFor` on a facet the app signals), its asserts become `expect`,
`waitFor` and the case's invariants, and the golden baselines hold the settled facets. A check no case-v1 step can
drive or no snapshot-v1 facet holds is listed in the case's `untested`, so a partial conversion says what it leaves
to the script. The script stays where it is: `live-map.json` links each one to its cases.

Every script is in exactly one of two tables:

  CONVERSIONS  script -> the cases built from it (one per engine where the script loops over engines)
  EXCLUSIONS   script -> (kind, task, reason): why no case can carry it; `kind` is one of EXCLUSION_KINDS and
               `task` the WORK.tsv task that closes the gap (or the suite's task that covers the script)

Outputs (written whole; `--check` compares instead of writing):

  tests/oracle/corpus/live/<case>.json   the cases
  tests/oracle/corpus/live/coverage.json covered/total over the scripts, each excluded script with its reason
  scripts/cmux-next/oracle/live-map.json every script: converted (its cases, its batch, what stays untested) or
                                         excluded (kind and reason); the batch of 8 a fleet run takes it in

Usage:
  gen_live.py [--out DIR] [--map FILE]            write the cases, coverage.json and live-map.json
  gen_live.py [--out DIR] [--map FILE] --check    exit 1 when any of them differs from a fresh generation, or a
                                                  live script is in neither table
  gen_live.py --selftest                          offline tests (gen_live_test.py)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCRIPTS = REPO / "scripts" / "cmux-next"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "live"
DEFAULT_MAP = HERE / "live-map.json"
SUITE = "live"
TASK = "p15-oracle-225"
GENERATOR = "scripts/cmux-next/oracle/gen_live.py"
COVERAGE = "coverage.json"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
# MQ-live of the spec (section 7): the inventory is every file of scripts/cmux-next this matches.
INVENTORY = re.compile(r"-live(-check)?\.py$")
INVENTORY_COMMAND = "ls scripts/cmux-next | grep -E -- '-live(-check)?\\.py$'"
BATCHES = 8
MAX_KEYS = 32  # case-v1 keyArgs.maxItems
WAIT_MS = 10_000
LOAD_MS = 15_000

EXCLUSION_KINDS: Dict[str, str] = {
    "pointer": "its checks need pointer input (debug.mouse, cua-driver, HID events or a real right-click); case-v1 "
               "has no pointer step",
    "relaunch": "its checks hold across an app quit and relaunch; driver_app.py has no app restart step (restart "
                "belongs to driver_daemon.py)",
    "perf": "it measures time, frames, CPU, memory or process limits; the oracle compares settled state, and the "
            "measurement stays a perf-lab story run on the fleet",
    "network": "it needs a host off loopback, a real service or credentials; oracle cases run offline "
               "(fixture.network offline)",
    "model": "it needs a real Chief brain, model or ACP agent run; the oracle launch has the mock agent pane only",
    "launch": "it needs a launch the bench launch does not make (another bundle id, a copied bundle, an inherited "
              "environment, a seeded state root or a custom config file)",
    "no-facet": "what it checks is read through debug.* methods that no snapshot-v1 facet carries",
    "host": "it checks host state outside the app (macOS services, the pasteboard, simulators, ~/Downloads)",
    "suite": "its scenario belongs to another oracle suite, which covers it",
    "evidence": "it produces captures or evaluation data, not a pass/fail check",
    "schema": "case-v1 refuses a value the scenario must name",
}

# ------------------------------------------------------------------------------------------------- steps

TARGET = {"window": "current"}
# Keys to the open command palette's panel (case-v1 target.overlay, driver_app.py debug.key target palette), as
# a person's keys go to the palette while it is the key panel; window-style-preview-live.py's key() does the same.
PALETTE = {"overlay": "palette"}
NO_RECEIPT = "no app reply carries the ActionEffect kind yet (driver_app.py); the settled facets are the check"
TYPED_NO_RECEIPT = "typed text goes to the focused field or terminal, not to an action"
# A key some panel answers itself runs no perform turn of the action registry, so its step has no turn checkpoint.
PALETTE_KEY_NO_TURN = ("the palette panel's own key handler takes it (PaletteController.handleKeyDown, "
                       "PaletteModel.handle), not a perform turn of the registry; the settled facets are the check")
DIALOG_KEY_NO_TURN = ("the cmux dialog in front answers it (its key-hint buttons), not a perform turn of the "
                      "registry; the settled facets are the check")
SHEET_KEY_NO_TURN = ("the system print sheet answers it (AppKit's sheet, not the app's key router), so no perform "
                     "turn runs; the settled facets are the check")
SOCKET_NO_RECEIPT = ("the {op} reply carries no ActionEffect kind the driver reads (driver_app.py op_{op}); the "
                     "settled facets are the check")
# driver_app.py op_cli reads every nonzero exit as cli.failed (the CLI writes its error to stderr), op_mcp reads an
# isError result as mcp.tool_error, and an action.run refusal keeps the app's own code under `control.`.
CLI_REFUSED = "cli.failed"
MCP_REFUSED = "mcp.tool_error"
CONFIRMATION_REQUIRED = "control.confirmation_required"  # ControlError.confirmationRequired
WORKSPACES = "/topology/topology/workspaces"
TAB_COUNT = "/topology/tab_count"
FIRST_TAB = "/tabs/panes/0/tabs/0"
PALETTE_OPEN = "/overlays/palette/open"
PALETTE_QUERY = "/overlays/palette/querySha256"
PALETTE_TOP = "/overlays/palette/topIds"
# The palette's row id of an action (RegistryPaletteProvider: `action:<id>`), as topIds lists it.
ACTION_ROW = "action:{}"
# Characters a typed string may hold, as case-v1 keystrokes ($defs/keystroke).
SHIFTED = {":": ";", "_": "-", "?": "/", "+": "=", "\"": "'", "<": ",", ">": ".", "{": "[", "}": "]", "|": "\\",
           "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
           ")": "0"}
PLAIN = set("abcdefghijklmnopqrstuvwxyz0123456789-=[];',./`\\")


class GenError(Exception):
    """A conversion that cannot be written (a bad keystroke, a duplicate id, a script in no table)."""


def wait(pointer: str, *, equals: Any = None, predicate: Any = None, ms: int = WAIT_MS) -> Dict[str, Any]:
    out: Dict[str, Any] = {"pointer": pointer, "maxMs": ms}
    if predicate is not None:
        out["predicate"] = predicate
    else:
        out["equals"] = equals
    return out


def changed(pointer: str, ms: int = WAIT_MS) -> Dict[str, Any]:
    return wait(pointer, predicate="changed", ms=ms)


def _finish(step: Dict[str, Any], waits: Optional[Mapping[str, Any]], note: Optional[str],
            checkpoint: Optional[Sequence[str]]) -> Dict[str, Any]:
    if waits:
        step["waitFor"] = dict(waits)
    if checkpoint:
        step["checkpoint"] = list(checkpoint)
    if note:
        step["note"] = note
    return step


def act(sid: str, action: str, params: Optional[Mapping[str, Any]] = None, *, target: Optional[Mapping[str, Any]] = None,
        error: Optional[str] = None, waits: Optional[Mapping[str, Any]] = None, note: Optional[str] = None,
        entrypoint: str = "script") -> Dict[str, Any]:
    args: Dict[str, Any] = {"action": action, "entrypoint": entrypoint}
    if params:
        args["params"] = dict(params)
    expect = {"outcome": "error", "error": error} if error else {"outcome": "ok", "noReceiptReason": NO_RECEIPT}
    step = {"id": sid, "op": "action.run", "target": dict(target or TARGET), "args": args, "expect": expect}
    # A refused run (ControlRouter+ActionRun prepared(): confirmation_required, an unavailable action) is refused
    # before the registry performs it, so no turn runs: as gen_actions.py, an error step has no turn checkpoint.
    return _finish(step, waits, note, ["before", "settled"] if error else ["before", "turn", "settled"])


def key(sid: str, *strokes: str, target: Optional[Mapping[str, Any]] = None,
        waits: Optional[Mapping[str, Any]] = None, note: Optional[str] = None, typed: bool = False,
        no_turn: Optional[str] = None) -> Dict[str, Any]:
    """A key step. `typed`: text for the focused field (settled only). `no_turn`: why no registry perform turn
    answers these keys (a palette, dialog or system sheet takes them), so the step records before and settled."""
    if not strokes or len(strokes) > MAX_KEYS:
        raise GenError(f"{sid}: a key step sends 1 to {MAX_KEYS} keystrokes, not {len(strokes)}")
    if typed and no_turn:
        raise GenError(f"{sid}: typed text has no turn checkpoint already")
    expect = {"outcome": "ok", "noReceiptReason": TYPED_NO_RECEIPT if typed else no_turn or NO_RECEIPT}
    step = {"id": sid, "op": "key", "target": dict(target or TARGET), "args": {"keys": list(strokes)},
            "expect": expect}
    checkpoint = ["settled"] if typed else ["before", "settled"] if no_turn else ["before", "turn", "settled"]
    return _finish(step, waits, note, checkpoint)


def keystrokes(text: str) -> List[str]:
    """`text` as the case-v1 keystrokes a person types: shift for capitals and shifted symbols."""
    out = []
    for char in text:
        if char == " ":
            out.append("space")
        elif char in PLAIN:
            out.append(char)
        elif char.isalpha() and char.isascii() and char.isupper():
            out.append("shift+" + char.lower())
        elif char in SHIFTED:
            out.append("shift+" + SHIFTED[char])
        else:
            raise GenError(f"{char!r} is not a keystroke case-v1 can type")
    return out


def type_text(sid: str, text: str, *, target: Optional[Mapping[str, Any]] = None,
              waits: Optional[Mapping[str, Any]] = None, note: Optional[str] = None) -> List[Dict[str, Any]]:
    """Key steps that type `text` into the focused field (or `target`'s), MAX_KEYS keys a step; `waits` goes on
    the last."""
    strokes = keystrokes(text)
    chunks = [strokes[i:i + MAX_KEYS] for i in range(0, len(strokes), MAX_KEYS)]
    steps = []
    for index, chunk in enumerate(chunks):
        last = index == len(chunks) - 1
        steps.append(key(sid if len(chunks) == 1 else f"{sid}-{index + 1}", *chunk, target=target, typed=True,
                         waits=waits if last else None, note=note if last else None))
    return steps


def cli(sid: str, *argv: str, error: Optional[str] = None, read: bool = False,
        target: Optional[Mapping[str, Any]] = None, waits: Optional[Mapping[str, Any]] = None,
        note: Optional[str] = None) -> Dict[str, Any]:
    step: Dict[str, Any] = {"id": sid, "op": "cli"}
    if read:
        step["readOnly"] = True
        step["expect"] = {"outcome": "ok"}
    else:
        step["target"] = dict(target or TARGET)
        step["expect"] = ({"outcome": "error", "error": error} if error
                          else {"outcome": "ok", "noReceiptReason": SOCKET_NO_RECEIPT.format(op="cli")})
    step["args"] = {"argv": list(argv)}
    return _finish(step, waits, note, ["before", "settled"])


def mcp(sid: str, tool: str, arguments: Mapping[str, Any], *, error: Optional[str] = None,
        waits: Optional[Mapping[str, Any]] = None, note: Optional[str] = None) -> Dict[str, Any]:
    expect = {"outcome": "error", "error": error} if error else {"outcome": "ok",
                                                                 "noReceiptReason": SOCKET_NO_RECEIPT.format(op="mcp")}
    step = {"id": sid, "op": "mcp", "target": dict(TARGET), "args": {"tool": tool, "arguments": dict(arguments)},
            "expect": expect}
    return _finish(step, waits, note, ["before", "settled"])


def settle(sid: str, *, waits: Optional[Mapping[str, Any]] = None, note: Optional[str] = None) -> Dict[str, Any]:
    return _finish({"id": sid, "op": "settle"}, waits, note, None)


def snapshot(sid: str, *facets: str, waits: Optional[Mapping[str, Any]] = None,
             note: Optional[str] = None) -> Dict[str, Any]:
    step: Dict[str, Any] = {"id": sid, "op": "snapshot"}
    if facets:
        step["args"] = {"facets": list(facets)}
    return _finish(step, waits, note, None)


def query_sha256(text: str) -> str:
    """The palette facet's querySha256 of typed `text` (OracleOverlaysFacet: sha256 of the text, which holds no
    case path for OraclePaths to rewrite)."""
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def palette_open(sid: str) -> Dict[str, Any]:
    return key(sid, "cmd+shift+p", waits=wait(PALETTE_OPEN, equals=True), note="Cmd-Shift-P opens the palette")


def palette_query(sid: str, query: str, *, top: Optional[str] = None,
                  lists: Sequence[str] = ()) -> List[Dict[str, Any]]:
    """`query` typed into the open palette, waited on as the palette's own query. `top`: the action whose row the
    ranked rows must put first (Return runs it); `lists`: actions whose rows the ranked rows must hold."""
    steps = type_text(sid, query, target=PALETTE, waits=wait(PALETTE_QUERY, equals=query_sha256(query)),
                      note=f"the palette's field holds {query!r}")
    if top:
        steps.append(settle(f"{sid}-top", waits=wait(f"{PALETTE_TOP}/0", equals=ACTION_ROW.format(top)),
                            note=f"the query's ranked rows put {top} first"))
    for action in lists:
        steps.append(settle(f"{sid}-lists-{slug(action)}",
                            waits=wait(PALETTE_TOP, predicate={"op": "contains", "value": ACTION_ROW.format(action)}),
                            note=f"the query's ranked rows list {action}"))
    return steps


def palette_close(sid: str, note: Optional[str] = None) -> Dict[str, Any]:
    """Escape twice: with a query, the first clears it and the second closes (PaletteNavReducer.escape), as
    window-style-preview-live.py's close_palette sends Escape until the palette closes."""
    return key(sid, "escape", "escape", target=PALETTE, no_turn=PALETTE_KEY_NO_TURN,
               waits=wait(PALETTE_OPEN, equals=False),
               note=note or "the first Escape clears the query, the second closes the palette")


def palette_run(sid: str, query: str, top: str, *, waits: Optional[Mapping[str, Any]] = None,
                note: Optional[str] = None) -> List[Dict[str, Any]]:
    """A person's palette run: Cmd-Shift-P, the query typed, its ranked rows with `top` first, then Return."""
    steps = [palette_open(f"{sid}-open")] + palette_query(f"{sid}-query", query, top=top)
    steps.append(key(f"{sid}-return", "return", target=PALETTE, no_turn=PALETTE_KEY_NO_TURN, waits=waits,
                     note=note))
    steps.append(settle(f"{sid}-closed", waits=wait(PALETTE_OPEN, equals=False),
                        note="running the row closes the palette"))
    return steps


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def new_workspace(sid: str, name: str, *, focus: bool = False) -> Dict[str, Any]:
    argv = ["workspace", "create", "--name", name, "--json"] + (["--focus"] if focus else [])
    return cli(sid, *argv, waits=changed(WORKSPACES),
               note=f"a workspace named {name}; its reply's value holds workspace_id, pane_id, tab_id and terminal_id")


def new_browser(sid: str, engine: str, url: str, *, load: str = "finished") -> Dict[str, Any]:
    """A browser tab of `engine` opened as the CLI opens it, in front (`--focus`), its first load ended before the
    next step. `load` is the tabs facet's loadState the load ends in: `loading` is already false while the tab is
    `unloaded` (no engine page yet) or `idle` (before its first navigation), so only loadState says it loaded."""
    argv = ["tab", f"new-{engine}", "--url", url, "--focus"]
    return cli(sid, *argv, waits=wait(f"{FIRST_TAB}/loadState", equals=load, ms=LOAD_MS),
               note=f"a {engine} tab in front, its first load {load}")


# ------------------------------------------------------------------------------------------------- cases

ENGINE_OF = {"webkit": "webkit", "chromium": "chromium"}
TEARDOWN = ["the driver quits the tagged app it launched and ends the tag's daemons (TagTeardown)",
            "the driver resets the session before the next case (app_reset.py)"]


def case(cid: str, script: str, title: str, steps: Sequence[Mapping[str, Any]], *, invariants: Sequence[str],
         untested: Sequence[str] = (), engine: str = "none", web: bool = False, priority: str = "P1",
         preconditions: Sequence[str] = ()) -> Dict[str, Any]:
    ops = {s["op"] for s in steps}
    requires = ["actions", "gui"]
    if "key" in ops:
        requires.append("keys")
    if "mcp" in ops:
        requires.append("mcp")
    if engine == "chromium":
        requires.append("chromium")
    fixture: Dict[str, Any] = {"seed": f"live.{cid}", "network": "offline", "clock": "fixed", "agent": "mock"}
    if web:
        fixture["web"] = True
    out: Dict[str, Any] = {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": cid,
        "suite": SUITE,
        "title": title[:200],
        "priority": priority,
        "surface": "cmux-next-native",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        # As gen_actions.py, gen_daemon_ops.py and gen_mcp.py: the launch applies only `viewport`
        # (driver_app.launch_spec). The engine is pinned by `requires: chromium` and the `tab new-<engine>` step.
        "environment": {},
        "fixture": fixture,
        "preconditions": ["a fresh driver_app.py session: bench config, animations off, the mock agent pane",
                          "the launch's first workspace is shown with its terminal focused", *preconditions],
        "requires": requires,
        "platforms": ["mac"],
        "steps": [dict(s) for s in steps],
        "invariants": [f"converted from scripts/cmux-next/{script} ({TASK}); the script stays, and "
                       f"scripts/cmux-next/oracle/live-map.json links it to this case", *invariants],
        "teardown": list(TEARDOWN),
    }
    if untested:
        out["untested"] = list(untested)
    return out


def close_all_workspaces() -> List[Dict[str, Any]]:
    script = "close-all-workspaces-live.py"
    steps = [new_workspace("make-beta", "beta"), new_workspace("make-gamma", "gamma"),
             new_workspace("make-delta", "delta")]
    steps.append(palette_open("palette-look-open"))
    steps += palette_query("palette-look-query", "close all workspaces",
                           lists=("workspace.closeAll", "workspace.closeAllInAllWindows"))
    steps.append(palette_close("palette-look-close"))
    steps += [
        act("script-refused", "workspace.closeAll", error=CONFIRMATION_REQUIRED,
            note="a script's run of a destructive action without confirm is refused"),
        cli("cli-refused", "workspace", "close-all", error=CLI_REFUSED,
            note="`cmux workspace close-all` without --confirm is refused"),
    ]
    steps += palette_run("person-close", "close all workspaces", "workspace.closeAll", waits=changed(WORKSPACES),
                         note="a person's run (Return on the top row) asks nothing for idle terminals and closes the "
                              "window's four workspaces, with the workspaces-closed undo toast")
    steps += [
        new_workspace("make-epsilon", "epsilon"), new_workspace("make-zeta", "zeta"),
        cli("cli-close-other", "workspace", "close-other", "--confirm", waits=changed(WORKSPACES)),
        act("second-window", "newWindow", waits=wait("/windows/count", equals=2)),
        mcp("mcp-close-all", "app_workspace_close_all", {"confirm": True, "focus": True}, waits=changed(WORKSPACES)),
        act("third-window", "newWindow", waits=changed("/windows/count")),
        cli("cli-close-windows", "app", "close-other-windows", waits=wait("/windows/count", equals=1)),
        cli("cli-close-everywhere", "workspace", "close-all-in-all-windows", "--confirm", waits=changed(WORKSPACES)),
    ]
    return [case(
        "close-all-workspaces", script,
        "Close All Workspaces through the palette, a script, the CLI and MCP: refused without confirm, closes with it",
        steps, priority="P0",
        invariants=["the refused script and CLI runs change no workspace: their settled checkpoints equal the ones "
                    "before them",
                    "the palette's top rows for the query are workspace.closeAll and workspace.closeAllInAllWindows",
                    "the person's close leaves the window open (the store's home workspace never closes) and its "
                    "settled overlays stack holds one toast",
                    "the last close leaves no listed workspace in any window"],
        untested=["the close question while a terminal runs `sleep` and its Cancel: no facet holds a terminal's "
                  "foreground program, so no step can wait until sleep runs",
                  "the toast's Undo: debug.toast undo has no case step and the toast's button needs a pointer (p15-oracle-350)",
                  "`cmux mcp serve` tools/list: driver_app.py's mcp step sends tools/call only"])]


def close_toast() -> List[Dict[str, Any]]:
    script = "close-toast-live.py"
    steps = [
        cli("warn-off", "settings", "set", "app.warnBeforeClosingTab", "false", waits=changed("/settings/nonDefaultKeys"),
            note="no close question: the script's config sets app.warnBeforeClosingTab false"),
        key("open-settings", "cmd+,", waits=changed(TAB_COUNT)),
        key("close-settings", "cmd+w", waits=changed(TAB_COUNT), note="closing Settings shows no toast"),
        new_workspace("make-idle", "ct-idle", focus=True),
        cli("idle-tab", "tab", "create", "terminal", "--pane", "$step:make-idle#/stdout/value/pane_id", "--json",
            waits=changed(TAB_COUNT), note="a second terminal tab in the workspace's pane"),
        act("show-idle", "tab.focus", target={"tab": "$step:idle-tab#/stdout/value/tab_id"},
            note="Show Tab puts it in front, as a person's close is of a shown tab"),
        key("close-idle", "cmd+w", waits=changed(TAB_COUNT), note="closing an idle terminal shows no toast"),
    ]
    return [case(
        "close-toast", script, "The close toast shows only for a costly close: Settings and an idle terminal close "
                               "with no toast", steps,
        invariants=["after close-settings and after close-idle the settled overlays stack holds no toast",
                    "close-idle closes only the second tab: the workspace keeps its first terminal"],
        untested=["a terminal running `sleep` closes with the undo toast and Undo restores it: no facet holds a "
                  "terminal's foreground program, so no step can wait until sleep runs",
                  "Close Other Panes over three panes as one toast: the person's run goes through debug.toast "
                  "perform, which has no case step",
                  "a tab group whose only tab runs `sleep`: same foreground-program wait"])]


def window_style_preview() -> List[Dict[str, Any]]:
    script = "window-style-preview-live.py"
    steps = [snapshot("committed", "settings", "overlays"), palette_open("open")]
    steps += palette_query("query", "window style", lists=("appearance.chromeStyle.default",))
    steps += [key(f"down-{n}", "down", target=PALETTE, no_turn=PALETTE_KEY_NO_TURN,
                  waits=changed("/overlays/palette/selectedIndex"),
                  note="the selection moves; a Window Style row previews its style and writes nothing")
              for n in (1, 2, 3)]
    steps.append(palette_close("escape", note="the first Escape clears the query, the second closes the palette and "
                                              "puts the committed style back"))
    steps.append(palette_open("reopen"))
    steps += palette_query("query-again", "window style bare", top="appearance.chromeStyle.bare")
    steps.append(key("commit", "return", target=PALETTE, no_turn=PALETTE_KEY_NO_TURN,
                     waits=changed("/settings/effectiveSha256"),
                     note="Return on Window Style: Bare writes appearance.chromeStyle"))
    steps.append(settle("commit-closed", waits=wait(PALETTE_OPEN, equals=False),
                        note="running the row closes the palette"))
    return [case(
        "window-style-preview", script, "Window Style rows preview while selected and write only on Return", steps,
        invariants=["/settings/effectiveSha256 and /settings/nonDefaultKeys are the same at every checkpoint from "
                    "`committed` through `escape`: a preview writes nothing",
                    "after `commit` /settings/nonDefaultKeys holds appearance.chromeStyle (bare) and the palette is "
                    "closed"],
        untested=["the previewed style itself (debug.pane_chrome chrome_style): no snapshot-v1 facet holds the "
                  "window's drawn chrome style",
                  "window captures of each style"])]


def sidebar_density() -> List[Dict[str, Any]]:
    script = "sidebar-density-live.py"
    steps = [new_workspace("make-done", "done"), new_workspace("make-working", "working"),
             act("pin-current", "palette.toggleWorkspacePin", waits=changed("/sidebar/rows"),
                 note="the shown workspace is pinned (the top band)"),
             snapshot("default", "sidebar", "settings")]
    for name in ("comfortable", "expanded", "compact"):
        steps.append(act(f"density-{name}", f"sidebar.density.{name}", waits=changed("/settings/effectiveSha256"),
                         note=f"the palette and Options entry: writes sidebar.density = {name}"))
    return [case(
        "sidebar-density", script, "Sidebar densities through their actions: each writes sidebar.density and keeps "
                                   "the rows", steps,
        invariants=["each density step changes /settings/nonDefaultKeys only by sidebar.density",
                    "the sidebar's rows, their order, selection and pin are the same at every density"],
        untested=["row heights, padding and the one-line Comfortable layout (debug.sidebar_rows frames): no "
                  "snapshot-v1 facet holds row geometry",
                  "status glyphs of done and working rows: OSC 7501 records are in no facet the app can wait on",
                  "the favicon tab row of a web workspace and the group rows",
                  "the sidebar background menu's Options folder: no step opens a context menu (p15-oracle-350)"])]


def shortcut_hint_digits() -> List[Dict[str, Any]]:
    script = "shortcut-hint-digits-live.py"
    steps = [new_workspace(f"make-{n}", f"hint-{n}") for n in ("a", "b", "c")]
    steps += [key(f"select-{n}", f"cmd+{n}", note=f"Cmd-{n} selects the sidebar row numbered {n} (sidebar.numbering "
                                                  f"counts Home and the App Store)") for n in (3, 4, 5, 6, 1)]
    return [case(
        "shortcut-hint-digits", script, "Cmd-digit selects the sidebar row its digit chip names", steps,
        invariants=["after each select step /sidebar/selectedWorkspace is the row the digit counts to, Home and the "
                    "App Store included"],
        untested=["the chips drawn while Cmd is held (debug.shortcut_hints): a key step sends whole keystrokes, never "
                  "a held modifier, and no facet holds the chips"])]


def sidebar_group_menu() -> List[Dict[str, Any]]:
    script = "sidebar-group-menu-live.py"
    steps = [new_workspace("make-second", "group-second"), new_workspace("make-third", "group-third"),
             act("new-group", "workspace.moveToNewGroup", {"name": "Groups proof"}, waits=changed("/sidebar/rows"),
                 note="New Group, as the trailer row of Move to Group runs it: a name skips the name editor"),
             key("collapse", "ctrl+cmd+.", waits=changed("/sidebar/rows"),
                 note="Collapse hides the group's workspace rows"),
             key("expand", "ctrl+cmd+.", waits=changed("/sidebar/rows"), note="Expand shows them again")]
    return [case(
        "sidebar-group-menu", script, "New Group from a workspace, then collapse and expand the group", steps,
        invariants=["after new-group the shown workspace's row has a group and a group header row is listed above it",
                    "after collapse the group header is collapsed and its member rows are not listed; after expand "
                    "the rows equal the ones after new-group"],
        untested=["the right-click menus' rows (debug.sidebar_rows menu_x/menu_y): no step opens a context menu (p15-oracle-350)",
                  "Move to Group of a second workspace: the new group's id is in no step reply a later step can "
                  "reference (p15-oracle-180 seeds ids)",
                  "the group across a relaunch (phase verify): driver_app.py has no app restart step (p15-oracle-351)"])]


def dialogs_undo() -> List[Dict[str, Any]]:
    script = "dialogs-undo-live.py"
    steps = [new_workspace("make-group-member", "dlg-g", focus=True),
             key("new-group", "ctrl+cmd+g", waits=changed("/sidebar/rows"),
                 note="New Workspace Group with the shown workspace")]
    steps += palette_run("close-group", "close workspaces in group", "workspaceGroup.closeWorkspaces",
                         waits=changed(WORKSPACES),
                         note="Close Workspaces in Group asks nothing for idle terminals and shows the "
                              "workspace-group-closed toast")
    steps.append(new_workspace("make-tab-group", "dlg-t", focus=True))
    steps += palette_run("tab-group", "new tab group", "tabGroup.create",
                         note="New Tab Group from the shown tab (tab groups are in the daemon facet, which waitFor "
                              "cannot read: the settle barrier is the wait)")
    steps += palette_run("close-tab-group", "close tab group", "tabGroup.close", waits=changed(TAB_COUNT),
                         note="closing the tab group asks nothing (an idle terminal) and shows the tab-closed toast")
    return [case(
        "dialogs-undo", script, "Closing a workspace group or a tab group asks nothing and shows an undo toast",
        steps,
        invariants=["no settled checkpoint has a dialog (/overlays/dialog/specId is null at each)",
                    "after close-group-return and close-tab-group-return the settled overlays stack holds a toast"],
        untested=["Undo of each toast: debug.toast undo has no case step and the toast's button needs a pointer (p15-oracle-350)",
                  "Forget Machine: it needs a remote machine record (remote.connect to a host off loopback)",
                  "Cmd-Q with a foreground program quits at once and a relaunch shows the terminal: no app restart "
                  "step"])]


def browser_beforeunload_close() -> List[Dict[str, Any]]:
    script = "browser-beforeunload-close-live.py"
    dialog = "/overlays/dialog/specId"
    page = "$WEB/beforeunload.html"
    steps = [new_browser("open", "chromium", page),
             key("activate", "a", typed=True,
                 note="a keydown on the page is its user activation (HTML activation-triggering input), which "
                      "Chromium requires before beforeunload may ask"),
             key("close-asks", "cmd+w", waits=wait(dialog, equals="browser.dialog.beforeunload"),
                 note="a person's Cmd-W: the tab stays and a cmux dialog asks in it"),
             key("close-again", "cmd+w", note="a second Cmd-W keeps the tab and the one question"),
             key("cancel", "escape", no_turn=DIALOG_KEY_NO_TURN, waits=wait(dialog, equals=None),
                 note="Cancel: the tab stays and answers"),
             key("close-leave", "cmd+w", waits=wait(dialog, equals="browser.dialog.beforeunload")),
             key("leave", "return", no_turn=DIALOG_KEY_NO_TURN, waits=changed(TAB_COUNT),
                 note="Leave: the tab closes and no question is left"),
             new_browser("reopen", "chromium", page),
             key("rearm", "a", typed=True),
             act("script-close", "closeTab", waits=changed(TAB_COUNT),
                 note="an automation close of an armed page closes it with no question")]
    return [case(
        "browser-beforeunload-close", script,
        "A person's close of a Chromium tab runs the page's beforeunload first; an automation close does not",
        steps, engine="chromium", web=True, priority="P0",
        invariants=["while the question shows the tab is listed and selected, and the overlays stack has one dialog",
                    "after cancel the tab is listed, loaded, and the app answers its socket (no hang)",
                    "after leave and after script-close no dialog is left"],
        untested=["Chromium's own app-modal Leave site? alert never shows: no facet lists Chromium's windows",
                  "the page answers browser.page.eval after Cancel: a page read makes the tab agent-driven, which "
                  "changes what the next close does"])]


def reopen_closed_history(engine: str) -> Dict[str, Any]:
    script = "reopen-closed-history-live.py"
    url = f"{FIRST_TAB}/url"
    steps = [new_browser("open", engine, "$WEB/load.html"),
             cli("go-other", "browser", "page", "navigate", "$WEB/other.html",
                 waits=wait(url, equals="$WEB/other.html", ms=LOAD_MS), note="the tab goes on from A to B"),
             key("close", "cmd+w", waits=changed(TAB_COUNT), note="the person closes it"),
             key("reopen", "cmd+shift+t", waits=wait(url, equals="$WEB/other.html", ms=LOAD_MS),
                 note="Reopen Last Closed Tab brings it back at B"),
             key("back", "cmd+[", waits=wait(url, equals="$WEB/load.html", ms=LOAD_MS), note="Back goes to A"),
             snapshot("after-back", "tabs", "history")]
    return case(
        f"reopen-closed-history-{engine}", script,
        f"Reopen Closed Tab keeps a {engine} tab's Back history in the session", steps, engine=ENGINE_OF[engine],
        web=True,
        invariants=["after reopen the tab can go back; after back it cannot (the app's in-memory history and the "
                    "daemon's copy are not stacked: no Back entry twice)"],
        untested=["the same across a quit and relaunch: driver_app.py has no app restart step (p15-oracle-351)",
                  "the page's own report of what it shows: the script's server counts each document's path"])


def print_page(engine: str) -> Dict[str, Any]:
    script = "print-live.py"
    steps = [new_browser("open", engine, "$WEB/load.html")]
    if engine == "webkit":
        steps += [act("print", "browserPrint", waits=wait("/focus/windows/0/hasSheet", equals=True),
                      note="the system print panel opens as a sheet on the tab's window"),
                  key("cancel", "escape", no_turn=SHEET_KEY_NO_TURN,
                      waits=wait("/focus/windows/0/hasSheet", equals=False))]
        invariants = ["while the panel shows the tab's window has a sheet and the tab is unchanged"]
        untested = ["the page's own window.print() and its script going on after Escape: no step runs page script "
                    "without making the tab agent-driven"]
    else:
        steps += [act("print", "browserPrint", note="Chromium's print preview opens over the page"),
                  key("close-tab", "cmd+w", waits=changed(TAB_COUNT), note="closing the tab closes the preview")]
        invariants = ["after close-tab no window of the app is left over the main window"]
        untested = ["the preview window itself (a Chromium dialog window attached to the page window): no facet "
                    "lists Chromium's windows"]
    return case(f"print-{engine}", script, f"Print… of a {engine} page opens its print UI and nothing is printed",
                steps, engine=ENGINE_OF[engine], web=True, invariants=invariants, untested=untested)


def error_pages(engine: str) -> Dict[str, Any]:
    script = "error-pages-live.py"
    steps = [new_browser("refused", engine, "http://127.0.0.1:9/", load="failed"),
             snapshot("error-page", "tabs", "overlays")]
    owner = "Chromium's own net error page" if engine == "chromium" else "cmux's error page"
    return case(
        f"error-pages-{engine}", script, f"A refused connection in a {engine} tab shows {owner}", steps,
        engine=ENGINE_OF[engine],
        invariants=[f"the tab's load ends failed and stays in the tab with {owner}; no dialog or window opens"],
        untested=["a host that does not resolve and an expired certificate on a public host: they need DNS and a host off "
                  "loopback",
                  "a self-signed https server's certificate interstitial: the web fixture serves http only (p15-oracle-352)",
                  "which page the pane shows over the page (debug.browser.page_status), sampled every 0.1 s"])


def bookmark_bubble() -> List[Dict[str, Any]]:
    script = "bookmark-bubble-live.py"
    steps = [new_browser("open", "webkit", "$WEB/load.html"),
             act("star", "bookmark.addPage", waits=changed("/overlays/stack"),
                 note="Bookmark This Page opens the bubble on the shared native popup host"),
             act("star-again", "bookmark.addPage", waits=changed("/overlays/stack"),
                 note="the star toggles the bubble closed; the page stays bookmarked"),
             act("star-third", "bookmark.addPage", waits=changed("/overlays/stack"), note="it opens again")]
    return [case(
        "bookmark-bubble", script, "The bookmark bubble opens and closes from the star on the native popup host",
        steps, engine="webkit", web=True,
        invariants=["after star and star-third the overlays stack's top is one popover of the browser window; after "
                    "star-again it is gone",
                    "no settled checkpoint lists a second window for the bubble"],
        untested=["the card's frame under the star and inside the window (debug.window_list)",
                  "a click outside closes it: no pointer step (p15-oracle-350)",
                  "a star pressed before the page has a title, Page Info on the same host"])]


CONVERSIONS: Dict[str, Callable[[], List[Dict[str, Any]]]] = {
    "bookmark-bubble-live.py": bookmark_bubble,
    "browser-beforeunload-close-live.py": browser_beforeunload_close,
    "close-all-workspaces-live.py": close_all_workspaces,
    "close-toast-live.py": close_toast,
    "dialogs-undo-live.py": dialogs_undo,
    "error-pages-live.py": lambda: [error_pages("chromium"), error_pages("webkit")],
    "print-live.py": lambda: [print_page("chromium"), print_page("webkit")],
    "reopen-closed-history-live.py": lambda: [reopen_closed_history("chromium"), reopen_closed_history("webkit")],
    "shortcut-hint-digits-live.py": shortcut_hint_digits,
    "sidebar-density-live.py": sidebar_density,
    "sidebar-group-menu-live.py": sidebar_group_menu,
    "window-style-preview-live.py": window_style_preview,
}

OSC7501 = ("OSC 7501 program status records are in no snapshot-v1 facet the app can wait on (a sidebar row carries "
           "only needsYou, and waitFor cannot read the daemon facet), so every checkpoint would race the shell")
NO_REMOTE_URL = ("case-v1's noRemoteUrl rule refuses every scheme://host off loopback in a case, so a case "
                 "cannot name {urls} (only Chromium's debug URLs such as chrome://crash pass)")
CHIEF = "a real Chief brain and its scratch home"
# The task that closes each gap (WORK.tsv, p15-oracle.md "Follow-ups of 225"): p15-oracle.md rule 6 gives every
# excluded script a reason and a task id. A script another suite covers names that suite's task.
POINTER_TASK = "p15-oracle-350"  # a case-v1 pointer step through debug.mouse, and a menu facet
RESTART_TASK = "p15-oracle-351"  # driver_app.py restarts the app (case-v1 restart, process app)
WEB_FIXTURE_TASK = "p15-oracle-352"  # webfixture.py: a self-signed https origin, basic auth, an inline PDF
OUTSIDE_TASK = "p15-oracle-353"  # real services, host state, evidence: a loopback stand-in or a written retirement
CHIEF_TASK = "p15-oracle-354"  # driver_app.py runs the app's Chief over mock_chief.py
LAUNCH_TASK = "p15-oracle-355"  # case-v1 fixture.launch: a per-case app environment and config
FACET_TASK = "p15-oracle-356"  # snapshot-v1 facets for what the scripts read through debug.* methods
SCHEMA_TASK = "p15-oracle-357"  # case-v1 noRemoteUrl takes chrome:// and cmux:// pages
PERF_TASK = "p12-perf-process-220"  # the orphan bench queue: every perf-like script is a lab story or retired
TASK_ID = re.compile(r"^p\d{2}-[a-z-]+-\d{3}[a-z]?$")
WORK = REPO / "plans" / "cmux-next" / "chrome-parity" / "WORK.tsv"

EXCLUSIONS: Dict[str, Tuple[str, str, str]] = {
    "adblock-first-tab-live.py": ("network", OUTSIDE_TASK, "needs a fork build with cmux_ext_load_command_line_async, uBlock "
                                  "Origin's filter lists and its blocked ad requests (ext-mv2-live.py's job)"),
    "agent-cursor-visibility-live.py": ("no-facet", FACET_TASK, "the agent cursor's visibility is debug.agent_cursor only; it "
                                        "also minimizes a window and needs a manual Space switch"),
    "agent-pane-live.py": ("launch", LAUNCH_TASK, "downloads a fleet job's build and starts it with its own ACPMUX_HOME and five "
                           "pooled harnesses; its checks are the page's transport and token (no facet)"),
    "agent-pane-menu-live.py": ("pointer", POINTER_TASK, "right-clicks down the transcript with cua-driver and reads the menu from "
                                "the window's accessibility tree"),
    "automation-notifications-quiet-live.py": ("host", OUTSIDE_TASK, "checks usernoted's app table and the bundle's Dock tile "
                                               "plug-in, outside the app"),
    "bookmarks-import-live.py": ("launch", LAUNCH_TASK, "needs synthetic browser profiles under CMUX_NEXT_BROWSER_IMPORT_HOME, "
                                 "which the bench launch does not set, and the picker dialog's checkboxes"),
    "bookmarks-incognito-omnibar-live.py": ("no-facet", FACET_TASK, "its checks are the omnibar's suggestion rows, which no "
                                            "snapshot-v1 facet holds"),
    "browser-challenges-live.py": ("network", WEB_FIXTURE_TASK, "needs an HTTPS server with a self-signed certificate and an HTTP "
                                   "basic-auth server; the web fixture serves plain http only, and the second half "
                                   "is a relaunch"),
    "browser-idle-cost-live.py": ("perf", PERF_TASK, "measures CPU seconds, idle wakeups, bytes written and footprint per "
                                  "Chromium process class over idle minutes"),
    "browser-import-offer-live.py": ("network", OUTSIDE_TASK, "loads https://example.com and needs CMUX_NEXT_BROWSER_IMPORT_OFFER=1 "
                                     "in the launch"),
    "browser-post-replay-live.py": ("relaunch", RESTART_TASK, "needs a form server that counts POSTs per form, and two of its four "
                                    "cases (reopen after quit, relaunch) restart the app"),
    "browser-profile-move-live.py": ("no-facet", FACET_TASK, "its checks are a page's cookie, localStorage, sessionStorage and "
                                     "IndexedDB values, read only through the page"),
    "browser-restore-live.py": ("relaunch", RESTART_TASK, "every check is after a quit and relaunch (Back and scroll restored)"),
    "browser-toolbar-default-live.py": ("no-facet", FACET_TASK, "the toolbar's buttons are debug.extensions.toolbar only"),
    "browser-use-scenarios-live.py": ("no-facet", FACET_TASK, "drives the browser-use site with an agent cursor and checks "
                                      "debug.agent_cursor and window captures"),
    "build-files-live.py": ("launch", LAUNCH_TASK, "runs a copied bundle with another LSEnvironment tag and checks App Support "
                            "folders on disk"),
    "cef-native-ui-live.py": ("pointer", POINTER_TASK, "drives Chromium's native widgets with real HID clicks and keys "
                              "(CGEventPost)"),
    "chat-transfer-live.py": ("launch", LAUNCH_TASK, "needs two builds running at once, each with its own acpmux home and the "
                              "fake ACP agent"),
    "chief-adoption-live.py": ("launch", LAUNCH_TASK, "runs the app as NIGHTLY's Chief build (CMUX_NEXT_CHIEF_BUILD_ID) over a "
                               "seeded Chief root and checks its backup folders"),
    "chief-brain-restart-live.py": ("model", CHIEF_TASK, f"needs {CHIEF} and a Claude login for the reply"),
    "chief-cache-live.py": ("model", OUTSIDE_TASK, "reads the real model's prompt-cache numbers through the subrouter"),
    "chief-first-send-live.py": ("model", CHIEF_TASK, f"needs {CHIEF}; it measures the first Home send over 20 fresh rounds"),
    "chief-home-fixes-live.py": ("model", CHIEF_TASK, f"needs {CHIEF}, `cmux chief shutdown` and a new brain's lock"),
    "chief-per-build-live.py": ("model", CHIEF_TASK, f"needs {CHIEF} per build identity, a copied bundle and a Claude login"),
    "chief-prompt-bubble-live.py": ("model", CHIEF_TASK, "needs the app's acpmux with the fake ACP agent and a 140 KB Chief "
                                    "prompt sent over acpmux"),
    "chief-subagents-live.py": ("model", CHIEF_TASK, f"needs {CHIEF}, its tools socket and real subagent runs"),
    "chrome-internal-pages-live.py": ("schema", SCHEMA_TASK, NO_REMOTE_URL.format(urls="chrome://extensions, chrome://version or "
                                                                  "chrome://flags") + "; the schema owner (p15-oracle-012) "
                                      "decides whether Chromium's internal pages join the local list"),
    "chrome-promos-live.py": ("launch", LAUNCH_TASK, "needs disable-user-education-rate-limiting through "
                              "CMUX_NEXT_CEF_EXTRA_SWITCHES and counts Chromium's help-bubble windows, which no facet "
                              "lists"),
    "chromium-popups-live.py": ("pointer", POINTER_TASK, "clicks Chromium's popup widgets at screen positions through cua-driver"),
    "chromium-tab-count-live.py": ("perf", PERF_TASK, "measures the soft open-file limit, open descriptors, threads and memory "
                                   "over a hundred Chromium tabs"),
    "classic-to-next-live.py": ("launch", LAUNCH_TASK, "seeds classic cmux data and a classic build, and runs classic-to-next.py "
                                "against them"),
    "clickthrough-live.py": ("pointer", POINTER_TASK, "clicks chips and menu rows in the agent page (debug.agent_pane click) and "
                             "watches its layout; it also relaunches"),
    "clipboard-read-live-check.py": ("launch", LAUNCH_TASK, "needs a Ghostty config with clipboard-read = ask and a marker on the "
                                     "host pasteboard (pbcopy)"),
    "column-resize-live.py": ("perf", PERF_TASK, "records every display frame while a column edge is dragged (debug.mouse)"),
    "cua-helper-v2-live.py": ("launch", LAUNCH_TASK, "needs Computer Use on with the upstream driver and a scripted ACP harness "
                              "in its own ACPMUX_HOME"),
    "devtools-device-mode-live.py": ("network", OUTSIDE_TASK, "compares a cmux tab with Google Chrome through CDP on a remote "
                                     "debugging port"),
    "devtools-resize-live.py": ("pointer", POINTER_TASK, "drags the docked DevTools divider with cua-driver or debug.mouse"),
    "divider-drag-reflow-live.py": ("perf", PERF_TASK, "records frames and display-link intervals while a divider is dragged"),
    "downloads-live.py": ("no-facet", FACET_TASK, "the Downloads list and its Pause, Resume and Retry are debug.downloads only"),
    "downloads-relaunch-live.py": ("relaunch", RESTART_TASK, "its checks are the Downloads list after a quit and relaunch"),
    "drag-lag-live.py": ("perf", PERF_TASK, "measures each debug.mouse move's reply time during drags"),
    "evicted-terminal-frame-live.py": ("no-facet", FACET_TASK, "the held last frame of an evicted terminal is debug.surfaces "
                                       "only, sampled as fast as the socket answers"),
    "ext-mv2-live.py": ("network", OUTSIDE_TASK, "installs from the Chrome Web Store and loads unpacked uBlock Origin"),
    "extensions-menu-live.py": ("evidence", OUTSIDE_TASK, "writes captures of the Extensions bubble with extensions loaded through "
                                "CMUX_NEXT_CEF_LOAD_EXTENSIONS"),
    "external-schemes-live.py": ("launch", LAUNCH_TASK, "needs the recording build env CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS, or a "
                                 "link would open another app on the host, and a user-gesture click in the page"),
    "group-editor-live.py": ("pointer", POINTER_TASK, "opens the group editor with real right-clicks and types into it through "
                             "cua-driver"),
    "hands-client-live.py": ("network", OUTSIDE_TASK, "signs in to the staging Cloud API with real credentials"),
    "hibernation-busy-live.py": ("launch", LAUNCH_TASK, "needs a short browser.hibernation from its own config and a click that "
                                 "starts Web Audio (debug.mouse)"),
    "home-api-live.py": ("model", CHIEF_TASK, "drives debug.home.api against the real local Chief owner"),
    "home-streaming-live.py": ("model", CHIEF_TASK, "times a real Chief reply's live draft in Home"),
    "hover-card-grid-live.py": ("no-facet", FACET_TASK, "checks glyph sizes and positions in the hover card (DebugCardGrid)"),
    "hovercard-delay-live.py": ("pointer", POINTER_TASK, "moves the pointer over rows and tabs and times the card's delay"),
    "hovercard-live.py": ("no-facet", FACET_TASK, "reads the hover card's text and its elapsed-time tick (debug.hover_cards, "
                          "debug.wakeups)"),
    "html-file-menu-live.py": ("model", CHIEF_TASK, "Send Message opens the Home chat (Chief); Open as Text needs a tab's "
                               "right-click menu"),
    "import-files-live.py": ("no-facet", FACET_TASK, "drives the import dialog and the cmux file picker through debug.toast and "
                             "debug.dialog"),
    "launch-env-fence-live.py": ("launch", LAUNCH_TASK, "starts the app with another cmux's inherited environment"),
    "layout-loop-stress-live.py": ("perf", PERF_TASK, "counts layout passes per window turn and plane sync (debug.layers) "
                                   "over a stress walk"),
    "legacy-session-adopt-live.py": ("launch", LAUNCH_TASK, "stages a copy of the app as the staging channel build over an "
                                     "old-layout daemon root"),
    "link-routing-live.py": ("launch", LAUNCH_TASK, "opens links through debug.terminal.links; without the recording env "
                             "CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS a system link opens Safari on the host"),
    "mac-screen-live.py": ("network", OUTSIDE_TASK, "pairs with another Mac through a cmux-vnc pair link"),
    "model-picker-focus-live.py": ("no-facet", FACET_TASK, "reads the agent page's focused element (chat_state.focus)"),
    "next-home-adopt-live.py": ("model", CHIEF_TASK, f"needs {CHIEF} and a Claude login, over a seeded pre-update layout"),
    "now-playing-live.py": ("host", OUTSIDE_TASK, "reads macOS Now Playing through MediaRemote and presses media keys"),
    "omnibar-pointer-live.py": ("pointer", POINTER_TASK, "walks the omnibar's hover and cursor states with debug.mouse"),
    "overlay-live-check.py": ("no-facet", FACET_TASK, "checks child-window order and reorder counts (debug.layers, "
                              "debug.window_list)"),
    "page-hang-live.py": ("suite", "p15-oracle-223", "journeys/chromium-renderer-hang (p15-oracle-223) covers the chrome://hang card, "
                          "with its Expectations line until the CEF DevTools fix"),
    "page-swap-visible-live.py": ("schema", SCHEMA_TASK, NO_REMOTE_URL.format(urls="cmux://bookmarks or cmux://remote-view") +
                                  "; its remote view half is debug.remote_view only"),
    "page-hover-zoom-live.py": ("no-facet", FACET_TASK, "hovers page elements through debug.page at each UI scale"),
    "palette-eval-live.py": ("evidence", OUTSIDE_TASK, "writes the palette ranker's input and query results for "
                             "webviews/scripts/palette-eval.ts"),
    "pane-toolbar-pins-live.py": ("no-facet", FACET_TASK, "the pane's tab bar buttons and their fade are debug.pane_chrome only; "
                                  "the first check needs a retired key in its own config file"),
    "passkeys-k16-live.py": ("suite", "p15-oracle-095", "runs passkeys-matrix-e2e.py --k16, which the e2e suite (p15-oracle-092..097) "
                             "converts or excludes"),
    "password-autofill-live.py": ("no-facet", FACET_TASK, "the page reports its own form state to the script's server; a page "
                                  "read through the socket turns filling off"),
    "pdf-live.py": ("host", WEB_FIXTURE_TASK, "needs an inline PDF route the web fixture does not serve and checks ~/Downloads for "
                    "a file that must not land"),
    "permission-prompts-live.py": ("no-facet", FACET_TASK, "the prompt bar and its Block and Allow are in no snapshot-v1 facet"),
    "phone-simulator-live.py": ("host", OUTSIDE_TASK, "boots an iOS simulator"),
    "quit-hidden-chromium-live.py": ("relaunch", RESTART_TASK, "its check is a clean exit of the app (no CEF FATAL, no SIGABRT); "
                                     "driver_app.py has no step that quits the app and reads its exit"),
    "remote-browser-local-live.py": ("launch", LAUNCH_TASK, "needs the remote browser host app (CMUX_NEXT_RB_HOST or the bundled "
                                     "helper) and reads its log"),
    "remote-view-rd-live.py": ("network", OUTSIDE_TASK, "needs a Linux cmux-rd host through an SSH tunnel and its token"),
    "remote-view-vnc-live.py": ("no-facet", FACET_TASK, "connects through debug.remote_view and checks decoded VNC frames"),
    "resize-frames-live.py": ("perf", PERF_TASK, "measures frame intervals during a live window resize"),
    "sidebar-doc-live.py": ("suite", "p15-oracle-062", "drives the daemon's sidebar verbs and a migration from an older registry: the "
                            "daemon-ops suite's sidebar.* cases and the upgrades suite (p15-oracle-208)"),
    "sidebar-instant-rows-live.py": ("perf", PERF_TASK, "samples row frames and opacity per display frame (debug.sidebar_rows "
                                     "motion)"),
    "sidebar-rows-perf-live.py": ("perf", PERF_TASK, "measures CPU time per tick and main-thread reply delay over 1,000 rows"),
    "sidebar-status-glyph-live.py": ("no-facet", FACET_TASK, "checks glyph crispness, size, line and spin phase "
                                     "(debug.sidebar_rows status_glyphs)"),
    "sidebar-status-matrix-live.py": ("no-facet", FACET_TASK, f"{OSC7501}; the rings and marks it checks are status_glyphs"),
    "sidebar-tui-doc-live.py": ("suite", "p15-oracle-234", "drives a real `cmux attach` TUI in tmux: the tui suite (p15-oracle-234)"),
    "sidebar-v2-drag-live.py": ("pointer", POINTER_TASK, "every drag goes through debug.mouse lift, moves and drop"),
    "status-indicators-live.py": ("launch", LAUNCH_TASK, "presets icon sets through CMUX_NEXT_DEBUG_TUNABLES_FILE and runs a "
                                  "fake ACP harness; its checks are banner attachments"),
    "terminal-cmd-click-live.py": ("pointer", POINTER_TASK, "moves the pointer and clicks through debug.terminal.links"),
    "terminal-path-links-live.py": ("launch", LAUNCH_TASK, "activates links through debug.terminal.links in a recording build "
                                    "(CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS)"),
    "terminal-program-status-conformance-live.py": ("no-facet", FACET_TASK, OSC7501),
    "terminal-program-status-live.py": ("no-facet", FACET_TASK, OSC7501),
    "tips-mute-live.py": ("no-facet", FACET_TASK, "moves the tips' clock through debug.updater tips `at` and reads the card's "
                          "menu through debug.hints"),
    "titlebar-double-click-live.py": ("pointer", POINTER_TASK, "double-clicks the titlebar with debug.mouse, with "
                                      "AppleActionOnDoubleClick in the launch's argument domain"),
    "update-card-close-live.py": ("relaunch", RESTART_TASK, "forces update states through debug.updater, clicks through hint mode "
                                  "and checks the hide after a relaunch"),
    "updated-card-close-live.py": ("relaunch", RESTART_TASK, "shows the card through debug.updater, clicks its x with debug.mouse "
                                   "and checks it after a relaunch"),
}


# ------------------------------------------------------------------------------------------------- generation


def inventory(scripts_dir: Path = SCRIPTS) -> List[str]:
    return sorted(p.name for p in scripts_dir.iterdir() if p.is_file() and INVENTORY.search(p.name))


def batch_of(index: int, total: int) -> int:
    return index * BATCHES // max(total, 1) + 1


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def work_tasks(path: Path = WORK) -> frozenset:
    """The task ids of WORK.tsv (its first column)."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()[1:]
    except OSError as error:
        raise GenError(f"{path}: {error}") from None
    return frozenset(line.split("\t", 1)[0] for line in lines if line)


def exclusion_problems(exclusions: Mapping[str, Tuple[str, str, str]], tasks: frozenset) -> List[str]:
    """p15-oracle.md rule 6: an excluded script has a known kind, a written reason and the id of a WORK.tsv task
    (not this one) that closes the gap or covers the script."""
    problems = []
    for name, entry in sorted(exclusions.items()):
        if not (isinstance(entry, tuple) and len(entry) == 3):
            problems.append(f"{name}: an exclusion is (kind, task, reason)")
            continue
        kind, task, reason = entry
        if kind not in EXCLUSION_KINDS:
            problems.append(f"{name}: unknown exclusion kind {kind!r}")
        if not (isinstance(task, str) and TASK_ID.match(task)):
            problems.append(f"{name}: an exclusion needs the id of the task that closes it, not {task!r}")
        elif task == TASK:
            problems.append(f"{name}: an exclusion names {TASK} itself, which closes nothing")
        elif task not in tasks:
            problems.append(f"{name}: {task} is not a task of WORK.tsv")
        if not isinstance(reason, str) or len(reason.strip()) < 20:
            problems.append(f"{name}: an exclusion needs a reason")
    return problems


def generate(names: Sequence[str], tasks: Optional[frozenset] = None) -> Tuple[Dict[str, Any], Dict[str, Any], List[str]]:
    """(case files by name, live-map.json, problems). `tasks`: WORK.tsv's task ids (read when None)."""
    problems: List[str] = []
    both = sorted(set(CONVERSIONS) & set(EXCLUSIONS))
    problems += [f"{name}: both converted and excluded" for name in both]
    listed = set(CONVERSIONS) | set(EXCLUSIONS)
    problems += [f"{name}: a live script in neither CONVERSIONS nor EXCLUSIONS" for name in names if name not in listed]
    problems += [f"{name}: in a table but not a live script of scripts/cmux-next" for name in sorted(listed - set(names))]
    problems += exclusion_problems(EXCLUSIONS, work_tasks() if tasks is None else tasks)
    files: Dict[str, Any] = {}
    scripts: Dict[str, Any] = {}
    for index, name in enumerate(names):
        entry: Dict[str, Any] = {"batch": batch_of(index, len(names))}
        if name in CONVERSIONS:
            built = CONVERSIONS[name]()
            entry["status"] = "converted"
            entry["cases"] = [f"{SUITE}/{c['id']}" for c in built]
            entry["untested"] = sorted({u for c in built for u in c.get("untested", ())})
            for built_case in built:
                file = f"{built_case['id']}.json"
                if file in files:
                    problems.append(f"{name}: case {built_case['id']} is also another script's")
                files[file] = built_case
        elif name in EXCLUSIONS:
            kind, task, reason = EXCLUSIONS[name] if len(EXCLUSIONS[name]) == 3 else ("", "", "")
            entry.update(status="excluded", kind=kind, task=task,
                         reason=f"{reason}: {EXCLUSION_KINDS.get(kind, kind)} ({task})")
        scripts[name] = entry
    converted = sorted(n for n in names if n in CONVERSIONS)
    excluded = {n: scripts[n]["reason"] for n in names if n in EXCLUSIONS}
    live_map = {
        "$comment": f"Written whole by {GENERATOR} ({TASK}); do not edit, change its tables and regenerate. Every live "
                    f"script is converted (its cases, what stays untested) or excluded with a reason and the task that "
                    f"closes the gap; `batch` is the "
                    f"fleet batch (1-{BATCHES}) that runs its cases twice.",
        "generator": GENERATOR,
        "suite": SUITE,
        "inventory": INVENTORY_COMMAND,
        "total": len(names),
        "converted": len(converted),
        "excluded": len(excluded),
        "cases": len(files),
        "kinds": dict(EXCLUSION_KINDS),
        "scripts": scripts,
    }
    files[COVERAGE] = {
        "generator": GENERATOR,
        "suite": SUITE,
        "catalog": INVENTORY_COMMAND,
        "map": "scripts/cmux-next/oracle/live-map.json",
        "total": len(names),
        "covered": len(converted),
        "verdicts": "not run",
        "cases": {n: scripts[n]["cases"] for n in converted},
        "excluded": excluded,
        "missing": [n for n in names if n not in listed],
    }
    return files, live_map, problems


def owned_files(out: Path) -> List[str]:
    path = out / COVERAGE
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return []
    return sorted(case.split("/", 1)[1] + ".json" for cases in (data.get("cases") or {}).values()
                  for case in cases if isinstance(case, str))


def differences(out: Path, map_path: Path, files: Mapping[str, Any], live_map: Mapping[str, Any]) -> List[str]:
    found = []
    for name, value in sorted(files.items()):
        path = out / name
        if not path.is_file() or path.read_text(encoding="utf-8") != render(value):
            found.append(f"{path}: differs from a fresh generation")
    for name in owned_files(out):
        if name not in files and (out / name).exists():
            found.append(f"{out / name}: generated earlier, no longer converted")
    if not map_path.is_file() or map_path.read_text(encoding="utf-8") != render(live_map):
        found.append(f"{map_path}: differs from a fresh generation")
    return found


def write(out: Path, map_path: Path, files: Mapping[str, Any], live_map: Mapping[str, Any]) -> int:
    out.mkdir(parents=True, exist_ok=True)
    owned = set(owned_files(out))
    for name in files:
        if name != COVERAGE and (out / name).exists() and name not in owned:
            raise GenError(f"{out / name}: exists and was not written by this generator")
    written = 0
    for name, value in sorted(files.items()):
        path = out / name
        if not path.is_file() or path.read_text(encoding="utf-8") != render(value):
            path.write_text(render(value), encoding="utf-8")
            written += 1
    for name in sorted(owned - set(files)):
        (out / name).unlink(missing_ok=True)
    if not map_path.is_file() or map_path.read_text(encoding="utf-8") != render(live_map):
        map_path.write_text(render(live_map), encoding="utf-8")
        written += 1
    return written


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the live suite's corpus directory")
    parser.add_argument("--map", type=Path, default=DEFAULT_MAP, help="live-map.json")
    parser.add_argument("--scripts", type=Path, default=SCRIPTS, help=argparse.SUPPRESS)
    parser.add_argument("--check", action="store_true", help="exit 1 when an output differs from a fresh generation")
    parser.add_argument("--selftest", action="store_true", help="run gen_live_test.py")
    args = parser.parse_args(argv)
    if args.selftest:
        return subprocess.run([sys.executable, "-I", str(HERE / "gen_live_test.py")], check=False).returncode
    try:
        files, live_map, problems = generate(inventory(args.scripts))
    except GenError as error:
        print(f"gen_live: {error}", file=sys.stderr)
        return 2
    for problem in problems:
        print(f"gen_live: {problem}", file=sys.stderr)
    if args.check:
        found = differences(args.out, args.map, files, live_map)
        for line in found:
            print(f"gen_live: {line}", file=sys.stderr)
        return 1 if found or problems else 0
    if problems:
        return 1
    written = write(args.out, args.map, files, live_map)
    print(f"gen_live: {live_map['converted']}/{live_map['total']} scripts converted into {live_map['cases']} cases, "
          f"{live_map['excluded']} excluded with a reason and a task; {written} files written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
