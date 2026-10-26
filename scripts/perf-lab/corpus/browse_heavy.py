#!/usr/bin/env python3
"""The browse-heavy corpus story's scripted parts (p12-perf-process.md 3.8, task 119).

    python3 -I scripts/perf-lab/corpus/browse_heavy.py --check   # the committed files are what this script makes
    python3 -I scripts/perf-lab/corpus/browse_heavy.py --write   # makes them again

browse-heavy is a scripted story, as Chromium's multi-tab system_health story is: code opens a fixed list of
public pages in tabs and switches between them (tools/perf/page_sets/system_health/multi_tab_stories.py,
MultiTabTypical24Story, and tools/perf/page_sets/system_health/system_health_story.py for the WPR archive),
and nothing comes from a person's session. This script makes, deterministically (a seeded random.Random, read
only through random()):

  perf-corpus/browse-heavy/layout.json  the layout snapshot (session_io.py, task 111): 6 workspaces with 5
                                        Chromium tabs each (30, in pane p0), WebKit tabs in w1, w3 (its own
                                        pane) and w5, and a terminal beside the tabs of w0
  perf-corpus/browse-heavy/pages.urls   the 30 public pages for wpr.py record and verify (task 113): line N is
                                        the page of the Nth Chromium tab in reference order (CHROMIUM_TABS)
  perf-corpus/browse-heavy.json         layout, input track and checkpoints. The input track runs ROUNDS rounds:
                                        hibernate one background Chromium tab in each of w1 to w5 (hibernateTab),
                                        then visit every workspace with Cmd-1 to Cmd-6 (each visit: a trackpad
                                        flick on the page, Ctrl-Tab twice, then tab.focus on the tab hibernated
                                        at the round's start, which wakes it); the visits of w1 and w4 type in
                                        the omnibar (Cmd-L, synthetic letters, Down, Escape) and the visit
                                        of w3 shows one of its WebKit tabs

No key goes where its text could run or load a page: the omnibar is always left with Escape, never Return, so
nothing navigates outside the Web Page Replay archive; the terminal of w0 gets no key. The fields a lab host
records (web_archive, checkpoint digests, status) are kept from the committed manifest.

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
PAGES_PATH = f"perf-corpus/{STORY}/pages.urls"
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

# macOS virtual key codes (play.py KEY_NAMES): the keys that are not typed text.
DIGIT_KEYS = (18, 19, 20, 21, 23, 22)  # 1 to 6: Cmd-N is selectWorkspaceByNumber
KEY_L, KEY_TAB, KEY_RETURN, KEY_ESCAPE, KEY_DOWN, KEY_DELETE = 37, 48, 36, 53, 125, 51
ESCAPES = 4  # the steps of OmnibarReducer.escape from an arrowed row to the page

METRICS = ("tab_switch_to_frame", "switch_to_frame", "wake_to_frame", "omnibar_key_to_frame", "key_to_frame",
           "dropped_frames", "footprint")
METRIC_UNITS = {"dropped_frames": "count", "footprint": "bytes"}

PLANNED = ("Scripted by scripts/perf-lab/corpus/browse_heavy.py (task 119). A lab host adds the Web Page Replay "
           "archive and spki (wpr.py record --urls perf-corpus/browse-heavy/pages.urls, task 113; wpr.py verify "
           "--tabs 30 shows 0 network misses) and the checkpoint digests of a recording replay (task 116).")
DESCRIPTION = ("30 Chromium tabs from Web Page Replay over 6 workspaces and 4 WebKit tabs: Cmd-1 to Cmd-6 "
               "workspace switches, Ctrl-Tab and tab clicks, background tabs hibernated and woken by showing them, "
               "omnibar typing closed with Escape, in 3 rounds of 60 s.")


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


def wpr():
    return _load("perf_lab_corpus_wpr", HERE / "wpr.py")


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
    """The references of the Chromium tabs in order (workspace, pane, tab): line N of PAGES_PATH is tab N's page."""
    return [f"@w{w}.p{p}.t{t}" for w, panes in enumerate(PANES) for p, kinds in enumerate(panes)
            for t, kind in enumerate(kinds) if kind == "chromium"]


# ---------------------------------------------------------------- input track

def _ref(workspace: int, pane: int, tab: int | None = None) -> str:
    return f"@w{workspace}.p{pane}" + ("" if tab is None else f".t{tab}")


