#!/usr/bin/env python3
"""Layout snapshots for the perf corpus (p12-perf-process.md 3.8, task p12-perf-process-111).

A layout snapshot is the shape of a session and nothing a person typed: the window size, each workspace's split
tree (side by side or stacked, in order), each pane's tab kinds in order and which one is selected, the shown
workspace, its focused pane and the terminals that run the builder's busy loop. No id, title, name, URL, cwd,
path or terminal text is in it: tabs are kinds (terminal, chromium, webkit, browser, chat, page:<name>) and every
other value is a count, an index or a flag. `validate` refuses any other key or value, so a recorder bug cannot
put text in a corpus blob.

  export: read the tree over the socket (`snapshot.get`, and the laid-out `debug.layers` pane frames and engines
          of each workspace with more than one pane or a selected browser tab, shown one at a time, then the shown
          workspace and focused pane are put back). Zoomed panes, docked panes and several screens are refused.
  import: rebuild it in a freshly launched app with perf-stress-session.py's own action calls (`split_chain`,
          `equalize`, `fill_pane`, `select_tab`, `make_busy`), then export again: the digest must match.

The digest (`digest`) is the sha256 of the snapshot's canonical JSON, which is exactly the bytes `write` puts in
the file (no trailing newline): it is the corpus manifest's layout blob id (manifest.py's sha256 of the file).
Splits come back even (`equalizeSplits`): a snapshot with uneven split sizes is refused at import, since
actions cannot set a split's ratio.

  python3 scripts/perf-lab/corpus/session_io.py export --socket /tmp/cmux-debug-<tag>.sock --out layout.json
  python3 scripts/perf-lab/corpus/session_io.py import --app "$NX_APP" --layout layout.json [--keep]
  python3 scripts/perf-lab/corpus/session_io.py digest layout.json
  python3 scripts/perf-lab/corpus/session_io.py stress-roundtrip --app "$NX_APP" --out "$NX_ARTIFACTS"

stress-roundtrip is the lab-host acceptance: it builds STRESS in one launch, exports it, imports the snapshot in
a second fresh launch and prints `LAYOUT-ROUNDTRIP {json}` with both digests.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import signal
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
STRESS_PATH = ROOT / "scripts" / "cmux-next" / "perf-stress-session.py"

SCHEMA = "cmux-layout-snapshot/v1"
SPLITS = {"right": "splitRight", "down": "splitDown"}
BROWSER_KINDS = {"chromium", "webkit", "browser"}
PLAIN_KINDS = {"terminal", "chat"} | BROWSER_KINDS
PAGE_KIND = re.compile(r"^page:[a-z][a-z0-9-]{0,31}$")  # an app page id (new-tab), never a title
IMPORTABLE_PAGES = {"page:new-tab"}  # newTab.page; other pages have no action that opens them in a pane
# Two pane frames closer than this along an axis (points) touch: a divider is a few points wide.
CUT_TOLERANCE = 4.0
# The widest space two neighbor panes may leave between them (points): the divider hit width tunable goes to 24
# (ChromeTunables.dividerHitWidth). A wider space is area no pane covers: a layout pass that has not run.
GAP_LIMIT = 24.0
# How long a shown workspace may take to lay out its panes before export gives up (seconds).
SETTLE_S = 10.0


class LayoutSnapshotError(RuntimeError):
    """The session cannot be exported, the snapshot is invalid or cannot be imported, or a round trip differs."""


def load_stress():
    """perf-stress-session.py as a module (its file name is not an import name)."""
    name = "perf_stress_session"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, STRESS_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# The snapshot: canonical bytes, digest, validation.

def canonical_bytes(snapshot) -> bytes:
    return json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode()


def digest(snapshot) -> str:
    return hashlib.sha256(canonical_bytes(snapshot)).hexdigest()


def leaves(node):
    """The leaf nodes of `node` in order: left to right, top to bottom, depth first."""
    if "tabs" in node:
        return [node]
    return [leaf for child in node["children"] for leaf in leaves(child)]


def _index(value, size):
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value < size


def _node_problems(node, where):
    if not isinstance(node, dict):
        return [f"{where}: a node is an object"]
    if "tabs" in node:
        problems = [f"{where}: unknown key {key!r}" for key in sorted(set(node) - {"tabs", "selected"})]
        tabs = node.get("tabs")
        if not isinstance(tabs, list) or not tabs:
            return problems + [f"{where}: a pane has at least one tab"]
        for index, kind in enumerate(tabs):
            if not isinstance(kind, str) or not (kind in PLAIN_KINDS or PAGE_KIND.match(kind)):
                problems.append(f"{where}.tabs[{index}]: {str(kind)[:40]!r} is not a tab kind")
        if not _index(node.get("selected"), len(tabs)):
            problems.append(f"{where}: selected is a tab index")
        return problems
    problems = [f"{where}: unknown key {key!r}" for key in sorted(set(node) - {"split", "children"})]
    if not isinstance(node.get("split"), str) or node["split"] not in SPLITS:
        problems.append(f"{where}: split is right or down")
    children = node.get("children")
    if not isinstance(children, list) or len(children) < 2:
        return problems + [f"{where}: a split has at least two children"]
    for index, child in enumerate(children):
        problems += _node_problems(child, f"{where}.children[{index}]")
        if isinstance(child, dict) and child.get("split") is not None and child.get("split") == node.get("split"):
            problems.append(f"{where}.children[{index}]: a split of the same direction is flattened into its parent")
    return problems


def validate(snapshot):
    """Every problem of `snapshot` (an empty list when it is valid). Only the keys and values of the format are
    allowed: any other key, any text where a kind, index or flag belongs, is refused."""
    if not isinstance(snapshot, dict):
        return ["a snapshot is an object"]
    allowed = {"schema", "window", "workspaces", "shown", "focused_pane", "busy"}
    problems = [f"unknown key {key!r}" for key in sorted(set(snapshot) - allowed)]
    if snapshot.get("schema") != SCHEMA:
        problems.append(f"schema is {SCHEMA}")
    window = snapshot.get("window")
    if not (isinstance(window, list) and len(window) == 2 and all(_index(v, 100_000) and v > 0 for v in window)):
        problems.append("window is [width, height] in points")
    workspaces = snapshot.get("workspaces")
    if not isinstance(workspaces, list) or not workspaces:
        return problems + ["workspaces is a non-empty list"]
    trees = []
    for index, workspace in enumerate(workspaces):
        where = f"workspaces[{index}]"
        if not isinstance(workspace, dict):
            problems.append(f"{where}: a workspace is an object")
            trees.append(None)
            continue
        problems += [f"{where}: unknown key {key!r}" for key in sorted(set(workspace) - {"tree", "even"})]
        if not isinstance(workspace.get("even"), bool):
            problems.append(f"{where}: even is true or false")
        node_problems = _node_problems(workspace.get("tree"), f"{where}.tree")
        problems += node_problems
        trees.append(None if node_problems else workspace["tree"])
    if not _index(snapshot.get("shown"), len(workspaces)):
        problems.append("shown is a workspace index")
    focused = snapshot.get("focused_pane")
    shown_tree = trees[snapshot["shown"]] if _index(snapshot.get("shown"), len(workspaces)) else None
    if focused is not None and shown_tree is not None and not _index(focused, len(leaves(shown_tree))):
        problems.append("focused_pane is null or a pane index of the shown workspace")
    busy = snapshot.get("busy")
    if not isinstance(busy, list):
        return problems + ["busy is a list of [workspace, pane, tab]"]
    addresses = []  # the entries that are [int, int, int], for the duplicate check
    for entry in busy:
        if not (isinstance(entry, list) and len(entry) == 3 and all(_index(v, 1 << 31) for v in entry)
                and _index(entry[0], len(workspaces))):
            problems.append(f"busy entry {str(entry)[:40]} is not [workspace, pane, tab]")
            continue
        addresses.append(tuple(entry))
        tree = trees[entry[0]]
        panes = leaves(tree) if tree else []
        if tree and not (_index(entry[1], len(panes)) and _index(entry[2], len(panes[entry[1]]["tabs"]))
                         and panes[entry[1]]["tabs"][entry[2]] == "terminal"):
            problems.append(f"busy entry {entry} is not a terminal tab")
    if len(set(addresses)) != len(addresses):
        problems.append("busy has a terminal twice")
    return problems


def check(snapshot):
    problems = validate(snapshot)
    if problems:
        raise LayoutSnapshotError("invalid layout snapshot: " + "; ".join(problems[:8]))
    return snapshot


def read(path):
    with open(path) as handle:
        return check(json.load(handle))


def write(snapshot, path):
    """Writes `snapshot`'s canonical bytes to `path`, nothing else, and returns their sha256: the digest is the
    file's sha256, the corpus blob id."""
    data = canonical_bytes(check(snapshot))
    with open(path, "wb") as handle:
        handle.write(data)
    return hashlib.sha256(data).hexdigest()


