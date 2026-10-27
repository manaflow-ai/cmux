#!/usr/bin/env python3
"""Generate the tours suite: one golden case per cmux-next media tour, with every timed wait made a typed wait.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3B (settle and waits), 3D (suite tours, golden, 23 media
tours) and task 091. Stdlib plus scripts/cmux-next/media/tour.py (its `load_tour` is the one tour reader), Python
3.9+, safe under `python3 -I`. `oracle.py gen --suite tours` runs it with `--out <corpus>/tours`.

Chrome reference (chromium/src): chrome/test/interaction/README.md and ui/base/interaction/interactive_test.h
(Kombucha) turn a scripted UI walk into Action, WaitForState and Check verbs, where a wait is a StateObserver on
the producer's own signal and never a timer; content/public/test/browser_test_utils.h WaitForLoadStop is the
page barrier. A tour (scripts/cmux-next/media/tours/<name>.json) is such a walk written for pictures: each step
runs one command, then sleeps `wait` seconds before its screenshot. Here each step becomes a case-v1 step whose
settled snapshot stands in for the screenshot, and the sleep becomes the step's waitFor or the settle barrier.

Step mapping (tour step -> case step):

  the first step (`Launch`)  snapshot (shot) or settle; tour `settings` become cli `settings set` setup steps
                             before it, since case-v1 has no launch config
  wait only                  snapshot (shot) or settle
  cmux ARGV                  cli ARGV on the app's socket (driver_app.py op_cli); a `daemon` verb reaches the tag's
                             daemon through the bundle's own cmux (cli/wire/socket.rs: the bundled cmux names its
                             app's session), so it needs no --session
  rpc {method, params}       cli `app call METHOD JSON` (cli/app/call.rs), the tour's own spelling for a method with
                             no verb (update-card.json)
  wait SECONDS               waitFor on the end state the command reaches (WAITS, below), else the settle barrier
                             alone; a wait of WIDE_WAIT_S or more widens the bounds to WIDE_MS
  optional REASON            tour.py reports a failing optional step as `unavailable`, but a case step expects one
                             outcome. An optional step is kept only when OPTIONAL_KNOWN proves from the bench build's
                             code that it answers ok in its own turn; every other one is dropped with its reason.
                             `cmux agent new-chat` is no CLI verb (cmux-tui cli/command.rs parse_agent falls through
                             to agent_focus, a usage error), so its steps and the steps that act on its chat drop too
  shot, display, windows     dropped: every step records its settled snapshot, and pictures are tour.py's job

The waits a command gets, each on the step's own end state (`changed` compares with the value read before the step,
driver_app.py wait_baseline):

  workspace new              /terminals/list/N/attach equals attached, N the new workspace's terminal in the facet's
                             order (OracleTerminalsFacet+Mirror.swift: workspaces, screens, panes, tabs); TourState
                             counts the terminals from the launch's one workspace with one terminal (bench_launch
                             start_fresh gives an empty saved session, and app_reset brings each case back to it)
  terminal write             /topology/topology/workspaces/W/screens/0/panes/0/tabs/0/title equals the step's own
                             title. The written text starts with `clear`, ends by setting the terminal title (OSC 2;
                             the tab title is TabModel.displayTitle) and holds the shell in `cat >/dev/null`, so the
                             title is the last thing the command does and no prompt is drawn after it: the settled
                             screen is the command's output alone. A later write to that terminal starts with ^D to
                             end the hold. OSC 7501 program status reaches no facet (TabModel.programStatus; the tab's
                             agent_state is the agent record's), so core's agent steps wait on their titles too
  split, new terminal tab    /topology/topology/workspaces (split, close pane, pin) or /topology/tab_count
  next tab                   /topology/topology/focus/tab
  sidebar toggle, palette    /sidebar/hidden, /overlays/palette/open
  settings set or unset      /settings/effectiveSha256, only when the step changes the document (the generator
                             tracks it from the tour's settings and steps)
  appStore.show              /webviews/pages: the App Store is a cmux page (AppStoreHandlers.swift showStore), and a
                             page joins the facet once it answers cmux.page.oracle.state (OracleWebviewsFacet.swift)
  workspace.showResources    /overlays/hoverCard/target: SidebarListView+HoverCard.swift showHoverCard pins the card
                             in the action's turn and the action refuses unless it shows
  a hover on a new rail mark /overlays/hoverCard/target
  a new browser tab          /tabs/panes/0/tabs/0/loadState equals finished (the tour's first browser or page tab:
                             the facet lists only panes with one)

The settle barrier alone ends a step whose effect is done when its control call answers: debug.appearance,
debug.updater and debug.hover_cards answer in their main-actor turn (HoverCardGallery.swift shows the gallery's child
window inside `show`, and a bench build, with no DEBUG, registers no gallery set and shows nothing).

Rewrites (TEXT_REWRITES, URL_REWRITES, REWRITES, DROPPED): a remote URL becomes a page of the loopback web fixture
($WEB, fixture.web); text a terminal runs never sleeps (a shell `sleep` that holds a state becomes the hold, and core's
timed agent run waits on a line from `head -n 1` that a later step writes); host-dependent output (uname,
/System/Applications) becomes fixed text; a step that needs a method only a DEBUG build registers
(DEBUG_ONLY_METHODS) is dropped with its reason, as is a step that only makes sense after a dropped one. driver_app.py
has no loopback web fixture yet (it fails a fixture.web case as a Crash), so while DRIVER_WEB_FIXTURE is False a step
that opens a $WEB page is dropped with that reason; the selftest fails once driver_app serves it. A tour that needs
launch features is EXCLUDED: case-v1 has no launch-feature field and driver_app launches every feature at its
default. Every rewrite, drop and exclusion is in coverage.json, and each drop is in the case's `untested`.

Usage:
  gen_tours.py [--out DIR] [--tours DIR]           write the cases and coverage.json into DIR
  gen_tours.py [--out DIR] [--tours DIR] --check   exit 1 when DIR differs from a fresh generation
  gen_tours.py --selftest                          offline tests
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MEDIA = HERE.parent / "media"
for _path in (str(HERE), str(MEDIA)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import tour  # noqa: E402  (scripts/cmux-next/media/tour.py: load_tour, slug, STEP_KEYS)

GENERATOR = "scripts/cmux-next/oracle/gen_tours.py"
SUITE = "tours"
TASK = "p15-oracle-091"
TOURS_DIR = MEDIA / "tours"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / SUITE
COVERAGE = "coverage.json"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
VIEWPORT = {"width": 1440, "height": 900}

# Waits. EXPECT_WAIT_MS is gen_actions.py's; a tour step that waited WIDE_WAIT_S or more (a page load, an agent
# start) gets WIDE_MS for its waitFor and its settle barrier.
WAIT_MS = 5000
WIDE_WAIT_S = 3
WIDE_MS = 10000

WORKSPACES = "/topology/topology/workspaces"
TAB_COUNT = "/topology/tab_count"
FOCUS_TAB = "/topology/topology/focus/tab"
SIDEBAR_HIDDEN = "/sidebar/hidden"
PALETTE_OPEN = "/overlays/palette/open"
SETTINGS_HASH = "/settings/effectiveSha256"
HOVER_TARGET = "/overlays/hoverCard/target"
WEBVIEW_PAGES = "/webviews/pages"
FIRST_PAGE_LOAD = "/tabs/panes/0/tabs/0/loadState"
LOAD_FINISHED = "finished"
ATTACHED = "attached"


def terminal_attach(index: int) -> str:
    """The attach state of the terminals facet's INDEX-th terminal (OracleTerminalsFacet+Mirror.swift order)."""
    return f"/terminals/list/{index}/attach"


