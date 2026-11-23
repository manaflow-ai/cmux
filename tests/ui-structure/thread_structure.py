#!/usr/bin/env python3
"""The Chief thread's structure check: a thread snapshot against tests/ui-structure/chief-thread.json.

Leo, 2026-11-10, on a nightly (824dfe5) whose Messages view drew a column of avatar tiles beside wide grey cards:
"latest nightly chief UI got completely cooked we have massive regression what happened" ... "Where's
the spec for that? Where's the iMessage". This is that spec as a check. It reads geometry, never pixels
or class names, so it holds whichever renderer draws the thread: the native transcript (its AXList
"Messages" of 'message' elements, MessagesLab TranscriptAccess.swift) or a web page (its labelled
Messages region, read through WebKit's or Chromium's accessibility tree).

A snapshot (points, top-left origin, y down):

    {"surface": "chief-panel" | "conversation-tab" | "home",
     "source": "where it came from",
     "surface_frame": [x, y, w, h],            # the panel, tab or Home view
     "thread_frame": [x, y, w, h] | null,      # the Messages container
     "messages": [{"frame": [...], "mine": bool, "sender": str, "text": str,
                   "kind": "text" | "attachment", "tail": bool | null}],
     "avatars": [{"frame": [...], "label": str}],          # optional: what the tree shows
     "side_elements": [{"frame": [...], "role": str, "label": str}]}

    thread_structure.py check [--surface S] SNAPSHOT.json   exit 0 pass, 1 violations, 2 usage
    thread_structure.py normalize --surface S AXDUMP.json   prints a snapshot from a raw AX dump
                                                            (tests/ui-structure/ax_dump.swift)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
SPEC_PATH = HERE / "chief-thread.json"

Frame = tuple[float, float, float, float]


def load_spec(path: Path = SPEC_PATH) -> dict[str, Any]:
    return json.loads(path.read_text())


def _f(value: Any) -> Frame:
    x, y, w, h = (float(v) for v in value)
    return (x, y, w, h)


def _max_x(f: Frame) -> float:
    return f[0] + f[2]


def _max_y(f: Frame) -> float:
    return f[1] + f[3]


def bubble_max_width(spec: dict[str, Any], thread_width: float) -> float:
    """The widest bubble the native transcript draws in a thread this wide (Layout.swift Metrics)."""
    b = spec["bubble"]
    at, column, slope, narrow = b["text_column_at"], b["text_column"], b["text_column_slope"], b["narrow_below"]
    if thread_width >= narrow:
        text = column - slope * (at - thread_width)
    else:
        text = (column - slope * (at - narrow)) * thread_width / narrow
    return text + 2 * b["pad_x"]


def _violation(rule: str, detail: str) -> dict[str, str]:
    return {"rule": rule, "detail": detail}


def check(snapshot: dict[str, Any], spec: dict[str, Any] | None = None, surface: str | None = None) -> list[dict[str, str]]:
    """Every rule the snapshot breaks (empty: it passes)."""
    spec = spec or load_spec()
    surface = surface or snapshot.get("surface") or "chief-panel"
    if surface not in spec["surfaces"]:
        raise ValueError(f"unknown surface {surface!r}; one of {sorted(spec['surfaces'])}")
    single = spec["surfaces"][surface]["single_conversation"]
    out: list[dict[str, str]] = []
    if not snapshot.get("thread_frame"):
        return [_violation("thread-present", "no Messages container in the surface")]
    thread = _f(snapshot["thread_frame"])
    tx, ty, tw, th = thread
    messages = [dict(m, frame=_f(m["frame"])) for m in snapshot.get("messages", [])]
    avatars = [dict(a, frame=_f(a["frame"])) for a in snapshot.get("avatars", []) or []]

    # no-side-column: a single conversation's thread spans its surface, with nothing beside it.
    if single:
        slack = spec["thread"]["surface_edge_slack"]
        if snapshot.get("surface_frame"):
            sx, _, sw, _ = _f(snapshot["surface_frame"])
            if tx - sx > slack:
                out.append(_violation("no-side-column", f"the thread starts {tx - sx:.0f} pt right of the surface's left edge (at most {slack})"))
            if (sx + sw) - _max_x(thread) > slack:
                out.append(_violation("no-side-column", f"the thread ends {(sx + sw) - _max_x(thread):.0f} pt left of the surface's right edge (at most {slack})"))
        side = [e for e in snapshot.get("side_elements", []) or []]
        if side:
            labels = ", ".join(sorted({str(e.get("label") or e.get("role") or "?") for e in side})[:8])
            out.append(_violation("no-side-column", f"{len(side)} element(s) beside the thread: {labels}"))

    # avatar-inline: inside the thread, bottom-aligned with an incoming bubble, just left of it.
    a_spec = spec["avatar"]
    incoming = [m for m in messages if not m.get("mine")]
    loose = []
    for a in avatars:
        f = a["frame"]
        inside = f[0] >= tx - 1 and _max_x(f) <= _max_x(thread) + 1
        if not single and not inside and (_max_x(f) <= tx + 1 or f[0] >= _max_x(thread) - 1):
            continue  # the docked Home's list column: its rows' avatars are the list's, not the thread's
        beside = any(
            abs(_max_y(m["frame"]) - _max_y(f)) <= a_spec["bottom_slack"]
            and 0 <= m["frame"][0] - _max_x(f) <= a_spec["max_gap"]
            for m in incoming
        )
        if not (inside and beside):
            loose.append(a)
    if loose:
        out.append(_violation("avatar-inline", f"{len(loose)} of {len(avatars)} avatar(s) are not beside an incoming bubble in the thread: "
                              + ", ".join(str(a.get("label") or "?") for a in loose[:8])))

    # bubble widths and sides.
    widest = bubble_max_width(spec, tw) + spec["bubble"]["width_slack"]
    full = spec["bubble"]["full_width_fraction"] * tw
    al = spec["alignment"]
    out_inset = al["side"] + al["tail_reach"] + al["slack"]
    in_inset = al["side"] + al["avatar_column"] + al["slack"]
    att_max = min(spec["attachment"]["max_width"], bubble_max_width(spec, tw)) + spec["attachment"]["width_slack"]
    for i, m in enumerate(messages):
        f = m["frame"]
        name = f"message {i + 1} ({'mine' if m.get('mine') else m.get('sender') or 'theirs'}: {str(m.get('text', ''))[:40]!r})"
        if m.get("kind") == "attachment":
            if f[2] > att_max:
                out.append(_violation("attachment-bubble-size", f"{name} is {f[2]:.0f} pt wide (at most {att_max:.0f})"))
            if f[0] < tx - 1 or _max_x(f) > _max_x(thread) + 1 or f[1] < ty - 1:
                out.append(_violation("attachment-bubble-size", f"{name} is not inside the thread"))
        else:
            if f[2] > widest:
                out.append(_violation("bubble-max-width", f"{name} is {f[2]:.0f} pt wide; the bubble column at {tw:.0f} pt is {widest:.0f}"))
            if f[2] >= full:
                out.append(_violation("bubble-not-full-width", f"{name} is {f[2] / tw:.0%} of the thread: a full-width card, not a bubble"))
        if m.get("mine"):
            gap = _max_x(thread) - _max_x(f)
            if gap > out_inset:
                out.append(_violation("sender-aligned", f"{name} ends {gap:.0f} pt from the right edge (at most {out_inset})"))
        else:
            gap = f[0] - tx
            if gap > in_inset:
                out.append(_violation("sender-aligned", f"{name} starts {gap:.0f} pt from the left edge (at most {in_inset})"))

    # needs-you-once.
    seen: dict[str, int] = {}
    for m in messages:
        text = str(m.get("text", "")).strip()
        for prefix in spec["needs_you"]["prefixes"]:
            if text.startswith(prefix):
                head = text.splitlines()[0]
                seen[head] = seen.get(head, 0) + 1
    for head, count in seen.items():
        if count > 1:
            out.append(_violation("needs-you-once", f"{head[:60]!r} heads {count} messages"))

    # tail-on-run-end, where the snapshot knows tails.
    if messages and all(m.get("tail") is not None for m in messages):
        for i, m in enumerate(messages):
            nxt = messages[i + 1] if i + 1 < len(messages) else None
            ends_run = nxt is None or bool(nxt.get("mine")) != bool(m.get("mine")) or nxt.get("sender") != m.get("sender")
            if m.get("kind") == "attachment":
                continue
            if ends_run and not m["tail"]:
                out.append(_violation("tail-on-run-end", f"message {i + 1} ends its run without a tail"))
    return out


# --- a raw accessibility dump (ax_dump.swift, or a web page's tree) to a snapshot ------------------

AVATAR_ROLES = {"AXImage", "AXGroup", "AXButton", "AXCell"}
SIDE_ROLES = {"AXRow", "AXCell", "AXOutline", "AXTable", "AXList", "AXButton", "AXImage", "AXStaticText", "AXGroup", "AXLink"}


def _walk(node: dict[str, Any], parents: tuple[dict[str, Any], ...] = ()):
    yield node, parents
    for child in node.get("children", []) or []:
        yield from _walk(child, parents + (node,))


def _names(node: dict[str, Any]) -> list[str]:
    return [str(node.get(k) or "") for k in ("label", "title", "description")]


def _text(node: dict[str, Any]) -> str:
    parts = []
    for n, _ in _walk(node):
        if n.get("role") == "AXStaticText":
            parts.append(str(n.get("value") or n.get("title") or n.get("label") or ""))
    return "\n".join(p for p in parts if p)


def _has_frame(n: dict[str, Any]) -> bool:
    f = n.get("frame")
    return bool(f) and f[2] > 0 and f[3] > 0


def normalize(raw: dict[str, Any], surface: str, spec: dict[str, Any] | None = None, source: str = "") -> dict[str, Any]:
    """A snapshot from a raw AX tree: {role, subrole, role_description, title, label, value,
    identifier, frame: [x, y, w, h], children}."""
    spec = spec or load_spec()
    names = set(spec["thread"]["container_names"])
    candidates = [(n, p) for n, p in _walk(raw) if _has_frame(n) and names & set(_names(n))
                  and n.get("role") in {"AXList", "AXGroup", "AXScrollArea", "AXWebArea"}]
    snap: dict[str, Any] = {"surface": surface, "source": source, "surface_frame": None, "thread_frame": None,
                            "messages": [], "avatars": [], "side_elements": []}
    if not candidates:
        return snap
    thread, parents = max(candidates, key=lambda c: c[0]["frame"][2] * c[0]["frame"][3])
    tf = _f(thread["frame"])
    snap["thread_frame"] = list(tf)
    # The surface: the web page that holds the thread, else the split pane or window that does.
    surface_node = next((p for p in reversed(parents) if p.get("role") == "AXWebArea"), None)
    if surface_node is None:
        for i in range(len(parents) - 1, -1, -1):
            if i > 0 and parents[i - 1].get("role") == "AXSplitGroup":
                surface_node = parents[i]
                break
    if surface_node is None:
        surface_node = next((p for p in reversed(parents) if p.get("role") == "AXWindow"), parents[-1] if parents else thread)
    sf = _f(surface_node["frame"]) if _has_frame(surface_node) else tf
    snap["surface_frame"] = list(sf)

    role_desc = spec["thread"]["message_role_description"]
    mine_name = spec["thread"]["mine_sender"]
    native = [n for n, _ in _walk(thread) if n.get("role_description") == role_desc and _has_frame(n)]
    cx = tf[0] + tf[2] / 2
    if native:
        for n in native:
            text = str(n.get("value") or "")
            sender = str(n.get("title") or "")
            snap["messages"].append({"frame": list(_f(n["frame"])), "mine": sender == mine_name, "sender": sender, "text": text,
                                     "kind": "attachment" if text.startswith("Attachment: ") else "text", "tail": None})
    else:
        # A web page: each bubble is the innermost group in the thread that holds text and no other
        # text group; an image the size of a picture is an attachment.
        for n, ps in _walk(thread):
            if n is thread or not _has_frame(n):
                continue
            f = _f(n["frame"])
            if n.get("role") == "AXImage" and f[2] >= 80 and f[3] >= 60:
                snap["messages"].append({"frame": list(f), "mine": f[0] + f[2] / 2 > cx, "sender": "", "text": str(n.get("label") or ""),
                                         "kind": "attachment", "tail": None})
                continue
            if n.get("role") != "AXGroup":
                continue
            inner_groups = [c for c, _ in _walk(n) if c is not n and c.get("role") == "AXGroup" and _text(c)]
            if inner_groups or not _text(n):
                continue
            if f[3] < 14:
                continue
            snap["messages"].append({"frame": list(f), "mine": f[0] + f[2] / 2 > cx and _max_x(f) > tf[0] + tf[2] * 0.6,
                                     "sender": "", "text": _text(n), "kind": "text", "tail": None})
    snap["messages"].sort(key=lambda m: (m["frame"][1], m["frame"][0]))

    # Avatars: square tiles of 20-72 pt anywhere in the surface (a monogram's text or a picture).
    in_surface = [(n, p) for n, p in _walk(surface_node) if _has_frame(n)]
    thread_ids = {id(n) for n, _ in _walk(thread)}
    for n, _ in in_surface:
        f = _f(n["frame"])
        if n.get("role") in AVATAR_ROLES and 20 <= f[2] <= 72 and abs(f[2] - f[3]) <= 4:
            label = _text(n) or str(n.get("label") or n.get("title") or "")
            if n.get("role") == "AXImage" or (label and len(label) <= 3 and label.isupper()):
                snap["avatars"].append({"frame": list(f), "label": label})
    # Side elements: anything of size in the surface, beside the thread (fully left or right of it,
    # overlapping it vertically), outside the thread's own tree.
    for n, _ in in_surface:
        if id(n) in thread_ids or n is surface_node or n.get("role") not in SIDE_ROLES:
            continue
        f = _f(n["frame"])
        if f[2] < 20 or f[3] < 20 or _max_y(f) <= tf[1] or f[1] >= _max_y(tf):
            continue
        if _max_x(f) <= tf[0] + 1 or f[0] >= _max_x(tf) - 1:
            if any(_f(a["frame"]) == f for a in snap["avatars"]) or n.get("role") in {"AXRow", "AXCell", "AXButton", "AXImage", "AXStaticText"}:
                snap["side_elements"].append({"frame": list(f), "role": n.get("role"), "label": _text(n) or str(n.get("label") or "")})
    return snap


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--surface")
    c.add_argument("--spec", type=Path, default=SPEC_PATH)
    c.add_argument("--json", action="store_true", help="print the violations as JSON")
    c.add_argument("snapshot", type=Path)
    n = sub.add_parser("normalize")
    n.add_argument("--surface", required=True)
    n.add_argument("--spec", type=Path, default=SPEC_PATH)
    n.add_argument("--source", default="")
    n.add_argument("dump", type=Path)
    args = ap.parse_args(argv)
    spec = load_spec(args.spec)
    if args.cmd == "normalize":
        print(json.dumps(normalize(json.loads(args.dump.read_text()), args.surface, spec, args.source), indent=1))
        return 0
    snapshot = json.loads(args.snapshot.read_text())
    try:
        found = check(snapshot, spec, args.surface)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(found, indent=1))
    else:
        where = snapshot.get("source") or args.snapshot
        if not found:
            print(f"chief thread structure: pass ({args.surface or snapshot.get('surface')}, {len(snapshot.get('messages', []))} messages; {where})")
        for v in found:
            print(f"chief thread structure: FAIL {v['rule']}: {v['detail']} ({where})")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
