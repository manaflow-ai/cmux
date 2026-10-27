#!/usr/bin/env python3
"""The browse-heavy corpus story's scripted parts (p12-perf-process.md 3.8, task 119).

    python3 -I scripts/perf-lab/corpus/browse_heavy.py --check   # the committed files are what this script makes
    python3 -I scripts/perf-lab/corpus/browse_heavy.py --write   # makes them again

browse-heavy is a scripted story, as Chromium's multi-tab system_health story is: code opens a fixed set of
tabs and switches between them (tools/perf/page_sets/system_health/multi_tab_stories.py, MultiTabTypical24Story),
and nothing comes from a person's session. This script makes, deterministically (a seeded random.Random, read
only through random()):

  perf-corpus/browse-heavy/layout.json  the layout snapshot (session_io.py, task 111): 6 workspaces with 5
                                        Chromium tabs each (30, in pane p0), WebKit tabs in w1, w3 (its own
                                        pane) and w5, and a terminal beside the tabs of w0
  perf-corpus/browse-heavy.json         layout, launch config, input track and checkpoints. The input track runs
                                        ROUNDS rounds: hibernate one background Chromium tab in each of w1 to w5
                                        (hibernateTab), then visit every workspace with Cmd-1 to Cmd-6 (each
                                        visit: a trackpad flick on the page, Ctrl-Tab, Ctrl-Shift-Tab, then
                                        tab.focus on the tab hibernated at the round's start, which wakes it);
                                        the visits of w1 and w4 type in the omnibar (Cmd-L, synthetic letters,
                                        Escape) and the visit of w3 shows one of its WebKit tabs

The manifest's `config` (CONFIG, which play.py sets over the bench's config) makes the keys reach the same targets
on any bench: sidebar.numbering is workspacesOnly, so Cmd-N shows workspace N-1 (the default, allItems, numbers
Home and the App Store first; SidebarNavigationSettings), and the omnibar's remote suggestions are off, so typing
sends no suggest request and the popup's rows come from local state only. A bare typed word still asks the host's
resolver whether it is an intranet host (IntranetHostProbe); that loads no page.

The Chromium tabs show the local pages of the layout import (perf-stress-session.py add_tab), not Web Page Replay
pages: no player step yet loads a page list into each tab after the import, so web_archive is null (PLANNED).
No key goes where its text could run or load a page: the omnibar is always left with Escape, never Return; the
terminal of w0 gets no key. The fields a lab host records (checkpoint digests, status) are kept from the
committed manifest.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_corpus_browse_heavy.py
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import random
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
STORY = "browse-heavy"
MANIFEST_PATH = f"perf-corpus/{STORY}.json"
LAYOUT_PATH = f"perf-corpus/{STORY}/layout.json"
SEED = 119

DURATION_MS = 180_000
ROUNDS = 3
ROUND_MS = DURATION_MS // ROUNDS

WINDOW = (1600, 1000)  # perf-stress-session.py WINDOW_SIZE: session_io.importable refuses any other window
PAGE_POINT = (480, 520)  # window points (top-left origin) inside pane p0 of every workspace
SCROLL_HZ = 60
SCROLL_DECAY = 0.85

# The panes of each workspace, left to right: their tab kinds. Pane p0 of every workspace holds its 5 Chromium tabs.
CHROMIUM_PER_WORKSPACE = 5
PANES: tuple[tuple[tuple[str, ...], ...], ...] = (
    (("chromium",) * 5, ("terminal",)),
    (("chromium",) * 5 + ("webkit",),),
    (("chromium",) * 5,),
    (("chromium",) * 5, ("webkit", "webkit")),
    (("chromium",) * 5,),
    (("chromium",) * 5 + ("webkit",),),
)
OMNIBAR_WORKSPACES = (1, 4)
WEBKIT_PANE_WORKSPACE = 3
# The workspace order of each round's visits. Every round ends on w0, so each starts with w0 shown.
VISIT_ORDER = ((1, 2, 3, 4, 5, 0), (5, 4, 3, 2, 1, 0), (3, 1, 5, 2, 4, 0))

# The replay's cmux-next.json settings (the manifest's `config`).
CONFIG = {"browser.omnibar.remoteSuggestions": False, "sidebar.numbering": "workspacesOnly"}
# The items Cmd-1 counts before the first workspace under each sidebar.numbering (SidebarNavigationSettings.Scope:
# allItems numbers Home = 1, App Store = 2, the first workspace = 3).
TOP_ITEMS = {"allItems": 2, "workspacesOnly": 0}
NEIGHBOR_RADIUS_KEY = "browser.keepNeighborTabsAwake"

# macOS virtual key codes (play.py KEY_NAMES): the keys that are not typed text.
DIGIT_KEYS = (18, 19, 20, 21, 23, 22, 26, 28)  # 1 to 8: Cmd-N is selectWorkspaceByNumber
KEY_L, KEY_TAB, KEY_RETURN, KEY_ESCAPE, KEY_DELETE = 37, 48, 36, 53, 51
# OmnibarReducer.escape from typed text with its popup open: close the popup, revert the edit, leave the field.
# The popup is always open then: the typed text is never empty, so its what-you-typed row exists
# (OmniboxPhaseA.primary), and no key arrows a row.
ESCAPES = 3

METRICS = ("tab_switch_to_frame", "switch_to_frame", "wake_to_frame", "omnibar_key_to_frame", "key_to_frame",
           "dropped_frames", "footprint")
METRIC_UNITS = {"dropped_frames": "count", "footprint": "bytes"}

PLANNED = ("Scripted by scripts/perf-lab/corpus/browse_heavy.py (task 119). A lab host adds the checkpoint digests "
           "of a recording replay (task 116). The Chromium tabs show the layout import's local pages: Web Page "
           "Replay pages (task 113) need a player step that loads a page list into each Chromium tab after the "
           "layout import, so web_archive stays null until play.py has it.")
DESCRIPTION = ("30 Chromium tabs over 6 workspaces and 4 WebKit tabs: Cmd-1 to Cmd-6 workspace switches, Ctrl-Tab, "
               "Ctrl-Shift-Tab and tab clicks, background tabs hibernated outside the awake neighbors and woken by "
               "showing them, omnibar typing closed with Escape, in 3 rounds of 60 s.")


def _load(name: str, path: Path):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def session_io():
    return _load("perf_lab_corpus_session_io", HERE / "session_io.py")


def manifest_module():
    return _load("perf_lab_corpus_manifest", HERE / "manifest.py")


def setting(key: str, root: Path = REPO_ROOT) -> Any:
    """The value the replay launches with: CONFIG's, else the cmux-next.json default (manifest.load_settings)."""
    return CONFIG[key] if key in CONFIG else manifest_module().load_settings(root)[key]