# Export.

def tree_from_frames(frames, leaf):
    """The split tree of pane `frames` ({pane: [x, y, w, h]}, window points with the bottom-left origin of
    `debug.layers`): the panes side by side are a `right` split (left to right), stacked ones a `down` split
    (top to bottom), same-direction splits flattened. `leaf(pane)` gives each pane's node. Returns
    (tree, even, panes in leaf order); `even` is True when every split's children share it evenly
    (perf-stress-session.py's EVEN_TOLERANCE). Raises LayoutSnapshotError for frames no split tree makes: a
    frame of zero width or height, two frames that overlap, or frames that leave part of the layout area (their
    bounding box) uncovered by more than a divider (GAP_LIMIT)."""
    tolerance = load_stress().EVEN_TOLERANCE
    axes = ("right", "down")

    def spans(item, axis):
        _, (x, y, w, h) = item
        return (x, x + w) if axis == "right" else (-(y + h), -y)  # down: top first

    def extent(items, axis):
        return min(spans(i, axis)[0] for i in items), max(spans(i, axis)[1] for i in items)

    def overlap(a, b, axis):
        (a0, a1), (b0, b1) = spans(a, axis), spans(b, axis)
        return min(a1, b1) - max(a0, b0)

    def groups(items, axis):
        made, end = [], None
        for item in sorted(items, key=lambda i: spans(i, axis)):
            start, stop = spans(item, axis)
            if made and start < end - CUT_TOLERANCE:
                made[-1].append(item)
                end = max(end, stop)
            else:
                made.append([item])
                end = stop
        return made

    def build(items, rect):
        """The node of `items`, which must tile `rect` ({axis: (start, stop)}) up to the dividers."""
        if len(items) == 1:
            pane = items[0][0]
            for axis in axes:
                start, stop = spans(items[0], axis)
                if abs(start - rect[axis][0]) > CUT_TOLERANCE or abs(stop - rect[axis][1]) > CUT_TOLERANCE:
                    raise LayoutSnapshotError(f"pane {pane} does not fill its part of the layout area: the pane frames "
                                              "leave area no pane covers")
            return leaf(pane), True, [pane]
        for axis in axes:
            parts = groups(items, axis)
            if len(parts) < 2:
                continue
            cross = "down" if axis == "right" else "right"
            bounds = [extent(part, axis) for part in parts]
            gaps = [bounds[0][0] - rect[axis][0], rect[axis][1] - bounds[-1][1]]
            gaps += [after[0] - before[1] for before, after in zip(bounds, bounds[1:])]
            if max(gaps) > GAP_LIMIT or abs(gaps[0]) > CUT_TOLERANCE or abs(gaps[1]) > CUT_TOLERANCE:
                raise LayoutSnapshotError(f"pane frames {sorted(p for p, _ in items)} leave {max(gaps):.0f} pt of the "
                                          "layout area that no pane covers")
            children, even, order = [], True, []
            for part, bound in zip(parts, bounds):
                node, part_even, part_order = build(part, {axis: bound, cross: rect[cross]})
                children.append(node)
                even = even and part_even
                order += part_order
            sizes = [stop - start for start, stop in bounds]
            even = even and max(sizes) - min(sizes) <= tolerance * max(sizes)
            return {"split": axis, "children": children}, even, order
        raise LayoutSnapshotError(f"pane frames {sorted(p for p, _ in items)} are not a split tree")

    if not frames:
        raise LayoutSnapshotError("no pane frames")
    items = sorted(frames.items())
    for pane, frame in items:
        if not (isinstance(frame, (list, tuple)) and len(frame) == 4
                and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in frame)):
            raise LayoutSnapshotError(f"pane {pane}: frame {str(frame)[:60]} is not [x, y, width, height]")
        if frame[2] < 1 or frame[3] < 1:
            raise LayoutSnapshotError(f"pane {pane}: frame {frame} has no area (its layout pass has not run)")
    for index, a in enumerate(items):
        for b in items[index + 1:]:
            if all(overlap(a, b, axis) > CUT_TOLERANCE for axis in axes):
                raise LayoutSnapshotError(f"pane frames of {a[0]} and {b[0]} overlap")
    return build(items, {axis: extent(items, axis) for axis in axes})