def single_tab_title(workspace: int) -> str:
    """The title of the only tab of a workspace's only pane (ControlTopology+JSON.swift: TabModel.displayTitle)."""
    return f"{WORKSPACES}/{workspace}/screens/0/panes/0/tabs/0/title"


# `cmux action run NAME`: the value NAME is sure to change. An action missing here (a directional focus that may have
# no neighbor, a menu) gets the settle barrier alone.
ACTION_WAITS = {
    "splitRight": WORKSPACES,
    "splitDown": WORKSPACES,
    "closePane": WORKSPACES,
    "palette.toggleTabPin": WORKSPACES,
    "newSurface": TAB_COUNT,
    "closeOtherTabsInPane": TAB_COUNT,
    "nextSurface": FOCUS_TAB,
    "toggleSidebar": SIDEBAR_HIDDEN,
    "commandPalette": PALETTE_OPEN,
    "appStore.show": WEBVIEW_PAGES,
    "workspace.showResources": HOVER_TARGET,
}
# Actions that add a terminal to the current workspace, and actions after which the generator no longer knows its
# terminal count (the tabs a close keeps depend on the pins).
ADDS_TERMINAL = {"splitRight", "splitDown", "newSurface"}
FORGETS_TERMINALS = {"closePane", "closeOtherTabsInPane"}
# `cmux tab VERB`: new tabs.
TAB_VERBS = {"new-page": TAB_COUNT}

# App control methods only a DEBUG build registers (`#if DEBUG` in CmuxNextApp): the oracle runs the bench build.
DEBUG_ONLY_METHODS = {
    "debug.terminal.links": "CmuxNextApp/DebugTerminalLinks.swift registers it in DEBUG builds only",
    "debug.update_surfaces": "CmuxNextApp/Control/AppControl+Updates.swift registers it in DEBUG builds only",
}

# Optional tour steps whose ok answer the bench build's code proves (argv prefix -> evidence). Any other optional
# step is dropped: its outcome on the bench build is not known, and a case step expects exactly one.
OPTIONAL_KNOWN = {
    ("app", "call", "debug.appearance"): (
        "CmuxNextApp/InputVerification/AppControl+Input.swift registers debug.appearance in DEBUG || "
        "CMUX_BENCH_HOOKS builds and answers in its main-actor turn, so the bench build runs it"),
    ("app", "call", "debug.home.sidebar_fixture"): (
        "CmuxNextApp/InputVerification/AppControl+Input.swift registers it in DEBUG || CMUX_BENCH_HOOKS builds, and "
        "DebugHomeSidebarFixture.handle answers a value (an error member when no Home page shows), so the cli exits 0"),
    ("settings", "set", "sidebar.sessionTree"): (
        "schemas/settings/settings-schema.json has sidebar.sessionTree, so the bench build's settings set takes it"),
}
NO_AGENT_CHAT = ("`cmux agent new-chat` is no CLI verb (cmux-tui cli/command.rs parse_agent sends it to agent_focus, "
                 "a usage error), so the step fails on every build")
OPTIONAL_UNKNOWN = ("tour.py optional ({reason}): its outcome on the bench build is not known, and a case step expects "
                    "one outcome")
OPTIONAL_KEPT = "tour.py optional ({reason}), kept: {evidence}"

# Steps that only make sense after a dropped step: (tour, 1-based step number) -> why. A number, not a title:
# main-pane has two steps titled "Focus the chat", and only the second goes.
DEPENDS_ON_LINKS = "it acts on the column a dropped debug.terminal.links step opens"
DEPENDS_ON_CHAT = "it acts on the chat column the dropped agent new-chat step opens"
DROPPED = {
    ("main-pane", 4): DEPENDS_ON_CHAT,
    ("main-pane", 6): DEPENDS_ON_CHAT,
    ("main-pane", 8): DEPENDS_ON_LINKS,
    ("main-pane", 10): DEPENDS_ON_LINKS,
    ("main-pane", 11): "it only sets up the dropped debug.terminal.links step after it",
    ("main-pane", 12): "it only sets up the dropped debug.terminal.links step after it",
}

# Tours no case can run yet: name -> why.
EXCLUDED = {
    "host-pressure": (
        "the tour launches with the feature hostPressure on (schemas/features/features.d/hostPressure.json ships "
        "off), and case-v1 has no launch-feature field: driver_app.py launches every feature at its default, so each "
        "step would record the feature-off app as the golden host-pressure tour"),
}

# driver_app.py fails a fixture.web case as a Crash; while this is False, a step that opens a $WEB page is dropped.
# The selftest fails once driver_app serves webfixture.py, to turn the steps back on.
DRIVER_WEB_FIXTURE = False
DRIVER_APP = HERE / "driver_app.py"
DRIVER_NO_WEB = "driver_app has no loopback web fixture yet (fixture.web)"
NO_WEB = ("driver_app.py fails a fixture.web case as a Crash (no loopback web fixture yet), so a step that opens a "
          "$WEB page waits until driver_app serves webfixture.py")
# Kept steps whose meaning changes when the web steps drop: (tour, number) -> note.
NO_WEB_NOTES = {
    ("pinned-tabs", 6): "the browser tab step is dropped (no web fixture in driver_app), so this pins the selected "
                        "terminal tab",
}

# Remote URLs -> a page of the loopback web fixture (scripts/cmux-next/oracle/webfixture.py).
URL_REWRITES = {
    "https://example.com": "$WEB/load.html",
    "https://example.org": "$WEB/other.html",
    "https://example.net": "$WEB/index.html",
}
URL = re.compile(r"\b(?:https?|wss?|ftp)://[^\s'\"]+")

