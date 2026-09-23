#!/usr/bin/env python3
"""Git merge driver for Xcode string catalogs (.xcstrings).

A string catalog is one large JSON object keyed by string id. Two branches that
each add a different key collide positionally even though the keys are disjoint,
because both insertions land in the same region of the file. On
Resources/Localizable.xcstrings (~6,700 entries) that produced 42 conflict
hunks in a single pull request, none of them a semantic disagreement.

This driver merges per key instead of per line. It is deliberately conservative:
when the same key is changed on both sides it exits non-zero and lets git write
normal conflict markers, so a real disagreement is never resolved silently.

Formatting is preserved by construction. The driver never re-serializes the
document; it locates the byte span of each key's `"key": value` pair and
assembles the result from those spans verbatim, taking each key's text from
whichever side supplies it. Catalogs in this repository are written in at least
three different styles (nested two-space, compacted leaf objects, and Xcode's
`"key" : value` spacing), and a branch often carries a different style from
main, so re-rendering would rewrite formatting the driver does not own.

Usage (git passes these): merge-xcstrings.py %O %A %B %P
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

DECODER = json.JSONDecoder()
WHITESPACE = " \t\r\n"


def _skip_whitespace(text: str, index: int) -> int:
    while index < len(text) and text[index] in WHITESPACE:
        index += 1
    return index


def scan_object(text: str, open_index: int) -> tuple[list[tuple[str, int, int, int]], int]:
    """Index one JSON object's members without re-serializing it.

    `open_index` is the offset of its `{`. Returns the member list, each entry
    `(key, key_start, value_start, value_end)`, and the offset of the closing
    `}`. Works regardless of the whitespace style the file was written in.
    """
    if text[open_index] != "{":
        raise ValueError(f"expected an object at offset {open_index}")
    index: int = open_index + 1
    members: list[tuple[str, int, int, int]] = []
    while True:
        index = _skip_whitespace(text, index)
        if index >= len(text):
            raise ValueError("unterminated object")
        char = text[index]
        if char == "}":
            return members, index
        if char == ",":
            index += 1
            continue
        if char != '"':
            raise ValueError(f"expected a key at offset {index}, found {char!r}")
        key_start = index
        key, index = DECODER.raw_decode(text, index)
        index = _skip_whitespace(text, index)
        if index >= len(text) or text[index] != ":":
            raise ValueError(f"expected ':' after key {key!r}")
        index = _skip_whitespace(text, index + 1)
        value_start = index
        _, index = DECODER.raw_decode(text, index)
        members.append((key, key_start, value_start, index))


class Layout:
    """One object's members plus the whitespace used to lay them out."""

    def __init__(self, text: str, open_index: int) -> None:
        members, close_index = scan_object(text, open_index)
        self.text = text
        self.open_index = open_index
        self.close_index = close_index
        self.members = members
        self.blocks = {key: text[key_start:value_end] for key, key_start, _, value_end in members}
        self.values = {key: text[value_start:value_end] for key, _, value_start, value_end in members}
        self.spans = {key: (key_start, value_start, value_end) for key, key_start, value_start, value_end in members}
        if members:
            self.lead = text[open_index + 1 : members[0][1]]
            self.tail = text[members[-1][3] : close_index]
            if len(members) >= 2:
                self.separator = text[members[0][3] : members[1][1]]
            else:
                self.separator = "," + self.lead
        else:
            self.lead = self.tail = text[open_index + 1 : close_index]
            self.separator = ","

    def assemble(self, ordered: list[tuple[str, str]]) -> str:
        """Rebuild this object from `(key, block_text)` pairs, keeping our layout."""
        if not ordered:
            return "{" + self.tail.strip(WHITESPACE) + "}"
        body = self.separator.join(block for _, block in ordered)
        return "{" + self.lead + body + self.tail + "}"


def merge_keys(
    base: dict, ours: dict, theirs: dict, label: str
) -> tuple[list[tuple[str, str]], list[str]]:
    """Three-way merge one mapping by key. Returns ((key, side) list, conflicts).

    `side` is "ours" or "theirs", naming which file the key's text comes from.
    """
    ordered: list[tuple[str, str]] = []
    conflicts: list[str] = []
    for key in list(ours) + [k for k in theirs if k not in ours]:
        in_base, in_ours, in_theirs = key in base, key in ours, key in theirs
        base_value, ours_value, theirs_value = base.get(key), ours.get(key), theirs.get(key)
        ours_changed = ours_value != base_value if in_base else in_ours
        theirs_changed = theirs_value != base_value if in_base else in_theirs
        if not in_ours and not in_theirs:
            continue
        if ours_changed and theirs_changed:
            if ours_value == theirs_value:
                if in_ours:
                    ordered.append((key, "ours"))
                continue
            conflicts.append(f"{label}.{key}")
            continue
        if ours_changed:
            if in_ours:
                ordered.append((key, "ours"))
            continue
        if theirs_changed:
            if in_theirs:
                ordered.append((key, "theirs"))
            continue
        ordered.append((key, "ours"))
    return ordered, conflicts