def builder_hints(builder):
    """What a perf-stress-session builder that made the session knows and the topology does not say: the
    engine each browser tab was asked for ({tab: chromium|webkit|browser}, browser for the app's default) and
    its busy terminals."""
    if builder is None:
        return {}, []
    engines = {tab: kind for asked in builder.made.values() for kind, tab, _ in asked if tab and kind in BROWSER_KINDS}
    return engines, list(getattr(builder, "busy", []))


def layers_window(rpc, window_key):
    layers = rpc("debug.layers")
    windows = (layers.get("windows") or []) if isinstance(layers, dict) else []
    return next((w for w in windows if w.get("id") == window_key), windows[0] if len(windows) == 1 else None)


def shown_engines(window):
    """{pane: chromium|webkit} for each pane whose selected tab is a browser (`debug.layers` browsers)."""
    names = {"cef": "chromium", "webkit": "webkit"}
    return {b.get("pane"): names[b.get("engine")] for b in (window or {}).get("browsers") or [] if b.get("engine") in names}


def pane_frames(window, pane_ids):
    frames = {}
    for plane in (window or {}).get("planes") or []:
        for ring in plane.get("rings") or []:
            if ring.get("pane") in pane_ids and ring.get("frame_in_window"):
                frames[ring["pane"]] = ring["frame_in_window"]
    return frames