# Terminal writes: each ends by setting its title and holding the shell, and the step waits on that title.
HOLD = "cat >/dev/null"
EOT = "\x04"
CLEAR = "clear"


def title_printf(title: str) -> str:
    """The shell text that sets the terminal title (OSC 2) to `title`."""
    return f"printf '\\033]2;%s\\007' '{title}'"


def write_title(tour_name: str, number: int) -> str:
    """The title a write step sets last and waits on."""
    return f"tours {tour_name} {number:02d}"


class TextRewrite:
    """A tour's terminal text replaced. `title` None: the generic wrap adds the step's title and the hold to `text`.
    `title` set: `text` is final and sets that title; `release`: it answers a read the terminal already holds, so it
    gets no ^D first."""

    def __init__(self, text: str, why: str, title: Optional[str] = None, release: bool = False) -> None:
        self.text, self.why, self.title, self.release = text, why, title, release


HOST_OUTPUT = ("host output (uname, the macOS app list) differs by host and OS; a golden baseline needs fixed text")
AGENT_RUN = ("clear; printf '\\033]7501;state=working\\033\\\\'; sleep 8; printf '\\033]7501;state=done\\033\\\\'; "
             "sleep 900\r")
AGENT_WORKING, AGENT_DONE = "tours core 15", "tours core 17"
TEXT_REWRITES = {
    "clear; printf '\\033]9;4;3\\007'; sleep 900\r": TextRewrite(
        "clear; printf '\\033]9;4;3\\007'\r",
        "the shell holds the progress state by reading stdin, not by a timed wait"),
    AGENT_RUN: TextRewrite(
        "clear; printf '\\033]7501;state=working\\033\\\\'; " + title_printf(AGENT_WORKING) + "; head -n 1 >/dev/null; "
        "printf '\\033]7501;state=done\\033\\\\'; " + title_printf(AGENT_DONE) + f"; {HOLD}\r",
        "the agent state holds until a later step writes a line, not for 8 timed seconds; each state then sets its "
        "title, and the shell reads stdin",
        title=AGENT_WORKING),
    "done\r": TextRewrite(
        "done\r", "the line ends the agent run's head; the done state and its title follow it",
        title=AGENT_DONE, release=True),
    "clear; uname -sm; echo; ls /System/Applications | head -12\r": TextRewrite(
        "clear; printf '%s\\n' 'cmux launch clip' infra docs-site app\r", HOST_OUTPUT),
}
SETTLED_WRITE = ("the screen is the command's output alone: it starts with clear, sets its title last and holds the "
                 "shell, so no prompt races the snapshot; the step waits on that title")
SLEEP = re.compile(r"\bsleep\b")

# Tour steps replaced by another tour step: (tour, title) -> (step, why).
REWRITES = {
    ("core", "The agent finishes: done mark in the spinner's place"): (
        {"title": "The agent finishes: done mark in the spinner's place", "daemon": True,
         "cmux": ["workspace", "name:Agent", "screen", "current", "pane", "current", "tab", "current", "terminal",
                  "current", "write", "--text", "done\r"]},
        "the tour waited 8 timed seconds for the agent to finish; this line ends the agent's wait, so the done state "
        "follows the step, not a clock"),
}

CLI_NO_RECEIPT = "a tour step: the bundle's cmux prints no ActionEffect kind (driver_app.py op_cli)"


class GenError(Exception):
    pass


# ------------------------------------------------------------------------------------------------ conversion


def leaf_settings(settings: Mapping[str, Any], prefix: str = "") -> List[Tuple[str, str]]:
    """A tour's `settings` document as (dotted key, CLI value text), in document order."""
    out: List[Tuple[str, str]] = []
    for key, value in settings.items():
        path = f"{prefix}{key}"
        if isinstance(value, dict):
            out.extend(leaf_settings(value, path + "."))
        elif isinstance(value, bool):
            out.append((path, "true" if value else "false"))
        elif isinstance(value, (int, float, str)):
            out.append((path, str(value)))
        else:
            raise GenError(f"settings {path}: {value!r} has no `cmux settings set` spelling")
    return out


def rewrite_urls(argv: List[str], where: str) -> Tuple[List[str], List[str]]:
    """argv with URL_REWRITES applied, and why each applied. A remote URL left over is a GenError."""
    out, notes = [], []
    for word in argv:
        for url in URL.findall(word):
            if url not in URL_REWRITES:
                raise GenError(f"{where}: {url} is not loopback and has no URL_REWRITES entry")
            word = word.replace(url, URL_REWRITES[url])
            notes.append(f"the tour's remote page is {URL_REWRITES[url]} (the loopback web fixture)")
        out.append(word)
    return out, notes


def no_sleep(argv: Sequence[str], where: str) -> None:
    """The generator never writes a sleep into a case."""
    for word in argv:
        if SLEEP.search(word):
            raise GenError(f"{where}: {word!r} sleeps; add a TEXT_REWRITES entry that waits on a signal")


class TourState:
    """What the generator knows of the app while it walks a tour: the config document the case's `settings`
    commands change, the hover target, whether a browser or page tab was opened yet, and the workspaces in order with
    their terminal counts (None: not known), whether each still has one pane with one tab, and whether its terminal
    holds stdin under the write hold."""

    def __init__(self) -> None:
        self.document: Dict[str, str] = {}
        self.hover: Optional[str] = None
        self.paged = False
        # The launch's one workspace with one terminal (bench_launch start_fresh; app_reset restores it).
        self.names: List[Optional[str]] = [None]
        self.terminals: List[Optional[int]] = [1]
        self.single_tab: List[bool] = [True]
        self.holding: List[bool] = [False]
        self.current = 0

    def settings_change(self, argv: Sequence[str]) -> Optional[bool]:
        """Whether a `settings set|unset` argv changes the document (None: not a settings command)."""
        if len(argv) == 4 and argv[0] == "settings" and argv[1] == "set":
            key, value = argv[2], argv[3]
            changed = self.document.get(key) != value
            self.document[key] = value
            return changed
        if len(argv) == 3 and argv[0] == "settings" and argv[1] == "unset":
            return self.document.pop(argv[2], None) is not None
        return None

    def new_workspace(self, name: str, where: str) -> int:
        """Adds the workspace `workspace new` makes and focuses; the facet index of its terminal."""
        if self.current != len(self.names) - 1:
            raise GenError(f"{where}: the current workspace is not the last one, so the generator cannot tell where "
                           "workspace new puts the new one")
        if name in self.names:
            raise GenError(f"{where}: a second workspace named {name!r}")
        known = [count for count in self.terminals if count is not None]
        if len(known) != len(self.terminals):
            raise GenError(f"{where}: a workspace's terminal count is not known, so the new terminal's place is not")
        self.names.append(name)
        self.terminals.append(1)
        self.single_tab.append(True)
        self.holding.append(False)
        self.current = len(self.names) - 1
        return sum(known)

    def workspace(self, selector: str, where: str) -> int:
        """The index of a `name:X` workspace the tour made."""
        if not selector.startswith("name:") or selector[5:] not in self.names:
            raise GenError(f"{where}: workspace {selector!r} is not one the tour made by name")
        return self.names.index(selector[5:])

    def tab_added(self, terminal: bool) -> None:
        self.single_tab[self.current] = False
        count = self.terminals[self.current]
        if terminal and count is not None:
            self.terminals[self.current] = count + 1

    def terminals_forgotten(self) -> None:
        self.single_tab[self.current] = False
        self.terminals[self.current] = None


