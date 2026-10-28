#!/usr/bin/env python3
"""The switch-at-scale fixture (Lawrence 2026-10-28: "need to make sure changing spaces and screens, when there's a lot of
workspaces, groups, tabs, terminals, panes etc, is extremely fast"; /Users/lawrence/fun/wt/handoff/switch-scale.md).

A generated layout snapshot, the same bytes on every host and Python 3.9+ (splitmix64 as story_kit's, fixed seed):

  * N workspaces (1,000 for the full fixture; 10 and 100 for the curve) in spaces and groups: 10 spaces and 40 groups at
    1,000 (min(10, max(2, N/100)) spaces, max(spaces, N/25) groups), each group in one space (round robin), each
    workspace in space `index % spaces`, 4 of 5 of them in a group of their space, the rest loose.
  * each workspace: 2-6 screens, each screen 4-12 panes (1-4 side by side columns of stacked panes), each pane 2-8 tabs
    of mixed kinds (terminal 50 %, Chromium 20 %, WebKit 15 %, agent chat 15 %), a selected tab, an active screen and a
    focused pane. Half of the terminals produce output (`busy`). Every terminal has `scrollback_lines` of history.
  * Home (the home workspace) and 3 windows on 2 displays (window 0 and 1 on display 0, window 2 on display 1), each on
    its own space and that space's first workspace.

Workspace `i` has the same shape at every N (its numbers come from its own seed), so the 10-workspace fixture is the
first 10 workspaces of the 1,000-workspace one: the curve changes only the count.

The format is cmux-layout-snapshot/v1 (session_io.py) grown by what v1 refuses (several screens, spaces, groups,
windows): no id, title, name, URL, cwd or text, only counts, indexes, flags and the v1 tab kinds. `validate` refuses
any other key. Pane trees are v1 trees ({"split": "right"|"down", "children": [...]} or {"tabs": [...], "selected": k}).

  python3 -I scripts/perf-lab/corpus/stories/switch_scale.py write --workspaces 1000 --out /tmp/switch-scale-1000.json
  python3 -I scripts/perf-lab/corpus/stories/switch_scale.py summary --workspaces 1000
  python3 -I scripts/perf-lab/corpus/stories/switch_scale.py digest /tmp/switch-scale-1000.json

`write` prints one line `SWITCH-SCALE-FIXTURE {json}` (the summary with the file's sha256, which is the layout's
digest). The in-process bench (SwitchScaleBench.swift, story swift-switch-scale) runs `write` itself when
CMUX_SWITCH_SCALE_LAYOUT names no file; the app bench (switch-scale-bench.py, story switch-scale) imports the same file.
Stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

SCHEMA = "cmux-layout-snapshot/v2"
SEED = 0x5C0FE5CA1E2026
FULL_WORKSPACES = 1000
FULL_SPACES = 10
FULL_GROUPS = 40
SCREENS = (2, 6)
PANES = (4, 12)
TABS = (2, 8)
MAX_COLUMNS = 4
# Tab kinds by weight (out of 20): terminal 10, Chromium 4, WebKit 3, agent chat 3.
KIND_WHEEL = ("terminal",) * 10 + ("chromium",) * 4 + ("webkit",) * 3 + ("chat",) * 3
KINDS = frozenset(KIND_WHEEL)
SCROLLBACK_LINES = 10_000
WINDOW = [1600, 1000]
WINDOWS = 3
DISPLAYS = 2
GROUPED_OF_FIVE = 4


class Rng:
    """splitmix64, as story_kit.Rng: the same numbers on every Python (also the macOS command line tools' 3.9, which
    the in-process bench runs), so the fixture and its digest never move."""

    MASK = (1 << 64) - 1

    def __init__(self, seed: int):
        self.state = seed & self.MASK

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & self.MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & self.MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & self.MASK
        return z ^ (z >> 31)

    def between(self, low: int, high: int) -> int:
        return low + self.next() % (high - low + 1)

    def choice(self, items):
        return items[self.next() % len(items)]


def spaces_for(workspaces: int) -> int:
    return min(FULL_SPACES, max(2, workspaces // 100))


def groups_for(workspaces: int) -> int:
    return max(spaces_for(workspaces), workspaces * FULL_GROUPS // FULL_WORKSPACES)


def _columns(rng, panes: list) -> dict:
    """`panes` (leaves) as 1-4 side by side columns of stacked panes, flattened as v1 wants."""
    count = rng.between(1, min(MAX_COLUMNS, len(panes)))
    columns = [[] for _ in range(count)]
    for index, pane in enumerate(panes):
        columns[index % count].append(pane)
    nodes = [column[0] if len(column) == 1 else {"split": "down", "children": column} for column in columns]
    return nodes[0] if len(nodes) == 1 else {"split": "right", "children": nodes}


def workspace(index: int) -> dict:
    """Workspace `index`'s shape: the same at every fixture size."""
    rng = Rng(SEED ^ ((index + 1) * 0x9E3779B97F4A7C15))
    screens, busy = [], []
    for screen_index in range(rng.between(*SCREENS)):
        made, flags = [], []
        for _ in range(rng.between(*PANES)):
            tabs = [rng.choice(KIND_WHEEL) for _ in range(rng.between(*TABS))]
            flags.append([kind == "terminal" and rng.next() % 2 == 0 for kind in tabs])
            made.append({"tabs": tabs, "selected": rng.between(0, len(tabs) - 1)})
        tree = _columns(rng, made)
        # Busy addresses are in the tree's leaf order (left to right, top to bottom), as v1's are.
        made_index = {id(leaf): index for index, leaf in enumerate(made)}
        for pane_index, leaf in enumerate(leaves(tree)):
            busy += [[screen_index, pane_index, t] for t, flag in enumerate(flags[made_index[id(leaf)]]) if flag]
        screens.append({"tree": tree, "focused_pane": rng.between(0, len(made) - 1)})
    return {"screens": screens, "active_screen": rng.between(0, len(screens) - 1), "busy": busy}