def digit_workspace(digit: int, numbering: str) -> int | None:
    """The workspace Cmd-<digit> (1 to 8) shows under sidebar.numbering, None for a top item (Home, App Store)."""
    index = digit - 1 - TOP_ITEMS[numbering]
    return index if index >= 0 else None


def ring_distance(a: int, b: int, count: int) -> int:
    """Steps between two tabs of a strip of COUNT, wrapping as Ctrl-Tab and the awake neighbors do (NeighborTabs)."""
    return min((a - b) % count, (b - a) % count)


# ---------------------------------------------------------------- layout

def _pane(kinds: tuple[str, ...]) -> dict[str, Any]:
    return {"tabs": list(kinds), "selected": 0}


def layout() -> dict[str, Any]:
    workspaces = []
    for panes in PANES:
        tree = _pane(panes[0]) if len(panes) == 1 else {"split": "right", "children": [_pane(p) for p in panes]}
        workspaces.append({"tree": tree, "even": True})
    return {"schema": "cmux-layout-snapshot/v1", "window": list(WINDOW), "workspaces": workspaces, "shown": 0,
            "focused_pane": 0, "busy": []}


def chromium_tabs() -> list[str]:
    """The references of the Chromium tabs in order (workspace, pane, tab)."""
    return [f"@w{w}.p{p}.t{t}" for w, panes in enumerate(PANES) for p, kinds in enumerate(panes)
            for t, kind in enumerate(kinds) if kind == "chromium"]


# ---------------------------------------------------------------- input track

def _ref(workspace: int, pane: int, tab: int | None = None) -> str:
    return f"@w{workspace}.p{pane}" + ("" if tab is None else f".t{tab}")