def changed(pointer: str, max_ms: int) -> Dict[str, Any]:
    return {"pointer": pointer, "predicate": "changed", "maxMs": max_ms}


def equals(pointer: str, value: Any, max_ms: int) -> Dict[str, Any]:
    return {"pointer": pointer, "equals": value, "maxMs": max_ms}


def is_write(argv: Sequence[str]) -> bool:
    return argv[:1] == ["workspace"] and "write" in argv


def terminal_write(argv: List[str], state: TourState, tour_name: str, number: int, max_ms: int,
                   where: str) -> Tuple[List[str], Dict[str, Any], List[str]]:
    """A `workspace name:X ... write --text T` step as (argv, waitFor, notes): T rewritten so its screen settles and
    its last act sets a title (TextRewrite), and a wait on that title in the workspace's only tab."""
    if "--text" not in argv or argv.index("--text") + 1 >= len(argv):
        raise GenError(f"{where}: a terminal write with no --text")
    index = argv.index("--text") + 1
    text = argv[index]
    workspace = state.workspace(argv[1], where)
    if not state.single_tab[workspace]:
        raise GenError(f"{where}: workspace {argv[1]} has more than one pane or tab, so its title has no fixed place")
    rewrite = TEXT_REWRITES.get(text)
    notes = [rewrite.why] if rewrite else []
    holding = state.holding[workspace]
    if rewrite and rewrite.title:
        title = rewrite.title
        out = (EOT if holding and not rewrite.release else "") + rewrite.text
    else:
        title = write_title(tour_name, number)
        body = rewrite.text if rewrite else text
        if not body.endswith("\r"):
            raise GenError(f"{where}: the text does not end with a return, so the shell never runs it")
        body = body[:-1]
        if not body.startswith(CLEAR):
            body = f"{CLEAR}; {body}"
        out = f"{EOT if holding else ''}{body}; {title_printf(title)}; {HOLD}\r"
        notes.append(SETTLED_WRITE)
    state.holding[workspace] = True
    argv = argv[:index] + [out] + argv[index + 1:]
    return argv, equals(single_tab_title(workspace), title, max_ms), notes


def wait_for(argv: Sequence[str], state: TourState, max_ms: int, where: str) -> Tuple[Optional[Dict[str, Any]], str]:
    """The waitFor of a cli step that writes no terminal, or None and why the settle barrier alone ends it."""
    settings = state.settings_change(argv)
    if settings is not None:
        if settings:
            return changed(SETTINGS_HASH, max_ms), ""
        return None, "the setting already has this value, so the document does not change"
    if argv[:2] == ["workspace", "new"]:
        name = argv[argv.index("--name") + 1] if "--name" in argv[:-1] else None
        if not name:
            raise GenError(f"{where}: workspace new with no --name")
        return equals(terminal_attach(state.new_workspace(name, where)), ATTACHED, max_ms), ""
    if argv[:2] == ["action", "run"] and len(argv) >= 3:
        action = argv[2]
        if action in ADDS_TERMINAL:
            state.tab_added(terminal=True)
        elif action in FORGETS_TERMINALS:
            state.terminals_forgotten()
        if action == "workspace.showResources":
            state.hover = action
        pointer = ACTION_WAITS.get(action)
        if pointer:
            return changed(pointer, max_ms), ""
        return None, f"no snapshot value {action} is sure to change"
    if argv[:2] == ["tab", "new-browser"]:
        state.tab_added(terminal=False)
        if state.paged:
            return changed(TAB_COUNT, max_ms), ""
        state.paged = True
        return equals(FIRST_PAGE_LOAD, LOAD_FINISHED, max_ms), ""
    if argv[:1] == ["tab"] and len(argv) >= 2 and argv[1] in TAB_VERBS:
        state.tab_added(terminal=False)
        state.paged = True
        return changed(TAB_VERBS[argv[1]], max_ms), ""
    if argv[:3] == ["app", "call", "debug.pointer_hover"]:
        target = argv[3] if len(argv) > 3 else "{}"
        if target != state.hover:
            state.hover = target
            return changed(HOVER_TARGET, max_ms), ""
        return None, "the pointer stays on the same mark, so the hover target does not change"
    return None, "its effect is done when its control call answers (the generator's mapping table)"


def step_id(number: int, title: str) -> str:
    return f"{number:02d}-{tour.slug(title)}".rstrip("-")


def cli_step(sid: str, argv: List[str], *, daemon: bool, wait: Optional[Dict[str, Any]], bound: Optional[int],
             notes: Sequence[str]) -> Dict[str, Any]:
    step: Dict[str, Any] = {"id": sid, "op": "cli",
                            "target": {"session": "current"} if daemon else {"window": "current"},
                            "args": {"argv": argv},
                            "expect": {"outcome": "ok", "noReceiptReason": CLI_NO_RECEIPT}}
    if wait:
        step["waitFor"] = wait
    if bound:
        step["settleMaxMs"] = bound
    if notes:
        step["note"] = "; ".join(notes)
    return step


def runner_step(sid: str, shot: bool, bound: Optional[int], note: str) -> Dict[str, Any]:
    step: Dict[str, Any] = {"id": sid, "op": "snapshot" if shot else "settle"}
    if bound:
        step["settleMaxMs"] = bound
    if note:
        step["note"] = note
    return step


def command_of(step: Mapping[str, Any]) -> Optional[List[str]]:
    """The tour step's cmux argv, an rpc as `app call`, or None for a wait-only step."""
    if step.get("cmux") is not None:
        return list(step["cmux"])
    rpc = step.get("rpc")
    if rpc is not None:
        return ["app", "call", rpc["method"], json.dumps(rpc.get("params") or {}, sort_keys=True,
                                                         separators=(",", ":"))]
    return None