def settled_window(rpc, window_key, pane_ids, where):
    """The `debug.layers` window once the shown workspace has laid out `pane_ids`: a ring with a frame of some
    area for each of them, every plane `in_sync`, and the same frames in two reads in a row (a show answers
    before the layout pass that sizes the panes). Raises LayoutSnapshotError after SETTLE_S."""
    stress = load_stress()
    last = {}

    def stable():
        window = layers_window(rpc, window_key)
        planes = (window or {}).get("planes") or []
        frames = pane_frames(window, pane_ids)
        ready = (set(frames) == pane_ids and planes and all(plane.get("in_sync") is True for plane in planes)
                 and all(frame[2] >= 1 and frame[3] >= 1 for frame in frames.values()))
        previous, last["frames"] = last.get("frames"), frames if ready else None
        return window if ready and frames == previous else None

    window = stress.wait(stable, SETTLE_S, step=0.05)
    if window is None:
        raise LayoutSnapshotError(f"{where}: debug.layers did not settle on frames for its {len(pane_ids)} panes in "
                                  f"{SETTLE_S:.0f} s (planes in sync, the same frames twice)")
    return window


def tab_engine(asked, shown, where):
    """The engine to export for a browser tab the builder asked as `asked` (chromium, webkit, browser or None)
    whose engine `debug.layers` reports as `shown` (chromium, webkit or None). What the app shows comes first; an
    ask for one engine that the app opened as the other is refused. `browser` (the app's default engine) takes
    either and stays `browser`, so a snapshot that names no engine names none after a round trip."""
    if asked in ("chromium", "webkit") and shown and shown != asked:
        raise LayoutSnapshotError(f"{where}: a tab asked as {asked} is a {shown} page (debug.layers)")
    if asked == "browser":
        return asked
    return shown or asked