def build(workspaces: int) -> dict:
    if workspaces < 1:
        raise ValueError("a fixture has at least one workspace")
    spaces, groups = spaces_for(workspaces), groups_for(workspaces)
    by_space = {space: [g for g in range(groups) if g % spaces == space] for space in range(spaces)}
    placement = Rng(SEED)
    out = []
    for index in range(workspaces):
        space = index % spaces
        shape = workspace(index)
        roll = placement.next()
        grouped = roll % 5 < GROUPED_OF_FIVE and by_space[space]
        shape["space"] = space
        shape["group"] = by_space[space][(roll // 5) % len(by_space[space])] if grouped else None
        out.append(shape)
    first = {space: next(i for i in range(workspaces) if i % spaces == space) for space in range(spaces)}
    windows = [{"display": 0 if w < WINDOWS - 1 else min(1, DISPLAYS - 1), "space": w % spaces,
                "workspace": first[w % spaces]} for w in range(WINDOWS)]
    return {"schema": SCHEMA, "window": list(WINDOW), "spaces": spaces,
            "groups": [{"space": g % spaces} for g in range(groups)], "workspaces": out, "windows": windows,
            "home": True, "scrollback_lines": SCROLLBACK_LINES}


def leaves(node: dict) -> list:
    if "tabs" in node:
        return [node]
    return [leaf for child in node["children"] for leaf in leaves(child)]


def _index(value, size) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value < size


def _tree_problems(node, where: str) -> list:
    if not isinstance(node, dict):
        return [f"{where}: a node is an object"]
    if "tabs" in node:
        problems = [f"{where}: unknown key {key!r}" for key in sorted(set(node) - {"tabs", "selected"})]
        tabs = node.get("tabs")
        if not isinstance(tabs, list) or not tabs or any(kind not in KINDS for kind in tabs):
            return problems + [f"{where}: tabs is a non-empty list of {sorted(KINDS)}"]
        if not _index(node.get("selected"), len(tabs)):
            problems.append(f"{where}: selected is a tab index")
        return problems
    problems = [f"{where}: unknown key {key!r}" for key in sorted(set(node) - {"split", "children"})]
    if node.get("split") not in ("right", "down"):
        problems.append(f"{where}: split is right or down")
    children = node.get("children")
    if not isinstance(children, list) or len(children) < 2:
        return problems + [f"{where}: a split has at least two children"]
    for index, child in enumerate(children):
        problems += _tree_problems(child, f"{where}.children[{index}]")
        if isinstance(child, dict) and child.get("split") == node.get("split"):
            problems.append(f"{where}.children[{index}]: a split of the same direction is flattened into its parent")
    return problems


def validate(snapshot) -> list:
    """Every problem of `snapshot`; only the format's keys, counts, indexes, flags and kinds are allowed."""
    if not isinstance(snapshot, dict):
        return ["a snapshot is an object"]
    allowed = {"schema", "window", "spaces", "groups", "workspaces", "windows", "home", "scrollback_lines"}
    problems = [f"unknown key {key!r}" for key in sorted(set(snapshot) - allowed)]
    if snapshot.get("schema") != SCHEMA:
        problems.append(f"schema is {SCHEMA}")
    spaces = snapshot.get("spaces")
    if not _index(spaces, 1000) or spaces < 1:
        return problems + ["spaces is a count"]
    groups = snapshot.get("groups")
    if not isinstance(groups, list) or any(not isinstance(g, dict) or set(g) != {"space"} or not _index(g["space"], spaces)
                                           for g in groups):
        problems.append("groups is a list of {space}")
        groups = []
    workspaces = snapshot.get("workspaces")
    if not isinstance(workspaces, list) or not workspaces:
        return problems + ["workspaces is a non-empty list"]
    for index, ws in enumerate(workspaces):
        where = f"workspaces[{index}]"
        if not isinstance(ws, dict):
            problems.append(f"{where}: a workspace is an object")
            continue
        problems += [f"{where}: unknown key {key!r}" for key in sorted(set(ws) - {"screens", "active_screen", "busy", "space", "group"})]
        if not _index(ws.get("space"), spaces):
            problems.append(f"{where}: space is a space index")
        group = ws.get("group")
        if group is not None and not (_index(group, len(groups)) and groups[group]["space"] == ws.get("space")):
            problems.append(f"{where}: group is null or a group index of its space")
        screens = ws.get("screens")
        if not isinstance(screens, list) or not screens:
            problems.append(f"{where}: screens is a non-empty list")
            continue
        panes_by_screen = []
        for s, screen in enumerate(screens):
            if not isinstance(screen, dict) or set(screen) != {"tree", "focused_pane"}:
                problems.append(f"{where}.screens[{s}]: a screen is {{tree, focused_pane}}")
                panes_by_screen.append([])
                continue
            tree_problems = _tree_problems(screen["tree"], f"{where}.screens[{s}].tree")
            problems += tree_problems
            panes = [] if tree_problems else leaves(screen["tree"])
            panes_by_screen.append(panes)
            if panes and not _index(screen["focused_pane"], len(panes)):
                problems.append(f"{where}.screens[{s}]: focused_pane is a pane index")
        if not _index(ws.get("active_screen"), len(screens)):
            problems.append(f"{where}: active_screen is a screen index")
        busy = ws.get("busy")
        if not isinstance(busy, list):
            problems.append(f"{where}: busy is a list of [screen, pane, tab]")
            continue
        for entry in busy:
            ok = isinstance(entry, list) and len(entry) == 3 and all(_index(v, 1 << 20) for v in entry)
            panes = panes_by_screen[entry[0]] if ok and entry[0] < len(panes_by_screen) else []
            if not (ok and _index(entry[1], len(panes)) and _index(entry[2], len(panes[entry[1]]["tabs"]))
                    and panes[entry[1]]["tabs"][entry[2]] == "terminal"):
                problems.append(f"{where}: busy entry {str(entry)[:40]} is not a terminal tab")
    windows = snapshot.get("windows")
    if not isinstance(windows, list) or not windows:
        problems.append("windows is a non-empty list")
    else:
        for index, window in enumerate(windows):
            if not (isinstance(window, dict) and set(window) == {"display", "space", "workspace"}
                    and _index(window["display"], 16) and _index(window["space"], spaces)
                    and _index(window["workspace"], len(workspaces))):
                problems.append(f"windows[{index}] is {{display, space, workspace}} indexes")
    if not isinstance(snapshot.get("home"), bool):
        problems.append("home is true or false")
    if not _index(snapshot.get("scrollback_lines"), 1 << 24):
        problems.append("scrollback_lines is a count")
    window = snapshot.get("window")
    if not (isinstance(window, list) and len(window) == 2 and all(_index(v, 100_000) and v > 0 for v in window)):
        problems.append("window is [width, height] in points")
    return problems


def canonical_bytes(snapshot: dict) -> bytes:
    return json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode()


def summary(snapshot: dict) -> dict:
    screens = [s for ws in snapshot["workspaces"] for s in ws["screens"]]
    panes = [p for s in screens for p in leaves(s["tree"])]
    tabs = [k for p in panes for k in p["tabs"]]
    by_kind = {kind: tabs.count(kind) for kind in sorted(KINDS)}
    return {"workspaces": len(snapshot["workspaces"]), "spaces": snapshot["spaces"], "groups": len(snapshot["groups"]),
            "screens": len(screens), "panes": len(panes), "tabs": len(tabs), "tabs_by_kind": by_kind,
            "busy_terminals": sum(len(ws["busy"]) for ws in snapshot["workspaces"]),
            "windows": len(snapshot["windows"]), "displays": len({w["display"] for w in snapshot["windows"]}),
            "home": snapshot["home"], "scrollback_lines": snapshot["scrollback_lines"],
            "digest": hashlib.sha256(canonical_bytes(snapshot)).hexdigest()}


def write(snapshot: dict, path: Path) -> dict:
    problems = validate(snapshot)
    if problems:
        raise ValueError("invalid switch-scale fixture: " + "; ".join(problems[:8]))
    path.write_bytes(canonical_bytes(snapshot))
    return summary(snapshot)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    w = commands.add_parser("write", help="write the fixture of N workspaces")
    w.add_argument("--workspaces", type=int, default=FULL_WORKSPACES)
    w.add_argument("--out", required=True)
    s = commands.add_parser("summary", help="print the counts of the fixture of N workspaces")
    s.add_argument("--workspaces", type=int, default=FULL_WORKSPACES)
    d = commands.add_parser("digest", help="check a fixture file and print its digest")
    d.add_argument("path")
    args = parser.parse_args(argv)
    if args.command == "write":
        print("SWITCH-SCALE-FIXTURE " + json.dumps(write(build(args.workspaces), Path(args.out)), sort_keys=True))
    elif args.command == "summary":
        print(json.dumps(summary(build(args.workspaces)), sort_keys=True))
    else:
        snapshot = json.loads(Path(args.path).read_text())
        problems = validate(snapshot)
        if problems:
            print("invalid: " + "; ".join(problems[:8]), file=sys.stderr)
            return 1
        print(summary(snapshot)["digest"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