def optional_evidence(argv: Sequence[str]) -> Optional[str]:
    """OPTIONAL_KNOWN's evidence for an optional step's argv, or None."""
    for prefix, evidence in OPTIONAL_KNOWN.items():
        if tuple(argv[:len(prefix)]) == prefix:
            return evidence
    return None


def drop_reason(name: str, number: int, raw: Mapping[str, Any], argv: Optional[List[str]]) -> Optional[str]:
    """Why a tour step is not in the case, or None."""
    drop = DROPPED.get((name, number))
    if drop:
        return drop
    method = (raw.get("rpc") or {}).get("method") or (argv[2] if argv and argv[:2] == ["app", "call"] else None)
    if method in DEBUG_ONLY_METHODS:
        return f"{method}: {DEBUG_ONLY_METHODS[method]}, and the tours suite runs the bench build"
    if argv and argv[:2] == ["agent", "new-chat"]:
        return NO_AGENT_CHAT
    if raw.get("optional") and (argv is None or optional_evidence(argv) is None):
        return OPTIONAL_UNKNOWN.format(reason=raw["optional"].strip())
    return None


def convert(path: Path, web: bool = DRIVER_WEB_FIXTURE) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """One tour as (case, its coverage.json entry). `web`: whether driver_app serves fixture.web."""
    loaded = tour.load_tour(path)
    name = loaded["name"]
    if loaded.get("features"):
        raise GenError(f"{path.name}: the tour launches with features {loaded['features']}, which no case can turn on; "
                       "add it to EXCLUDED with the reason")
    state = TourState()
    steps: List[Dict[str, Any]] = []
    entry: Dict[str, Any] = {"tour": path.relative_to(REPO).as_posix() if path.is_relative_to(REPO) else path.name,
                             "case": f"{SUITE}/{name}", "tour_steps": len(loaded["steps"]), "waitFor": 0,
                             "settle": 0, "dropped": {}, "rewritten": {}}
    untested = ["pixels: the tour's screenshots and video (scripts/cmux-next/media/tour.py); a case compares model "
                "state, and its reviewed baseline stands in for each picture"]
    preconditions = ["private scratch config", "tagged bench build", "no unrelated app instance",
                     "the main window is 1440 x 900 pt",
                     "the launch has one workspace with one terminal (an empty saved session)"]
    for number, (key, value) in enumerate(leaf_settings(loaded.get("settings") or {}), 1):
        argv = ["settings", "set", key, value]
        wait, why = wait_for(argv, state, WAIT_MS, f"{path.name} settings")
        steps.append(cli_step(f"setup-{number:02d}-{tour.slug(key)}", argv, daemon=False, wait=wait, bound=None,
                              notes=["the tour launches with this setting; case-v1 has no launch config"]
                              + ([why] if why else [])))
    for index, raw in enumerate(loaded["steps"]):
        number = index + 1
        title = raw["title"].strip()
        where = f"{path.name} step {number}"
        sid = step_id(number, title)
        notes: List[str] = []
        if (name, title) in REWRITES:
            raw, why = REWRITES[(name, title)]
            entry["rewritten"][sid] = why
            notes.append(why)
        argv = command_of(raw)
        drop = drop_reason(name, number, raw, argv)
        if argv is not None and not drop:
            argv, url_notes = rewrite_urls(argv, where)
            if url_notes and not web:
                drop = NO_WEB
            notes.extend(url_notes)
        if drop:
            entry["rewritten"].pop(sid, None)
            entry["dropped"][sid] = drop
            untested.append(f"tour step {number} ({title}): {drop}")
            continue
        if not web and (name, number) in NO_WEB_NOTES:
            notes.append(NO_WEB_NOTES[(name, number)])
        shot = raw.get("shot", True) is not False
        long_wait = float(raw.get("wait", tour.DEFAULT_WAIT)) >= WIDE_WAIT_S
        max_ms = WIDE_MS if long_wait else WAIT_MS
        bound = WIDE_MS if long_wait else None
        if argv is None:
            entry["settle"] += 1
            steps.append(runner_step(sid, shot, bound, "; ".join(notes)))
            continue
        if raw.get("optional"):
            notes.append(OPTIONAL_KEPT.format(reason=raw["optional"].strip(), evidence=optional_evidence(argv)))
        if is_write(argv):
            argv, wait, write_notes = terminal_write(argv, state, name, number, max_ms, where)
            notes.extend(write_notes)
            entry["rewritten"].setdefault(sid, "; ".join(write_notes))
        else:
            wait, why = wait_for(argv, state, max_ms, where)
            if why:
                notes.append(why)
        no_sleep(argv, where)
        entry["waitFor" if wait else "settle"] += 1
        steps.append(cli_step(sid, argv, daemon=bool(raw.get("daemon")), wait=wait, bound=bound, notes=notes))
    web_steps = "$WEB" in json.dumps(steps)
    if web_steps:
        preconditions.append("the loopback web fixture server ($WEB, webfixture.py)")
    fixture: Dict[str, Any] = {"seed": f"tours-{name}-v1", "network": "offline", "clock": "fixed", "agent": "mock"}
    if web_steps:
        fixture["web"] = True
    case = {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": name,
        "suite": SUITE,
        "title": f"Tour: {loaded['title']}"[:200],
        "priority": "P2",
        "surface": "cmux-next-native",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {"viewport": dict(VIEWPORT)},
        "fixture": fixture,
        "preconditions": preconditions,
        "requires": ["gui"],
        "platforms": ["mac"],
        "steps": steps,
        "invariants": [
            "each step's settled snapshot is the model state of the tour's picture of that step",
            "no step waits on a clock: each ends on its waitFor value or the settle barrier",
        ],
        "teardown": ["quit the tagged app the run started", "verify its debug socket is gone"],
        "untested": untested,
    }
    entry["steps"] = len(steps)
    return case, entry


def generate(tours_dir: Path, web: bool = DRIVER_WEB_FIXTURE) -> Dict[str, Any]:
    """Every file of the suite: one case per tour that EXCLUDED does not name, and coverage.json."""
    paths = sorted(tours_dir.glob("*.json"))
    if not paths:
        raise GenError(f"{tours_dir}: no tours")
    files: Dict[str, Any] = {}
    tours: Dict[str, Any] = {}
    excluded: Dict[str, str] = {}
    for path in paths:
        if tour.slug(path.stem) in EXCLUDED:
            excluded[tour.slug(path.stem)] = EXCLUDED[tour.slug(path.stem)]
            continue
        try:
            case, entry = convert(path, web)
        except tour.TourError as error:
            raise GenError(str(error)) from None
        if f"{case['id']}.json" in files:
            raise GenError(f"{path.name}: case {case['id']} is generated twice")
        files[f"{case['id']}.json"] = case
        tours[case["id"]] = entry
    files[COVERAGE] = {
        "generator": GENERATOR,
        "suite": SUITE,
        "task": TASK,
        "tours": "scripts/cmux-next/media/tours",
        "total": len(tours) + len(excluded),
        "covered": len(tours),
        "excluded": excluded,
        "missing": [],
        "verdicts": "not run",
        "cases": len(tours),
        "steps": {key: sum(t[key] for t in tours.values()) for key in ("waitFor", "settle")},
        "by_tour": tours,
    }
    return files