def tab_kind(tab, engine):
    """The snapshot kind of a `snapshot.get` tab; `engine` is chromium or webkit when known."""
    kind = tab.get("kind")
    if kind == "terminal":
        return "terminal"
    if kind == "browser":
        return engine or "browser"
    if kind == "conversation":
        return "chat"
    if kind == "page" and isinstance(tab.get("page"), str) and PAGE_KIND.match(f"page:{tab['page']}"):
        return f"page:{tab['page']}"
    raise LayoutSnapshotError(f"tab kind {str(kind)[:40]!r} ({str(tab.get('page'))[:40]}) has no snapshot kind")


def export_layout(rpc, builder=None, log=None):
    """The layout snapshot of the app behind `rpc`. `builder`: the perf-stress-session builder that made the
    session (its tab engines and busy terminals; without it, a browser tab whose engine the app does not show
    is `browser`, and no terminal is busy). Each workspace with several panes or a selected browser tab is shown
    once to read its laid-out pane frames and its shown engines (`settled_window`); the shown workspace and
    focused pane are put back after, also when the export fails."""
    stress = load_stress()
    reader = stress.Stress(rpc, log=log or (lambda line: None))
    engines, busy_ids = builder_hints(builder)
    topology = reader.topology()
    windows = [w for w in topology.get("windows") or [] if w.get("workspace")]
    if len(windows) != 1:
        raise LayoutSnapshotError(f"the app shows workspaces in {len(windows)} windows; a snapshot has one window")
    window = windows[0]
    shown_id, focused_id = window["workspace"], window.get("focused_pane")
    layers = layers_window(rpc, window.get("key"))
    frame = (layers or {}).get("frame")
    if not frame:
        raise LayoutSnapshotError(f"debug.layers gave no frame for window {window.get('key')}")
    workspaces = [w for w in topology.get("workspaces") or [] if w.get("id")]
    specs, addresses, moved = [], {}, False
    shown_index = focused_index = None
    try:
        for index, workspace in enumerate(workspaces):
            screens = workspace.get("screens") or []
            if len(screens) != 1:
                raise LayoutSnapshotError(f"workspace {index} has {len(screens)} screens; a snapshot has one per workspace")
            if screens[0].get("zoomed_pane"):
                raise LayoutSnapshotError(f"workspace {index} has a zoomed pane")
            every_pane = [p for p in screens[0].get("panes") or [] if p.get("id")]
            if any(p.get("dock") for p in every_pane):
                raise LayoutSnapshotError(f"workspace {index} has a docked pane; a snapshot has no docks")
            panes = {p["id"]: p for p in every_pane}
            if not panes:
                raise LayoutSnapshotError(f"workspace {index} has no pane")
            # A selected browser's engine shows in debug.layers only while its workspace shows; it is read even
            # when the builder knows what it asked for, since the app may have opened the other engine.
            shows_browser = any(t.get("kind") == "browser" and t.get("id") == reader.selected_tab(p)
                                for p in panes.values() for t in p.get("tabs") or [])
            pane_engines = {}
            if len(panes) > 1 or shows_browser:
                if workspace["id"] != shown_id or moved:
                    reader.show(workspace["id"])
                    moved = True
                shown_layers = settled_window(rpc, window.get("key"), set(panes), f"workspace {index}")
                pane_engines = shown_engines(shown_layers)
                frames = pane_frames(shown_layers, set(panes))
            if len(panes) == 1:
                frames = {next(iter(panes)): [0, 0, 1, 1]}

            def leaf(pane_id):
                pane = panes[pane_id]
                tabs = pane.get("tabs") or []
                selected = reader.selected_tab(pane)
                kinds = [tab_kind(t, tab_engine(engines.get(t.get("id")), pane_engines.get(pane_id) if t.get("id") == selected else None,
                                                f"workspace {index}"))
                         for t in tabs]
                if not kinds:
                    raise LayoutSnapshotError(f"workspace {index}: pane has no tab")
                return {"tabs": kinds, "selected": next((i for i, t in enumerate(tabs) if t.get("id") == selected), 0)}

            tree, even, order = tree_from_frames(frames, leaf)
            specs.append({"tree": tree, "even": even})
            for pane_index, pane_id in enumerate(order):
                for tab_index, tab in enumerate(panes[pane_id].get("tabs") or []):
                    addresses[tab.get("id")] = [index, pane_index, tab_index]
            if workspace["id"] == shown_id:
                shown_index = index
                focused_index = order.index(focused_id) if focused_id in order else None
        if shown_index is None:
            raise LayoutSnapshotError(f"the shown workspace {shown_id} is not in the topology")
    finally:
        if moved:
            reader.show(shown_id)
            if focused_id:
                reader.focus_pane(focused_id)
    busy = sorted(addresses[tab] for tab in busy_ids if tab in addresses
                  if leaves(specs[addresses[tab][0]]["tree"])[addresses[tab][1]]["tabs"][addresses[tab][2]] == "terminal")
    snapshot = {"schema": SCHEMA, "window": [round(frame[2]), round(frame[3])], "workspaces": specs,
                "shown": shown_index, "focused_pane": focused_index, "busy": busy}
    return check(snapshot)


