#!/usr/bin/env python3
"""Git merge driver for ratchet baselines: a keyed three-way merge.

A baseline lists known debt, one entry per key. Two branches that each fix or
add different entries collide positionally under a line merge, and keeping
one side whole would silently drop the other side's fixes (the style ratchets
only warn under their ceiling). This merges entry by entry: an entry either
side removed is removed, one either side added is added, one either side
changed takes that change; both sides changing the same entry differently is
a conflict, written as ordinary conflict markers around that entry.

  .txt / .tsv  one entry per line; "#" comment lines before the first entry
               are the header (ours). A line whose trailing tab-separated
               fields are numbers is keyed by its leading fields (the numbers
               are its value); any other line is its own key.
  .json        nested objects of counts in a generator's format (indent=1,
               sorted keys or the writer's own key order, which the result
               keeps), merged key by key; an object left empty is dropped.
               Both sides lowering the same count keeps the higher one. A
               file in any other shape, or an entry both sides changed in
               any other way (a raise), is a conflict: both whole files
               between markers.

Usage (git): merge-baseline.py %O %A %B %P; writes the result to %A and exits
1 on a conflict.
"""
from __future__ import annotations

import json
import re
import sys

NUMBER = re.compile(r"-?\d+(\.\d+)?")
MISSING = object()


def merge_value(base, ours, theirs):
    """(result, conflict) for one entry; MISSING means absent."""
    if ours == theirs:
        return ours, False
    if ours == base:
        return theirs, False
    if theirs == base:
        return ours, False
    return ours, True


def split_lines(text: str):
    header, entries = [], {}
    for line in text.splitlines():
        if not entries and (not line.strip() or line.startswith("#")):
            header.append(line)
            continue
        if not line.strip():
            continue
        fields = line.split("\t")
        value_fields = 0
        while value_fields < len(fields) - 1 and NUMBER.fullmatch(fields[len(fields) - 1 - value_fields]):
            value_fields += 1
        key = "\t".join(fields[: len(fields) - value_fields]) if value_fields else line
        entries[key] = line
    return header, entries


def merge_lines(base: str, ours: str, theirs: str) -> tuple[str, bool]:
    _, base_entries = split_lines(base)
    header, our_entries = split_lines(ours)
    _, their_entries = split_lines(theirs)
    ordered = list(our_entries) + [key for key in their_entries if key not in our_entries]
    keys = sorted(ordered) if list(our_entries) == sorted(our_entries) else ordered
    out, conflict = list(header), False
    for key in keys:
        result, clash = merge_value(base_entries.get(key, MISSING), our_entries.get(key, MISSING),
                                    their_entries.get(key, MISSING))
        if clash:
            conflict = True
            out += ["<<<<<<< ours"]
            out += [] if our_entries.get(key) is None else [our_entries[key]]
            out += ["======="]
            out += [] if their_entries.get(key) is None else [their_entries[key]]
            out += [">>>>>>> theirs"]
        elif result is not MISSING:
            out.append(result)
    return "\n".join(out) + "\n", conflict


def whole_file_conflict(ours: str, theirs: str) -> tuple[str, bool]:
    """Both sides whole between markers, so the file never looks resolved."""
    def ended(text: str) -> str:
        return text if text.endswith("\n") or not text else text + "\n"
    return f"<<<<<<< ours\n{ended(ours)}=======\n{ended(theirs)}>>>>>>> theirs\n", True


def is_count(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def merge_leaf(base, ours, theirs):
    """(result, conflict) for one leaf. Both sides lowering the same count keeps the higher: the merged code can still
    hold hits only one side removed, and a ratchet never rises above its base (a later --update-baseline lowers it)."""
    result, clash = merge_value(base, ours, theirs)
    if clash and is_count(base) and is_count(ours) and is_count(theirs) and ours < base and theirs < base:
        return max(ours, theirs), False
    return result, clash


def merge_node(base, ours, theirs, sort: bool, top: bool = False):
    """(result, conflict) for nested objects, merged key by key; MISSING means absent. Keys keep ours' order, then
    theirs' new keys (sorted when the file is). An object left empty is dropped."""
    nodes = [node for node in (base, ours, theirs) if node is not MISSING]
    if not all(isinstance(node, dict) for node in nodes):
        return merge_leaf(base, ours, theirs)
    pick = lambda node, key: node.get(key, MISSING) if isinstance(node, dict) else MISSING
    keys = list(ours) if isinstance(ours, dict) else []
    keys += [key for key in (theirs if isinstance(theirs, dict) else {}) if key not in keys]
    keys += [key for key in (base if isinstance(base, dict) else {}) if key not in keys]
    merged = {}
    for key in sorted(keys) if sort else keys:
        result, clash = merge_node(pick(base, key), pick(ours, key), pick(theirs, key), sort)
        if clash:
            return None, True
        if result is not MISSING:
            merged[key] = result
    return (merged if merged or top else MISSING), False


def merge_json(base: str, ours: str, theirs: str) -> tuple[str, bool]:
    try:
        documents = [json.loads(text) if text.strip() else {} for text in (base, ours, theirs)]
    except ValueError:
        return whole_file_conflict(ours, theirs)
    if not all(isinstance(document, dict) for document in documents):
        return whole_file_conflict(ours, theirs)
    # The generators' formats: indent=1 with sorted keys, or in the writer's own key order (rust_panic_ratchet.py).
    sort = json.dumps(documents[1], indent=1, sort_keys=True) + "\n" == ours
    if not sort and json.dumps(documents[1], indent=1) + "\n" != ours:
        return whole_file_conflict(ours, theirs)  # not a generator's format: leave it to a person
    merged, clash = merge_node(*documents, sort=sort, top=True)
    if clash:
        return whole_file_conflict(ours, theirs)
    return json.dumps(merged, indent=1, sort_keys=sort) + "\n", False


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print("usage: merge-baseline.py BASE OURS THEIRS PATH", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path, path = argv[1:]
    texts = []
    for name in (base_path, ours_path, theirs_path):
        with open(name, encoding="utf-8") as handle:
            texts.append(handle.read())
    merge = merge_json if path.endswith(".json") else merge_lines
    result, conflict = merge(*texts)
    with open(ours_path, "w", encoding="utf-8") as handle:
        handle.write(result)
    if conflict:
        print(f"merge-baseline: {path}: both sides changed the same entry; resolve it or regenerate the baseline",
              file=sys.stderr)
    return 1 if conflict else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