def _strings_open_index(text: str, layout: Layout) -> int:
    if "strings" not in layout.spans:
        raise ValueError("catalog has no 'strings' object")
    _, value_start, _ = layout.spans["strings"]
    if text[value_start] != "{":
        raise ValueError("'strings' is not an object")
    return value_start


def merge_catalog_text(
    base_text: str, ours_text: str, theirs_text: str
) -> tuple[str, list[str], list[str]]:
    """Merge three catalog texts by key. Returns (text, conflicts, merged keys)."""
    base_doc, ours_doc, theirs_doc = (json.loads(t) for t in (base_text, ours_text, theirs_text))
    tops = {
        "base": Layout(base_text, base_text.index("{")),
        "ours": Layout(ours_text, ours_text.index("{")),
        "theirs": Layout(theirs_text, theirs_text.index("{")),
    }
    strings = {
        side: Layout(text, _strings_open_index(text, tops[side]))
        for side, text in (("base", base_text), ("ours", ours_text), ("theirs", theirs_text))
    }

    ordered_strings, conflicts = merge_keys(
        base_doc.get("strings", {}), ours_doc.get("strings", {}), theirs_doc.get("strings", {}), "strings"
    )
    strings_text = strings["ours"].assemble(
        [(key, strings[side].blocks[key]) for key, side in ordered_strings]
    )

    top_ordered, top_conflicts = merge_keys(
        {k: v for k, v in base_doc.items() if k != "strings"},
        {k: v for k, v in ours_doc.items() if k != "strings"},
        {k: v for k, v in theirs_doc.items() if k != "strings"},
        "catalog",
    )
    side_of = dict(top_ordered)
    strings_block = json.dumps("strings") + _joiner(tops["ours"], "strings") + strings_text

    # Keep our member order, substituting the rebuilt "strings" object in place,
    # then append any top-level key only theirs introduced.
    rebuilt: list[tuple[str, str]] = []
    for key, _, _, _ in tops["ours"].members:
        if key == "strings":
            rebuilt.append((key, strings_block))
        elif key in side_of:
            rebuilt.append((key, tops[side_of[key]].blocks[key]))
    for key, side in top_ordered:
        if key not in ours_doc:
            rebuilt.append((key, tops[side].blocks[key]))

    merged_text = (
        ours_text[: tops["ours"].open_index]
        + tops["ours"].assemble(rebuilt)
        + ours_text[tops["ours"].close_index + 1 :]
    )
    return merged_text, conflicts + top_conflicts, [key for key, _ in ordered_strings]


def _joiner(layout: Layout, key: str) -> str:
    """The exact text between a key and its value in this file, e.g. ': ' or ' : '."""
    key_start, value_start, _ = layout.spans[key]
    key_text_end = key_start + len(json.dumps(key))
    return layout.text[key_text_end:value_start]


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: merge-xcstrings.py %O %A %B [%P]", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = (Path(p) for p in argv[1:4])
    name = argv[4] if len(argv) > 4 else str(ours_path)
    try:
        base_text = base_path.read_text(encoding="utf-8")
        ours_text = ours_path.read_text(encoding="utf-8")
        theirs_text = theirs_path.read_text(encoding="utf-8")
        merged_text, conflicts, planned = merge_catalog_text(base_text, ours_text, theirs_text)
    except json.JSONDecodeError as error:
        print(f"merge-xcstrings: {name}: cannot parse ({error}); falling back", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"merge-xcstrings: {name}: cannot merge ({error}); falling back", file=sys.stderr)
        return 1
    if conflicts:
        print(
            f"merge-xcstrings: {name}: {len(conflicts)} key(s) changed on both sides; "
            "leaving them to the default driver: " + ", ".join(conflicts[:5]),
            file=sys.stderr,
        )
        return 1
    # Assembling text by hand earns a proof that the result is the catalog we
    # planned: valid JSON, with exactly the keys the three-way merge decided on.
    try:
        reparsed = json.loads(merged_text)
    except ValueError as error:
        print(f"merge-xcstrings: {name}: refusing to write invalid JSON ({error})", file=sys.stderr)
        return 1
    if list(reparsed.get("strings", {})) != planned:
        print(f"merge-xcstrings: {name}: merged key set did not match the plan", file=sys.stderr)
        return 1
    ours_path.write_text(merged_text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