# Import.

def importable(snapshot):
    """Why `snapshot` cannot be rebuilt through actions (a list; empty when it can)."""
    stress = load_stress()
    problems = []
    if snapshot["window"] != list(stress.WINDOW_SIZE):
        problems.append(f"window {snapshot['window']} is not the bench window {list(stress.WINDOW_SIZE)} (place_window)")
    for index, workspace in enumerate(snapshot["workspaces"]):
        if not workspace["even"]:
            problems.append(f"workspace {index} has uneven splits: equalizeSplits rebuilds them even")
        for pane in leaves(workspace["tree"]):
            pages = sorted({k for k in pane["tabs"] if k.startswith("page:")} - IMPORTABLE_PAGES)
            if pages:
                problems.append(f"workspace {index}: no action opens {pages} in a pane")
    return problems


def _fresh(stress_builder, workspaces):
    """The app's own workspaces, which become the snapshot's first ones: each must be a lone terminal (a fresh
    launch), and no more than the snapshot has."""
    existing = stress_builder.workspaces()
    if len(existing) > workspaces:
        raise LayoutSnapshotError(f"the app has {len(existing)} workspaces; the snapshot has {workspaces}")
    for workspace in existing:
        panes = stress_builder.panes(workspace)
        kinds = [t.get("kind") for p in panes for t in p.get("tabs") or []]
        if len(panes) != 1 or kinds != ["terminal"]:
            raise LayoutSnapshotError(f"workspace {workspace.get('id')} is not a fresh lone terminal: import into a fresh app")
    return [w["id"] for w in existing]


def _build_node(stress_builder, workspace, pane, node):
    """Splits `pane` into `node`'s tree: a chain of splits per split node (each new pane follows the last one),
    then each child in its pane. Returns the panes in leaf order."""
    if "tabs" in node:
        return [pane]
    children = node["children"]
    regions = stress_builder.split_chain(workspace, pane, SPLITS[node["split"]], len(children) - 1)
    if len(regions) != len(children):
        raise LayoutSnapshotError(f"{SPLITS[node['split']]} of {regions[-1]} made no pane (refusals: {stress_builder.refusals[-3:]})")
    return [leaf for region, child in zip(regions, children) for leaf in _build_node(stress_builder, workspace, region, child)]


def _fill(stress_builder, workspace, pane, spec):
    """`pane` (a new pane: one terminal) gets `spec`'s tabs in order and selects `spec['selected']`."""
    kinds = [k.split(":")[0] for k in spec["tabs"]]  # page:new-tab -> page
    initial = stress_builder.tabs(workspace, pane)[0]["id"]
    adds = kinds[1:] if kinds[0] == "terminal" else kinds
    if adds:
        stress_builder.fill_pane(workspace, pane, adds)
    if kinds[0] != "terminal":
        stress_builder.close_tab(workspace, pane, initial)
    tabs = stress_builder.tabs(workspace, pane)
    if len(tabs) != len(kinds):
        raise LayoutSnapshotError(f"pane {pane} has {len(tabs)} tabs, not {len(kinds)} (refusals: {stress_builder.refusals[-3:]})")
    wanted = tabs[spec["selected"]]["id"]
    if stress_builder.selected_tab(stress_builder.pane(workspace, pane)) != wanted:
        stress_builder.select_tab(workspace, pane, wanted)
    return [t["id"] for t in tabs]