# ------------------------------------------------------------------------------------------------ files


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def owned_files(out: Path) -> List[str]:
    """The case files the last generation wrote (from its coverage.json)."""
    path = out / COVERAGE
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return []
    return sorted(f"{case}.json" for case in (data.get("by_tour") or {}))


def drift(out: Path, files: Mapping[str, Any]) -> List[str]:
    problems = []
    for name, value in sorted(files.items()):
        path = out / name
        if not path.is_file():
            problems.append(f"{name}: missing")
        elif path.read_text(encoding="utf-8") != render(value):
            problems.append(f"{name}: differs from a fresh generation")
    for name in owned_files(out):
        if name not in files and (out / name).exists():
            problems.append(f"{name}: generated earlier, its tour is gone")
    return problems


def write(out: Path, files: Mapping[str, Any]) -> Tuple[int, int]:
    """Writes changed files and removes the cases of tours that are gone; refuses to overwrite a case file it did
    not write."""
    out.mkdir(parents=True, exist_ok=True)
    owned = set(owned_files(out))
    for name in files:
        if name != COVERAGE and (out / name).exists() and name not in owned:
            raise GenError(f"{out / name}: exists and was not written by this generator")
    written = 0
    for name, value in sorted(files.items()):
        path = out / name
        text = render(value)
        if not path.is_file() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")
            written += 1
    removed = 0
    for name in sorted(owned - set(files)):
        (out / name).unlink(missing_ok=True)
        removed += 1
    return written, removed


# ------------------------------------------------------------------------------------------------ self tests


def validation_errors(case: Mapping[str, Any]) -> List[str]:
    """The corpus checks `oracle.py check` runs on one case: the case-v1 schema (normalize.validate) and the
    semantic rules (oracle.check_case)."""
    import normalize
    import oracle
    schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
    errors = list(normalize.validate(case, schema))
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / SUITE / f"{case['id']}.json"
        path.parent.mkdir()
        path.write_text(render(case), encoding="utf-8")
        loaded, error = oracle.load_case(path, f"{SUITE}/{case['id']}")
        if error:
            return errors + [error]
        errors.extend(oracle.check_case(loaded, oracle.mutation_operations()))
    return errors


def tour_file(directory: Path, name: str, data: Mapping[str, Any]) -> Path:
    path = directory / f"{name}.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


class GenToursSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.files = generate(TOURS_DIR)
        cls.cases = {k[:-5]: v for k, v in cls.files.items() if k != COVERAGE}
        cls.tours = {tour.slug(p.stem): json.loads(p.read_text(encoding="utf-8")) for p in TOURS_DIR.glob("*.json")}

    def test_every_tour_is_a_case_or_excluded(self) -> None:
        self.assertEqual(len(self.tours), 23, "the spec's tours suite is the 23 media tours")
        coverage = self.files[COVERAGE]
        self.assertEqual(sorted(self.cases) + sorted(coverage["excluded"]),
                         sorted(set(self.tours) - set(EXCLUDED)) + sorted(EXCLUDED))
        self.assertEqual((coverage["covered"], len(coverage["excluded"]), coverage["total"]), (22, 1, 23))
        self.assertTrue(all(coverage["excluded"].values()))

    def test_launch_features_exclude_the_tour(self) -> None:
        self.assertEqual(sorted(name for name, data in self.tours.items() if data.get("features")), sorted(EXCLUDED))
        self.assertNotIn("host-pressure", self.cases)
        self.assertIn("hostPressure", self.files[COVERAGE]["excluded"]["host-pressure"])
        with tempfile.TemporaryDirectory() as tmp:
            tour_file(Path(tmp), "featured", {"title": "F", "features": ["x"], "steps": [{"title": "Launch"}]})
            with self.assertRaisesRegex(GenError, "EXCLUDED"):
                generate(Path(tmp))

    def test_cases_pass_the_corpus_checks(self) -> None:
        for name, case in self.cases.items():
            with self.subTest(case=name):
                self.assertEqual(validation_errors(case), [])

    def test_no_case_waits_on_a_clock(self) -> None:
        for name, case in self.cases.items():
            text = json.dumps(case)
            with self.subTest(case=name):
                self.assertIsNone(SLEEP.search(text), "a case never sleeps, in the runner or a shell")
                for step in case["steps"]:
                    self.assertNotIn("wait", step)
                    self.assertIn(step["op"], ("cli", "snapshot", "settle"))

    def test_no_remote_url_and_no_web_fixture_yet(self) -> None:
        for name, case in self.cases.items():
            with self.subTest(case=name):
                self.assertEqual(URL.findall(json.dumps(case)), [])
                self.assertNotIn("$WEB", json.dumps(case["steps"]))
                self.assertNotIn("web", case["fixture"])
        self.assertEqual(self.files[COVERAGE]["by_tour"]["core"]["dropped"]["08-browser-tab"], NO_WEB)
        self.assertEqual(self.files[COVERAGE]["by_tour"]["pinned-tabs"]["dropped"]["05-browser-tab-four-tabs"], NO_WEB)

    def test_driver_web_fixture_flag_matches_driver_app(self) -> None:
        refuses = DRIVER_NO_WEB in DRIVER_APP.read_text(encoding="utf-8")
        self.assertEqual(DRIVER_WEB_FIXTURE, not refuses,
                         "driver_app.py serves fixture.web now: set DRIVER_WEB_FIXTURE and regenerate the suite")

    def test_web_steps_come_back_with_the_fixture(self) -> None:
        case, entry = convert(TOURS_DIR / "core.json", web=True)
        browser = {s["id"]: s for s in case["steps"]}["08-browser-tab"]
        self.assertEqual(browser["args"]["argv"], ["tab", "new-browser", "--url", "$WEB/load.html"])
        self.assertEqual(browser["waitFor"], equals(FIRST_PAGE_LOAD, LOAD_FINISHED, WIDE_MS))
        self.assertEqual(browser["settleMaxMs"], WIDE_MS)
        self.assertTrue(case["fixture"]["web"])
        self.assertNotIn("08-browser-tab", entry["dropped"])
        self.assertEqual(validation_errors(case), [])

    def test_core_is_mapped(self) -> None:
        core = {s["id"]: s for s in self.cases["core"]["steps"]}
        self.assertEqual(core["01-launch"]["op"], "snapshot")
        self.assertEqual(core["02-new-workspace"]["waitFor"], equals(terminal_attach(1), ATTACHED, WAIT_MS))
        self.assertEqual(core["05-split-right"]["waitFor"], changed(WORKSPACES, WAIT_MS))
        self.assertEqual(core["07-new-terminal-tab"]["waitFor"], changed(TAB_COUNT, WAIT_MS))
        self.assertEqual(core["09-hide-the-sidebar"]["waitFor"], changed(SIDEBAR_HIDDEN, WAIT_MS))
        # Tour holds four terminals (its own, two splits and a tab) after the launch's one: Agent's is the sixth.
        self.assertEqual(core["14-agent-workspace"]["waitFor"], equals(terminal_attach(5), ATTACHED, WAIT_MS))
        self.assertEqual(core["16-an-agent-works-row-working-spinner"]["waitFor"],
                         equals(terminal_attach(6), ATTACHED, WAIT_MS))
        typed = core["03-type-in-the-terminal"]
        self.assertEqual(typed["target"], {"session": "current"})
        self.assertEqual(typed["args"]["argv"][-1], "clear; echo hello from the cmux-next tour; "
                         + title_printf("tours core 03") + f"; {HOLD}\r")
        self.assertEqual(typed["waitFor"], equals(single_tab_title(1), "tours core 03", WAIT_MS))
        progress = core["04-a-command-reports-progress-tab-loading-s"]
        self.assertEqual(progress["args"]["argv"][-1], EOT + "clear; printf '\\033]9;4;3\\007'; "
                         + title_printf("tours core 04") + f"; {HOLD}\r", "^D ends step 3's hold first")
        self.assertEqual(progress["waitFor"], equals(single_tab_title(1), "tours core 04", WAIT_MS))
        for dropped in ("12-notifications-panel", "13-agent-chat", "20-profile-menu"):
            self.assertNotIn(dropped, core)
        self.assertIn("17-the-agent-finishes-done-mark-in-the-spin",
                      self.files[COVERAGE]["by_tour"]["core"]["rewritten"])

    def test_core_agent_steps_wait_on_their_end_state(self) -> None:
        core = {s["id"]: s for s in self.cases["core"]["steps"]}
        start, finish = core["15-agent-starts"], core["17-the-agent-finishes-done-mark-in-the-spin"]
        text = start["args"]["argv"][-1]
        self.assertTrue(text.startswith("clear; printf '\\033]7501;state=working"), "a fresh shell: no ^D")
        working, held, done = (text.index(title_printf(AGENT_WORKING)), text.index("head -n 1"),
                               text.index("state=done"))
        self.assertLess(working, held, "the working title is set before the run waits for its line")
        self.assertLess(held, done)
        self.assertLess(done, text.index(title_printf(AGENT_DONE)), "the done title follows the done state")
        self.assertTrue(text.endswith(f"{HOLD}\r"))
        self.assertEqual(start["waitFor"], equals(single_tab_title(2), AGENT_WORKING, WAIT_MS))
        self.assertEqual(finish["args"]["argv"][-2:], ["--text", "done\r"], "it answers head: no ^D, no wrap")
        self.assertEqual(finish["waitFor"], equals(single_tab_title(2), AGENT_DONE, WAIT_MS))
        self.assertEqual(finish["target"], {"session": "current"})

    def test_every_terminal_write_waits_on_its_title_and_holds(self) -> None:
        writes = 0
        for name, case in self.cases.items():
            for step in case["steps"]:
                argv = (step.get("args") or {}).get("argv") or []
                if not is_write(argv):
                    continue
                writes += 1
                with self.subTest(case=name, step=step["id"]):
                    wait = step["waitFor"]
                    self.assertRegex(wait["pointer"],
                                     r"^/topology/topology/workspaces/\d+/screens/0/panes/0/tabs/0/title$")
                    text = argv[-1]
                    if text != "done\r":
                        self.assertTrue(text.lstrip(EOT).startswith(CLEAR), "the screen starts clean")
                        self.assertTrue(text.endswith(f"{HOLD}\r"), "no prompt is drawn after the title")
                    self.assertIn(title_printf(wait["equals"]), text if text != "done\r" else
                                  {s["id"]: s for s in case["steps"]}["15-agent-starts"]["args"]["argv"][-1])
        self.assertEqual(writes, 7, "core 3, 4, 15, 17; glass 3; launch-themes and launch-wallpapers 5")

    def test_write_refuses_a_title_with_no_fixed_place(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            write_step = ["workspace", "name:W", "screen", "current", "pane", "current", "tab", "current", "terminal",
                          "current", "write", "--text", "echo hi\r"]
            tour_file(Path(tmp), "split", {"title": "S", "steps": [
                {"title": "Launch"}, {"title": "New", "cmux": ["workspace", "new", "--name", "W"]},
                {"title": "Split", "cmux": ["action", "run", "splitRight"]}, {"title": "Type", "cmux": write_step}]})
            with self.assertRaisesRegex(GenError, "more than one pane or tab"):
                generate(Path(tmp))
            tour_file(Path(tmp), "split", {"title": "S", "steps": [
                {"title": "Launch"}, {"title": "New", "cmux": ["workspace", "new", "--name", "W"]},
                {"title": "Close", "cmux": ["action", "run", "closePane"]},
                {"title": "Next", "cmux": ["workspace", "new", "--name", "X"]}]})
            with self.assertRaisesRegex(GenError, "terminal count is not known"):
                generate(Path(tmp))

    def test_optional_steps_are_dropped_unless_known(self) -> None:
        """tour.py reports a failing optional step as unavailable; a case step expects one outcome, so an optional step
        is in a case only when OPTIONAL_KNOWN proves its ok answer."""
        by_tour = self.files[COVERAGE]["by_tour"]
        kept = dropped = 0
        for name, data in self.tours.items():
            if name in EXCLUDED:
                continue
            steps = {s["id"]: s for s in self.cases[name]["steps"]}
            for number, raw in enumerate(data["steps"], 1):
                if not raw.get("optional"):
                    continue
                sid = step_id(number, raw["title"].strip())
                with self.subTest(case=name, step=sid):
                    if sid in steps:
                        kept += 1
                        self.assertIsNotNone(optional_evidence(steps[sid]["args"]["argv"]))
                        self.assertEqual(steps[sid]["expect"]["outcome"], "ok")
                        self.assertIn("kept:", steps[sid]["note"])
                    else:
                        dropped += 1
                        self.assertIn(sid, by_tour[name]["dropped"])
        self.assertEqual(by_tour["agent-pane"]["dropped"]["02-open-agent-chat"], NO_AGENT_CHAT)
        self.assertGreater(kept, 0)
        self.assertGreater(dropped, 0)

    def test_page_and_card_actions_wait_on_what_they_publish(self) -> None:
        for name in ("app-store-features", "app-store-feature-gaps", "sidebar-view-toggles", "sidebar-edit-mode"):
            store = [s for s in self.cases[name]["steps"] if s.get("args", {}).get("argv", [])[:3] ==
                     ["action", "run", "appStore.show"]]
            with self.subTest(case=name):
                self.assertEqual([s["waitFor"]["pointer"] for s in store], [WEBVIEW_PAGES])
        card = {s["id"]: s for s in self.cases["hover-card"]["steps"]}["12-a-real-workspace-card-dark"]
        self.assertEqual(card["waitFor"], changed(HOVER_TARGET, WIDE_MS))

    def test_rpc_becomes_app_call(self) -> None:
        home = {s["id"]: s for s in self.cases["home"]["steps"]}
        dark = home["04-dark"]
        self.assertEqual(dark["args"]["argv"], ["app", "call", "debug.appearance", '{"mode":"dark"}'])
        self.assertNotIn("waitFor", dark)
        rail = [s for s in self.cases["rail-card-top"]["steps"] if "pointer_hover" in json.dumps(s)]
        self.assertEqual(rail[0]["waitFor"], changed(HOVER_TARGET, WAIT_MS))
        self.assertNotIn("waitFor", rail[1], "the second hover on the same mark changes no target")

    def test_settings_waits_follow_the_document(self) -> None:
        glass = self.cases["glass"]["steps"]
        setup = [s for s in glass if s["id"].startswith("setup-")]
        self.assertEqual([s["args"]["argv"][2:] for s in setup],
                         [["appearance.background", "hokusai-great-wave"], ["appearance.theme", "Clay Orange"]])
        self.assertTrue(all(s["waitFor"] == changed(SETTINGS_HASH, WAIT_MS) for s in setup))
        launch = glass[len(setup)]
        self.assertEqual((launch["id"], launch["op"], launch["settleMaxMs"]),
                         ("01-launch-over-art", "snapshot", WIDE_MS))
        state = TourState()
        self.assertEqual(wait_for(["settings", "set", "a.b", "x"], state, 1, "t")[0], changed(SETTINGS_HASH, 1))
        self.assertIsNone(wait_for(["settings", "set", "a.b", "x"], state, 1, "t")[0])
        self.assertEqual(wait_for(["settings", "unset", "a.b"], state, 1, "t")[0], changed(SETTINGS_HASH, 1))
        self.assertIsNone(wait_for(["settings", "unset", "a.b"], state, 1, "t")[0])

    def test_dropped_steps_have_a_reason(self) -> None:
        by_tour = self.files[COVERAGE]["by_tour"]
        main = by_tour["main-pane"]
        self.assertEqual([s["id"] for s in self.cases["main-pane"]["steps"]],
                         ["setup-01-layout-mainpane", "01-launch", "02-new-workspace"])
        self.assertEqual(len(main["dropped"]), 11)
        self.assertTrue(all(main["dropped"].values()))
        update = [s["args"]["argv"] for s in self.cases["update-card"]["steps"] if s["op"] == "cli"]
        self.assertFalse(any("debug.update_surfaces" in argv for argv in update))
        self.assertEqual(len(by_tour["update-card"]["dropped"]), 2)
        for name, case in self.cases.items():
            dropped = by_tour[name]["dropped"]
            ids = {s["id"] for s in case["steps"]}
            with self.subTest(case=name):
                self.assertFalse(ids & set(dropped))
                self.assertEqual(by_tour[name]["tour_steps"], len(dropped) + sum(
                    1 for s in case["steps"] if not s["id"].startswith("setup-")))
                self.assertEqual(sum(1 for u in case["untested"] if u.startswith("tour step ")), len(dropped))

    def test_refuses_a_sleep_and_a_remote_url(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tours = Path(tmp)
            tour_file(tours, "a", {"title": "A", "steps": [{"title": "Launch", "wait": 2}, {
                "title": "Ws", "cmux": ["workspace", "new", "--name", "W"]}, {
                "title": "Sleep", "daemon": True, "cmux": ["workspace", "name:W", "write", "--text", "sleep 3\r"]}]})
            with self.assertRaisesRegex(GenError, "sleeps"):
                generate(tours)
            tour_file(tours, "a", {"title": "A", "steps": [{"title": "Launch"}, {
                "title": "Web", "cmux": ["tab", "new-browser", "--url", "https://cmux.com"]}]})
            with self.assertRaisesRegex(GenError, "not loopback"):
                generate(tours)

    def test_write_check_and_removal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tours, out = Path(tmp) / "tours", Path(tmp) / "out"
            tours.mkdir()
            tour_file(tours, "one", {"title": "One", "steps": [{"title": "Launch"}]})
            tour_file(tours, "two", {"title": "Two", "steps": [{"title": "Launch", "shot": False}]})
            files = generate(tours)
            self.assertEqual(write(out, files), (3, 0))
            self.assertEqual(drift(out, files), [])
            self.assertEqual(json.loads((out / "two.json").read_text())["steps"][0]["op"], "settle")
            (tours / "two.json").unlink()
            files = generate(tours)
            self.assertEqual(drift(out, files), ["coverage.json: differs from a fresh generation",
                                                 "two.json: generated earlier, its tour is gone"])
            self.assertEqual(write(out, files), (1, 1))
            self.assertFalse((out / "two.json").exists())
            (out / "stray.json").write_text("{}")
            tour_file(tours, "stray", {"title": "Stray", "steps": [{"title": "Launch"}]})
            with self.assertRaisesRegex(GenError, "not written by this generator"):
                write(out, generate(tours))

    def test_checked_in_suite_is_fresh(self) -> None:
        self.assertEqual(drift(DEFAULT_OUT, self.files), [])


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--tours", type=Path, default=TOURS_DIR, help="the media tours directory")
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GenToursSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    try:
        files = generate(args.tours)
        if args.check:
            problems = drift(args.out, files)
            for problem in problems:
                print(f"gen_tours: {args.out / problem}")
            return 1 if problems else 0
        written, removed = write(args.out, files)
    except GenError as error:
        print(f"gen_tours: {error}", file=sys.stderr)
        return 2
    coverage = files[COVERAGE]
    print(f"gen_tours: {coverage['cases']} cases ({coverage['steps']['waitFor']} waitFor, "
          f"{coverage['steps']['settle']} settle), {written} written, {removed} removed, into {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
