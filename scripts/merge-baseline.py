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
  .jsonl       one compact JSON object per line whose `values` maps a value to
               its count (webviews/scripts/check-design-tokens.ts), keyed by
               every other field and merged count by count; a row left with no
               values is dropped. A row both sides changed the same count of is
               a conflict around that row; a line in any other shape makes the
               whole file a conflict.

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


def compact(row) -> str:
    return json.dumps(row, separators=(",", ":"), ensure_ascii=False)


def split_rows(text: str):
    """Rows by key (every field but `values`), or None when a line is not such a row in compact
    form or two rows share a key (one would silently replace the other's counts)."""
    rows = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            return None
        if (not isinstance(row, dict) or not isinstance(row.get("values"), dict)
                or compact(row) != line):
            return None
        # Sorted, so two rows that list the same fields in another order share one key.
        key = json.dumps({name: value for name, value in row.items() if name != "values"},
                         separators=(",", ":"), ensure_ascii=False, sort_keys=True)
        if key in rows:
            return None
        rows[key] = row
    return rows


def merge_jsonl(base: str, ours: str, theirs: str) -> tuple[str, bool]:
    split = [split_rows(text) for text in (base, ours, theirs)]
    if any(rows is None for rows in split):
        return whole_file_conflict(ours, theirs)
    base_rows, our_rows, their_rows = split
    ordered = list(our_rows) + [key for key in their_rows if key not in our_rows]
    out, conflict = [], False
    for key in ordered:
        values = {}
        clash_here = False
        names = [*our_rows.get(key, {}).get("values", {}),
                 *(name for name in their_rows.get(key, {}).get("values", {})
                   if name not in our_rows.get(key, {}).get("values", {})),
                 *base_rows.get(key, {}).get("values", {})]
        for name in dict.fromkeys(names):
            result, clash = merge_value(*(rows.get(key, {}).get("values", {}).get(name, MISSING)
                                          for rows in (base_rows, our_rows, their_rows)))
            clash_here = clash_here or clash
            if result is not MISSING:
                values[name] = result
        if clash_here:
            conflict = True
            out += ["<<<<<<< ours"]
            out += [compact(our_rows[key])] if key in our_rows else []
            out += ["======="]
            out += [compact(their_rows[key])] if key in their_rows else []
            out += [">>>>>>> theirs"]
        elif values:
            out.append(compact({**json.loads(key), "values": values}))
    return "\n".join(out) + "\n", conflict


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print("usage: merge-baseline.py BASE OURS THEIRS PATH", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path, path = argv[1:]
    texts = []
    for name in (base_path, ours_path, theirs_path):
        with open(name, encoding="utf-8") as handle:
            texts.append(handle.read())
    merge = merge_json if path.endswith(".json") else merge_jsonl if path.endswith(".jsonl") else merge_lines
    result, conflict = merge(*texts)
    with open(ours_path, "w", encoding="utf-8") as handle:
        handle.write(result)
    if conflict:
        print(f"merge-baseline: {path}: both sides changed the same entry; resolve it or regenerate the baseline",
              file=sys.stderr)
    return 1 if conflict else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