class _Track:
    """The input track and the state it leaves: each workspace's selected tab in p0 and the hibernated tabs."""

    def __init__(self, rng: random.Random, neighbor_radius: int):
        self.rng, self.events, self.checkpoints = rng, [], []
        self.neighbor_radius = neighbor_radius
        self.selected = [0] * len(PANES)
        self.hibernated: dict[int, int] = {}  # workspace: its hibernated p0 tab, woken by the round's visit

    def between(self, low: float, high: float) -> int:
        return round(low + self.rng.random() * (high - low))

    def add(self, t_ms: float, kind: str, payload: dict[str, Any]) -> None:
        self.events.append({"t_ms": round(t_ms), "kind": kind, "payload": payload})

    def key(self, t_ms: float, key_class: str, *, key_code: int | None = None,
            modifiers: tuple[str, ...] = ()) -> None:
        """A key press. Only the down: debug.key sends the down and the up, and play.py skips recorded ups."""
        down = {"phase": "down", "class": key_class, "modifiers": list(modifiers)}
        if key_code is not None:
            down["key_code"] = key_code
        self.add(t_ms, "key", down)

    def action(self, t_ms: float, action: str, target: str) -> None:
        self.add(t_ms, "action", {"id": action, "args": {"target": target}})

    def checkpoint(self, t_ms: float, name: str) -> None:
        self.checkpoints.append({"t_ms": round(t_ms), "name": name})

    def flick(self, t_ms: float, amplitude: float) -> int:
        """One trackpad flick on the shown page: SCROLL_HZ events with momentum, until under half a point."""
        x, y = PAGE_POINT
        index, dy = 0, amplitude
        while abs(dy) >= 0.5:
            self.add(t_ms + index * 1000 / SCROLL_HZ, "mouse",
                     {"phase": "scroll", "button": 0, "x": x, "y": y, "dy": round(dy, 2)})
            index, dy = index + 1, dy * SCROLL_DECAY
        return round(t_ms + index * 1000 / SCROLL_HZ)

    def omnibar(self, t_ms: float) -> float:
        """Cmd-L, a query of synthetic letters at about 7 keys/s (a Delete never takes a word's last letter, so the
        text is never empty), then Escape ESCAPES times once the popup's rows are there: each press takes one step
        of Chromium's OmniboxEditModel::OnEscapeKeyPressed (the popup, the edit, the focus; OmnibarReducer.escape),
        and the last one returns focus to the page. Never Return, so no page loads."""
        self.key(t_ms, "letter", key_code=KEY_L, modifiers=("cmd",))
        t, until, word = t_ms + self.between(350, 550), t_ms + self.between(1900, 2900), self.between(3, 8)
        letters = 0  # of the word being typed
        while t <= until:
            if word:
                self.key(t, "letter")
                word, letters = word - 1, letters + 1
            elif letters > 1 and self.rng.random() < 0.2:
                self.key(t, "named", key_code=KEY_DELETE)
                letters -= 1
            else:
                self.key(t, "space")
                word, letters = self.between(3, 8), 0
            t += self.between(95, 180)
        t += 450
        for _ in range(ESCAPES):
            t += self.between(200, 320)
            self.key(t, "named", key_code=KEY_ESCAPE)
        return t

    def ctrl_tab(self, t_ms: float, workspace: int, step: int) -> None:
        """Ctrl-Tab (nextSurface, STEP 1) or Ctrl-Shift-Tab (prevSurface, STEP -1) in the focused pane, p0: its
        next or previous tab, wrapping."""
        self.key(t_ms, "named", key_code=KEY_TAB, modifiers=("ctrl",) if step > 0 else ("ctrl", "shift"))
        self.selected[workspace] = (self.selected[workspace] + step) % len(PANES[workspace][0])

    def hibernate(self, t_ms: float, number: int) -> float:
        """Hibernates one Chromium tab of p0 in each of w1 to w5 that stays asleep until the round's visit wakes it
        with tab.focus: no tab the pane shows before then (its selected tab and the next one, which Ctrl-Tab shows)
        is within the awake-neighbor radius of it (browser.keepNeighborTabsAwake: a neighbor of the shown tab wakes
        at once, BrowserHibernation). Returns the time after the last one."""
        t = t_ms
        for workspace in range(1, len(PANES)):
            count, selected = len(PANES[workspace][0]), self.selected[workspace]
            shown = (selected, (selected + 1) % count)
            candidates = [tab for tab in range(CHROMIUM_PER_WORKSPACE)
                          if all(ring_distance(tab, other, count) > self.neighbor_radius for other in shown)]
            if not candidates:
                raise ValueError(f"w{workspace}: every Chromium tab is within {self.neighbor_radius} of tabs {shown}")
            tab = candidates[number % len(candidates)]
            self.action(t, "hibernateTab", _ref(workspace, 0, tab))
            self.hibernated[workspace] = tab
            t += self.between(250, 450)
        return t

    def visit(self, t_ms: float, number: int, workspace: int) -> float:
        """Cmd-<N> to the workspace (CONFIG's numbering), read (a flick), Ctrl-Tab and Ctrl-Shift-Tab, wake the
        hibernated tab with tab.focus, read again; omnibar typing in OMNIBAR_WORKSPACES, a WebKit tab of the second
        pane in WEBKIT_PANE_WORKSPACE. Ends with the visit's checkpoint; returns the time of the next visit."""
        digit = workspace + 1 + TOP_ITEMS[CONFIG["sidebar.numbering"]]
        self.key(t_ms, "digit", key_code=DIGIT_KEYS[digit - 1], modifiers=("cmd",))
        t = t_ms + 300
        if len(PANES[workspace]) > 1:
            self.action(t, "pane.focus", _ref(workspace, 0))  # Ctrl-Tab and the omnibar act on p0
        t = self.flick(t + self.between(600, 1000), -self.between(40, 72)) + self.between(400, 700)
        self.ctrl_tab(t, workspace, 1)
        t += self.between(700, 1000)
        self.ctrl_tab(t, workspace, -1)
        t += self.between(700, 1000)
        woken = self.hibernated.pop(workspace, None)
        if woken is not None:
            self.action(t, "tab.focus", _ref(workspace, 0, woken))
            self.selected[workspace] = woken
            t += self.between(900, 1300)
        t = self.flick(t, -self.between(40, 72)) + self.between(400, 700)
        if workspace in OMNIBAR_WORKSPACES:
            t = self.omnibar(t) + self.between(500, 800)
        if workspace == WEBKIT_PANE_WORKSPACE:
            self.action(t, "tab.focus", _ref(workspace, 1, number % len(PANES[workspace][1])))
            t += self.between(900, 1300)
        self.checkpoint(t, f"round-{number}-w{workspace}")
        return t + 300

    def round(self, number: int) -> None:
        base = number * ROUND_MS
        t = self.hibernate(base + 300, number) + 300
        self.checkpoint(t, f"round-{number}-hibernated")
        t += 300
        for workspace in VISIT_ORDER[number]:
            t = self.visit(t, number, workspace)
        end = base + ROUND_MS - 600
        while t + 1500 < end:  # reading in w0 until the next round
            t = self.flick(t + self.between(2000, 3500), self.between(-72, 48))