def import_layout(rpc, snapshot, builder=None, log=None):
    """Rebuilds `snapshot` in the freshly launched app behind `rpc` with perf-stress-session.py's calls: the
    bench window (`size_window`), then per workspace (the app's lone launch workspace first) its splits, shown,
    equalized, and each pane's tabs; then the busy terminals, the shown workspace and its focused pane. A snapshot
    with Chromium tabs is refused when Chromium is not running or fell back to WebKit (`cef_problems`). Returns
    the builder, which serves the browser tabs' local pages: close it when the app stops."""
    check(snapshot)
    problems = importable(snapshot)
    if problems:
        raise LayoutSnapshotError("the snapshot cannot be imported: " + "; ".join(problems))
    stress = load_stress()
    made = builder or stress.Stress(rpc, log=log)
    made.size_window()
    ids = _fresh(made, len(snapshot["workspaces"]))
    built, tab_ids, pane_ids = [], [], []
    for index, spec in enumerate(snapshot["workspaces"]):
        workspace = ids[index] if index < len(ids) else made.new_workspace()
        if not workspace:
            raise LayoutSnapshotError(f"workspace {index} did not appear")
        built.append(workspace)
        tree = spec["tree"]
        first = made.panes(made.workspace(workspace))[0]["id"]
        if tree.get("tabs") == ["terminal"]:  # what a new workspace already is
            panes = [first]
        else:
            # Shown first: a hidden workspace's split gets no even sizing and its equalizeSplits is refused.
            made.show(workspace)
            made.record_first(workspace, first)
            panes = _build_node(made, workspace, first, tree)
            if len(panes) > 1:
                made.equalize(first)
        pane_ids.append(panes)
        tab_ids.append([_fill(made, workspace, pane, leaf) if leaf["tabs"] != ["terminal"] else
                        [t["id"] for t in made.tabs(workspace, pane)] for pane, leaf in zip(panes, leaves(tree))])
        if (index + 1) % 10 == 0:
            made.log(f"layout: {index + 1}/{len(snapshot['workspaces'])} workspaces")
    made.busy = []
    for workspace, pane, tab in snapshot["busy"]:
        made.make_busy(tab_ids[workspace][pane][tab])
    shown = built[snapshot["shown"]]
    made.show(shown)
    if snapshot["focused_pane"] is not None:
        made.focus_pane(pane_ids[snapshot["shown"]][snapshot["focused_pane"]])
    made.measured = shown
    # The topology says only "browser": a Chromium ask that opened WebKit shows in debug.cef (Stress.summary's check).
    if any("chromium" in pane["tabs"] for spec in snapshot["workspaces"] for pane in leaves(spec["tree"])):
        problems = [r for r in made.refusals if r.startswith("openBrowser.chromium")]
        problems += stress.cef_problems(rpc("debug.cef"))
        if problems:
            raise LayoutSnapshotError("the snapshot's Chromium pages are not Chromium: " + "; ".join(problems[:4]))
    return made


def first_difference(want, got):
    """Where two snapshots first differ, for the round-trip error."""
    for key in ("window", "shown", "focused_pane", "busy"):
        if want.get(key) != got.get(key):
            return f"{key}: {str(want.get(key))[:80]} vs {str(got.get(key))[:80]}"
    if len(want["workspaces"]) != len(got["workspaces"]):
        return f"{len(want['workspaces'])} vs {len(got['workspaces'])} workspaces"
    for index, (a, b) in enumerate(zip(want["workspaces"], got["workspaces"])):
        if a != b:
            return f"workspace {index}: {json.dumps(a, sort_keys=True)[:160]} vs {json.dumps(b, sort_keys=True)[:160]}"
    return "none"


def roundtrip(rpc, snapshot, log=None):
    """Imports `snapshot` into the fresh app behind `rpc` and exports it again. Returns (builder, the export);
    raises LayoutSnapshotError naming the first difference when the digests differ (the builder is closed then)."""
    made = load_stress().Stress(rpc, log=log)
    try:
        import_layout(rpc, snapshot, builder=made)
        again = export_layout(rpc, builder=made, log=log)
        if digest(again) != digest(snapshot):
            raise LayoutSnapshotError(f"the round trip changed the layout: digest {digest(snapshot)[:12]} became "
                                      f"{digest(again)[:12]} ({first_difference(snapshot, again)})")
    except BaseException:
        made.close()
        raise
    return made, again