class _Track:
    """The input track and the state it leaves: each workspace's selected tab in p0 and the hibernated tabs."""

    def __init__(self, rng: random.Random):
        self.rng, self.events, self.checkpoints = rng, [], []
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
        """Cmd-L, a query of synthetic letters at about 7 keys/s, Down to a suggestion, then Escape ESCAPES times:
        each press takes one step of Chromium's OmniboxEditModel::OnEscapeKeyPressed (the arrowed row, the popup,
        the edit, the focus; OmnibarReducer.escape), so the omnibar is left whatever its popup showed. Never
        Return, so no page outside the archive loads."""
        self.key(t_ms, "letter", key_code=KEY_L, modifiers=("cmd",))
        t, until, word = t_ms + self.between(350, 550), t_ms + self.between(1900, 2900), self.between(3, 8)
        while t <= until:
            if word:
                self.key(t, "letter")
                word -= 1
            elif self.rng.random() < 0.2:
                self.key(t, "named", key_code=KEY_DELETE)
            else:
                self.key(t, "space")
                word = self.between(3, 8)
            t += self.between(95, 180)
        self.key(t + 250, "named", key_code=KEY_DOWN)
        t += 450
        for _ in range(ESCAPES):
            t += self.between(200, 320)
            self.key(t, "named", key_code=KEY_ESCAPE)
        return t

    def ctrl_tab(self, t_ms: float, workspace: int) -> None:
        """Ctrl-Tab (nextSurface) in the focused pane, p0: its next tab, wrapping."""
        self.key(t_ms, "named", key_code=KEY_TAB, modifiers=("ctrl",))
        self.selected[workspace] = (self.selected[workspace] + 1) % len(PANES[workspace][0])

    def hibernate(self, t_ms: float, number: int) -> float:
        """Hibernates one Chromium tab of p0 in each of w1 to w5 that the round's visit shows only by tab.focus:
        not the selected tab, nor the two Ctrl-Tab passes over first. Returns the time after the last one."""
        t = t_ms
        for workspace in range(1, len(PANES)):
            count, selected = len(PANES[workspace][0]), self.selected[workspace]
            passed = {selected, (selected + 1) % count, (selected + 2) % count}
            candidates = [tab for tab in range(CHROMIUM_PER_WORKSPACE) if tab not in passed]
            tab = candidates[number % len(candidates)]
            self.action(t, "hibernateTab", _ref(workspace, 0, tab))
            self.hibernated[workspace] = tab
            t += self.between(250, 450)
        return t

    def visit(self, t_ms: float, number: int, workspace: int) -> float:
        """Cmd-<N> to the workspace, read (a flick), Ctrl-Tab twice, wake the hibernated tab with tab.focus, read
        again; omnibar typing in OMNIBAR_WORKSPACES, a WebKit tab of the second pane in WEBKIT_PANE_WORKSPACE.
        Ends with the visit's checkpoint; returns the time of the next visit."""
        self.key(t_ms, "digit", key_code=DIGIT_KEYS[workspace], modifiers=("cmd",))
        t = t_ms + 300
        if len(PANES[workspace]) > 1:
            self.action(t, "pane.focus", _ref(workspace, 0))  # Ctrl-Tab and the omnibar act on p0
        t = self.flick(t + self.between(600, 1000), -self.between(40, 72)) + self.between(400, 700)
        self.ctrl_tab(t, workspace)
        t += self.between(700, 1000)
        self.ctrl_tab(t, workspace)
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


def input_track() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(events, checkpoints without digests), both in time order."""
    track = _Track(random.Random(SEED))
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
    """{repository path: bytes} of every file this script makes, but PAGES_PATH, which a person keeps. CURRENT
    (the committed manifest, if any) gives the recorded fields to keep: web_archive, status and each checkpoint's
    digests by name."""
    snapshot = session_io().check(layout())
    layout_bytes = session_io().canonical_bytes(snapshot)
    events, checkpoints = input_track()
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
        "web_archive": current.get("web_archive") or {"wprgo": None, "spki": None},
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


def pages_problems(root: Path = REPO_ROOT) -> list[str]:
    """Why PAGES_PATH is not one page per Chromium tab (wpr.read_urls refuses a URL twice), with no DNS lookup:
    wpr.py record checks each page's addresses on the lab host."""
    path = root / PAGES_PATH
    if not path.is_file():
        return [f"{PAGES_PATH}: missing"]
    try:
        urls = wpr().read_urls(path.read_text(encoding="utf-8"))
    except wpr().WprError as error:
        return [f"{PAGES_PATH}: {error}"]
    problems = [f"{PAGES_PATH}: {len(urls)} pages for {len(chromium_tabs())} Chromium tabs"] \
        if len(urls) != len(chromium_tabs()) else []
    return problems + [f"{PAGES_PATH}: {problem}" for url in urls
                       if (problem := wpr().public_url_problem(url, resolver=lambda host: ["8.8.8.8"]))]


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
                "--write" for path in stale(args.root)] + pages_problems(args.root)
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
