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
  .json        nested objects of counts (indent=1, sorted keys, the
               generators' format), merged leaf by leaf; an object left empty
               is dropped. A file in any other shape, or an entry both
               sides changed, is a conflict: both whole files between markers.

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


def flatten(value, prefix=()):
    if isinstance(value, dict):
        leaves = {}
        for key, child in value.items():
            leaves.update(flatten(child, prefix + (key,)))
        return leaves
    return {prefix: value}


def whole_file_conflict(ours: str, theirs: str) -> tuple[str, bool]:
    """Both sides whole between markers, so the file never looks resolved."""
    def ended(text: str) -> str:
        return text if text.endswith("\n") or not text else text + "\n"
    return f"<<<<<<< ours\n{ended(ours)}=======\n{ended(theirs)}>>>>>>> theirs\n", True


def merge_json(base: str, ours: str, theirs: str) -> tuple[str, bool]:
    try:
        documents = [json.loads(text) if text.strip() else {} for text in (base, ours, theirs)]
    except ValueError:
        return whole_file_conflict(ours, theirs)
    if not all(isinstance(document, dict) for document in documents):
        return whole_file_conflict(ours, theirs)
    if json.dumps(documents[1], indent=1, sort_keys=True) + "\n" != ours:
        return whole_file_conflict(ours, theirs)  # not the generators' format: leave it to a person
    base_leaves, our_leaves, their_leaves = (flatten(document) for document in documents)
    merged: dict = {}
    for path in sorted(set(base_leaves) | set(our_leaves) | set(their_leaves)):
        result, clash = merge_value(base_leaves.get(path, MISSING), our_leaves.get(path, MISSING),
                                    their_leaves.get(path, MISSING))
        if clash:
            return whole_file_conflict(ours, theirs)
        if result is MISSING:
            continue
        node = merged
        for key in path[:-1]:
            node = node.setdefault(key, {})
            if not isinstance(node, dict):
                return whole_file_conflict(ours, theirs)
        node[path[-1]] = result
    return json.dumps(merged, indent=1, sort_keys=True) + "\n", False


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