# CLI.

def _launch(app_path, out, label):
    stress = load_stress()
    folder = os.path.join(out, label)
    os.makedirs(folder, exist_ok=True)
    app = stress.load_activation_app()(os.path.abspath(app_path), folder, 50)
    app.launch()
    return app


def _hold(app):
    print(f"layout: app left running, socket {app.socket}", flush=True)
    while True:
        time.sleep(3600)  # test script: keep the pages' server up for the kept app


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export", help="write the layout snapshot of a running tagged app")
    export.add_argument("--socket", required=True, help="the debug socket of a running tagged app")
    export.add_argument("--out", required=True)
    load = commands.add_parser("import", help="rebuild a snapshot in a fresh app and check its digest")
    where = load.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="a Debug or bench `cmux DEV <tag>.app` to launch (not running)")
    where.add_argument("--socket", help="the debug socket of a freshly launched tagged app")
    load.add_argument("--layout", required=True)
    load.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="cmux-layout-"))
    load.add_argument("--keep", action="store_true", help="leave the launched app running")
    for name in ("digest", "validate"):
        command = commands.add_parser(name, help=f"{name} snapshot files")
        command.add_argument("files", nargs="+")
    trip = commands.add_parser("stress-roundtrip", help="STRESS in one launch, exported, imported in a second")
    trip.add_argument("--app", required=True)
    trip.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="cmux-layout-"))
    trip.add_argument("--vdisplay", type=float, default=0, help="first make the builder's virtual main display at this refresh (Hz)")
    opts = parser.parse_args(argv)
    for number in (signal.SIGTERM, signal.SIGHUP):  # exit through the finally blocks, which stop the apps
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))

    if opts.command in ("digest", "validate"):
        failed = False
        for path in opts.files:
            try:
                snapshot = read(path)
            except (OSError, ValueError, LayoutSnapshotError) as error:
                print(f"{path}: {error}", file=sys.stderr)
                failed = True
                continue
            print(f"{digest(snapshot)}  {path}" if opts.command == "digest" else f"{path}: ok")
        return 1 if failed else 0

    stress = load_stress()
    if opts.command == "export":
        snapshot = export_layout(stress.socket_rpc(opts.socket))
        print(f"{write(snapshot, opts.out)}  {opts.out}")
        return 0

    os.makedirs(opts.out, exist_ok=True)
    if opts.command == "import":
        snapshot = read(opts.layout)
        app = _launch(opts.app, opts.out, "import") if opts.app else None
        made = None
        try:
            made, again = roundtrip(app.rpc if app else stress.socket_rpc(opts.socket), snapshot)
            print("LAYOUT-IMPORT " + json.dumps({"digest": digest(again), "workspaces": len(again["workspaces"])}), flush=True)
            if app and opts.keep:
                _hold(app)
        finally:
            if made:
                made.close()
            if app and not opts.keep:
                app.stop()
        return 0

    display = None
    try:
        if opts.vdisplay:
            display = stress.start_vdisplay(opts.vdisplay, opts.out, 1800)
        source = _launch(opts.app, opts.out, "stress")
        builder = None
        try:
            builder = stress.Stress(source.rpc)
            summary = builder.build()
            exported = export_layout(source.rpc, builder=builder)
        finally:
            if builder:
                builder.close()
            source.stop()
        path = os.path.join(opts.out, "stress-layout.json")
        write(exported, path)
        target = _launch(opts.app, opts.out, "import")
        made = None
        try:
            start = time.monotonic()
            made, again = roundtrip(target.rpc, exported)
            result = {"digest": digest(exported), "import_digest": digest(again), "stress_build_s": summary.get("build_s"),
                      "import_s": round(time.monotonic() - start, 1), "layout": path}
        finally:
            if made:
                made.close()
            target.stop()
        print("LAYOUT-ROUNDTRIP " + json.dumps(result), flush=True)
    finally:
        if display:
            display.terminate()  # the helper this script started, by its process
    return 0


if __name__ == "__main__":
    sys.exit(main())
