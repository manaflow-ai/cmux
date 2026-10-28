#!/usr/bin/env python3
"""Git merge driver for keyed JSON documents: a three-way merge key by key.

plans/cmux-next/chrome-parity/design-result.json is one 1.6 MB line
({"programs": {name: {..., "tasks": [{"id": ...}, ...]}}, "plan": ..., ...}).
Each task branch edits only its own task, but git merges by line, so any two
edits of the file conflicted (40 merge-train conflicts in 24 hours).
plans/cmux-next/chromium-host-ops.json (indent=2) conflicted the same way when
two branches each appended an entry at the end of "exports" or "events".

This merges the parsed documents instead:

- Objects merge key by key, recursively, in ours' key order with theirs' new
  keys appended. A key one side deleted and the other left unchanged is deleted.
- A list of objects is keyed by the first of "id", "name", "kind", "site" that
  every item of base, ours and theirs has as a string, unique within each side.
  It merges item by item by that key, recursively, in ours' order with theirs'
  new items appended (in theirs' order when only theirs reordered the shared
  items). An item one side deleted and the other left unchanged is deleted.
  A list with no such key is a leaf.
- Every other list and every scalar is a leaf: the side that changed it wins,
  and both sides changing it differently is a conflict.

The result is written in ours' format: json.dumps(doc) with no newline (the
design file) or with one (a branch's fixer once wrote that), or indent=1 /
indent=2 plus a newline (the ops file), with ours' ensure_ascii.
A conflict writes both whole files between ordinary markers and exits 1: a
leaf both sides changed differently, items both sides reordered differently, a
side that does not parse, or an ours format this driver cannot reproduce. It
never writes a clean-looking merge it is unsure of.

Usage (git): merge-keyed-json.py %O %A %B %P; writes the result to %A.
"""
from __future__ import annotations

import json
import sys

MISSING = object()


class Conflict(Exception):
    pass


def same(a, b) -> bool:
    """JSON equality: true is not 1, 1 is not 1.0 (Python's == says they are)."""
    if a is MISSING or b is MISSING:
        return a is b
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[key], b[key]) for key in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


LIST_KEYS = ("id", "name", "kind", "site")


def keyed_by(value, key: str) -> bool:
    if not isinstance(value, list):
        return False
    seen = set()
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get(key), str) or item[key] in seen:
            return False
        seen.add(item[key])
    return True


def list_key(*sides):
    """The first of LIST_KEYS that every item of every present side has as a unique string, else None."""
    present = [side for side in sides if side is not MISSING]
    for key in LIST_KEYS:
        if all(keyed_by(side, key) for side in present):
            return key
    return None


def merge(base, ours, theirs, path: str):
    if same(ours, theirs):
        return ours
    if same(base, ours):
        return theirs
    if same(base, theirs):
        return ours
    if isinstance(ours, dict) and isinstance(theirs, dict) and (base is MISSING or isinstance(base, dict)):
        return merge_objects({} if base is MISSING else base, ours, theirs, path)
    if isinstance(ours, list) and isinstance(theirs, list) and (base is MISSING or isinstance(base, list)):
        key = list_key(base, ours, theirs)
        if key is not None:
            return merge_keyed_lists(key, [] if base is MISSING else base, ours, theirs, path)
    raise Conflict(f"{path or '/'}: both sides changed it differently")


def merge_objects(base: dict, ours: dict, theirs: dict, path: str) -> dict:
    merged: dict = {}
    for key in list(ours) + [key for key in theirs if key not in ours] + [key for key in base if key not in ours and key not in theirs]:
        value = merge(base.get(key, MISSING), ours.get(key, MISSING), theirs.get(key, MISSING), f"{path}/{key}")
        if value is not MISSING:
            merged[key] = value
    return merged


def merge_keyed_lists(key: str, base: list, ours: list, theirs: list, path: str) -> list:
    by_id = [{item[key]: item for item in side} for side in (base, ours, theirs)]
    shared = set(by_id[0]) & set(by_id[1]) & set(by_id[2])
    orders = [[item[key] for item in side if item[key] in shared] for side in (base, ours, theirs)]
    first, second = ours, theirs
    if orders[2] != orders[0]:
        if orders[1] != orders[0] and orders[1] != orders[2]:
            raise Conflict(f"{path}: both sides reordered the same items differently")
        if orders[1] == orders[0]:
            first, second = theirs, ours
    ids = list(dict.fromkeys([item[key] for item in first] + [item[key] for item in second]))
    merged = []
    for item_id in ids:
        value = merge(*(side.get(item_id, MISSING) for side in by_id), f"{path}[{key}={item_id}]")
        if value is not MISSING:
            merged.append(value)
    return merged


FORMATS = (
    ("compact", lambda doc, ascii_only: json.dumps(doc, ensure_ascii=ascii_only)),
    ("compact+newline", lambda doc, ascii_only: json.dumps(doc, ensure_ascii=ascii_only) + "\n"),
    ("indent=1", lambda doc, ascii_only: json.dumps(doc, indent=1, ensure_ascii=ascii_only) + "\n"),
    ("indent=2", lambda doc, ascii_only: json.dumps(doc, indent=2, ensure_ascii=ascii_only) + "\n"),
)


def detect_format(doc, text: str):
    for _, render in FORMATS:
        for ascii_only in (True, False):
            if render(doc, ascii_only) == text:
                return lambda merged, render=render, ascii_only=ascii_only: render(merged, ascii_only)
    return None


def read_bytes(path: str) -> bytes:
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except FileNotFoundError:
        return b""


def conflict(ours_path: str, ours_raw: bytes, theirs_raw: bytes, reason: str) -> int:
    def block(raw: bytes) -> bytes:
        return raw if raw.endswith(b"\n") else raw + b"\n"

    with open(ours_path, "wb") as handle:
        handle.write(b"<<<<<<< ours\n" + block(ours_raw) + b"=======\n" + block(theirs_raw) + b">>>>>>> theirs\n")
    print(f"merge-keyed-json: conflict: {reason}", file=sys.stderr)
    return 1


def merge_texts(base_raw: bytes, ours_raw: bytes, theirs_raw: bytes) -> str:
    """The merged text in ours' format; raises Conflict when it cannot merge."""
    try:
        base = json.loads(base_raw.decode("utf-8")) if base_raw.strip() else MISSING
        ours = json.loads(ours_raw.decode("utf-8"))
        theirs = json.loads(theirs_raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Conflict(f"a side does not parse ({error})") from None
    render = detect_format(ours, ours_raw.decode("utf-8"))
    if render is None:
        raise Conflict("ours is not in a format this driver writes back byte for byte")
    return render(merge(base, ours, theirs, ""))


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = argv[1:4]
    label = argv[4] if len(argv) > 4 else ours_path
    base_raw, ours_raw, theirs_raw = read_bytes(base_path), read_bytes(ours_path), read_bytes(theirs_path)
    try:
        merged = merge_texts(base_raw, ours_raw, theirs_raw)
    except (Conflict, RecursionError) as error:
        return conflict(ours_path, ours_raw, theirs_raw, f"{label}: {error}")
    with open(ours_path, "w", encoding="utf-8", newline="") as handle:
        handle.write(merged)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