def input_track(root: Path = REPO_ROOT) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(events, checkpoints without digests), both in time order."""
    track = _Track(random.Random(SEED), setting(NEIGHBOR_RADIUS_KEY, root))
    track.checkpoint(0, "layout-imported")
    for number in range(ROUNDS):
        track.round(number)
    track.checkpoint(DURATION_MS, "end")
    events = sorted(track.events, key=lambda event: event["t_ms"])
    return events, track.checkpoints


# ---------------------------------------------------------------- the manifest

def file_ref(path: str, data: bytes) -> dict[str, Any]:
    return {"path": path, **manifest_module().blob_ref(data)}


def outputs(root: Path = REPO_ROOT, current: dict[str, Any] | None = None) -> dict[str, bytes]:
    """{repository path: bytes} of every file this script makes. CURRENT (the committed manifest, if any) gives the
    recorded fields to keep: status and each checkpoint's digests by name."""
    snapshot = session_io().check(layout())
    layout_bytes = session_io().canonical_bytes(snapshot)
    events, checkpoints = input_track(root)
    current = current or {}
    status = current.get("status", "planned")
    digests = {c["name"]: (c.get("focus"), c.get("surfaces")) for c in current.get("checkpoints", [])}
    manifest = {
        "schema": "cmux-perf-corpus-story/v1",
        "id": STORY,
        "tier": "T1",
        "status": status,
        **({"planned": PLANNED} if status == "planned" else {}),
        "description": DESCRIPTION,
        "owner": "PL-perf-lab",
        "duration_ms": DURATION_MS,
        "layout": {"snapshot": file_ref(LAYOUT_PATH, layout_bytes), "workspaces": len(snapshot["workspaces"])},
        "input": {"events": "@events"},
        "pty": [],
        "config": CONFIG,
        "web_archive": None,
        "agents": [],
        "checkpoints": [{**c, "focus": digests.get(c["name"], (None, None))[0],
                         "surfaces": digests.get(c["name"], (None, None))[1]} for c in checkpoints],
        "metrics": [{"name": rf"corpus\.browse_heavy\.{name}", "unit": METRIC_UNITS.get(name, "ms"),
                     "better": "lower"} for name in METRICS],
    }
    text = json.dumps(manifest, indent=2)
    lines = ",\n".join("      " + json.dumps(event, separators=(",", ":")) for event in events)
    text = text.replace('"@events"', f"[\n{lines}\n    ]", 1)
    return {MANIFEST_PATH: (text + "\n").encode("utf-8"), LAYOUT_PATH: layout_bytes}


def _current(root: Path) -> dict[str, Any] | None:
    manifest = root / MANIFEST_PATH
    return json.loads(manifest.read_text(encoding="utf-8")) if manifest.is_file() else None


def stale(root: Path = REPO_ROOT) -> list[str]:
    """The made files that are missing or differ from what this script makes now."""
    return [path for path, data in outputs(root, _current(root)).items()
            if not (root / path).is_file() or (root / path).read_bytes() != data]


def write(root: Path = REPO_ROOT) -> list[str]:
    written = []
    for path, data in outputs(root, _current(root)).items():
        target = root / path
        if target.is_file() and target.read_bytes() == data:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        written.append(path)
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_args(argv)
    if args.write:
        print("\n".join(write(args.root)) or "up to date")
        return 0
    problems = [f"{path}: not what browse_heavy.py makes; run python3 -I scripts/perf-lab/corpus/browse_heavy.py "
                "--write" for path in stale(args.root)]
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
