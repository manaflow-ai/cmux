#!/usr/bin/env python3
"""Git merge driver for Xcode string catalogs (.xcstrings).

A string catalog is one large JSON object keyed by string id. Two branches that
each add a different key collide positionally even though the keys are disjoint,
because both insertions land in the same region of the file. On
Resources/Localizable.xcstrings (~6,700 entries) that produced 42 conflict
hunks in a single pull request, none of them a semantic disagreement.

This driver merges per key instead of per line. It is deliberately conservative:
when the same key is changed on both sides it exits non-zero after materializing
a visible diff3 conflict in %A, so a real disagreement is never resolved
silently or mistaken for an ours-only file.

Formatting is preserved by construction. The driver never re-serializes the
document; it locates the byte span of each key's `"key": value` pair and
assembles the result from those spans verbatim, taking each key's text from
whichever side supplies it. Catalogs in this repository are written in at least
three different styles (nested two-space, compacted leaf objects, and Xcode's
`"key" : value` spacing), and a branch often carries a different style from
main, so re-rendering would rewrite formatting the driver does not own.

Usage (git passes these): merge-xcstrings.py %O %A %B %P %L
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
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


def _canonical(value: object) -> str:
    """Type-strict identity for JSON values: `True` and `1` are different edits."""
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


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
        base_key, ours_key, theirs_key = (_canonical(v) for v in (base_value, ours_value, theirs_value))
        ours_changed = ours_key != base_key if in_base else in_ours
        theirs_changed = theirs_key != base_key if in_base else in_theirs
        if not in_ours and not in_theirs:
            continue
        if ours_changed and theirs_changed:
            if in_ours == in_theirs and ours_key == theirs_key:
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


def explicit_conflict(base: str, ours: str, theirs: str, width: int = 7) -> str:
    """A visible whole-file conflict when line-level merging is unavailable."""
    return (
        f"{'<' * width} ours\n{ours.rstrip()}\n"
        f"{'|' * width} base\n{base.rstrip()}\n"
        f"{'=' * width}\n{theirs.rstrip()}\n"
        f"{'>' * width} theirs\n"
    )


def explicit_conflict_bytes(base: bytes, ours: bytes, theirs: bytes, width: int = 7) -> bytes:
    """The byte-preserving equivalent used when one side is not UTF-8."""
    return (
        b"<" * width + b" ours\n" + ours.rstrip() + b"\n"
        + b"|" * width + b" base\n" + base.rstrip() + b"\n"
        + b"=" * width + b"\n" + theirs.rstrip() + b"\n"
        + b">" * width + b" theirs\n"
    )


def conflict_text(base: str, ours: str, theirs: str, width: int = 7) -> str:
    """Prefer a line-level diff3 conflict and fall back to an explicit one."""
    marker_prefixes = tuple(character * width for character in "<|=>")
    if any(
        line.startswith(marker_prefixes)
        for text in (base, ours, theirs)
        for line in text.splitlines()
    ):
        return explicit_conflict(base, ours, theirs, width)

    # Keep this helper self-contained. A merge driver can run against an
    # untrusted checkout, so importing another checked-out helper would grant
    # that branch code execution.
    try:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_path = root / "base"
            ours_path = root / "ours"
            theirs_path = root / "theirs"
            base_path.write_text(base, encoding="utf-8")
            ours_path.write_text(ours, encoding="utf-8")
            theirs_path.write_text(theirs, encoding="utf-8")
            result = subprocess.run(
                [
                    "git",
                    "merge-file",
                    "--diff3",
                    f"--marker-size={width}",
                    "-L",
                    "ours",
                    "-L",
                    "base",
                    "-L",
                    "theirs",
                    "-p",
                    str(ours_path),
                    str(base_path),
                    str(theirs_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        merged = result.stdout
    except (OSError, UnicodeError):
        return explicit_conflict(base, ours, theirs, width)

    if result.returncode <= 1 and any(
        line.startswith(marker_prefixes) for line in merged.splitlines()
    ):
        return merged
    return explicit_conflict(base, ours, theirs, width)


def _read_bytes(path: Path, label: str) -> tuple[bytes, OSError | None]:
    try:
        return path.read_bytes(), None
    except OSError as error:
        return f"[merge-xcstrings could not read {label}: {error}]\n".encode(), error


def _materialize_conflict(
    path: Path, base: str, ours: str, theirs: str, width: int, name: str
) -> None:
    try:
        path.write_text(conflict_text(base, ours, theirs, width), encoding="utf-8")
    except OSError as error:
        print(f"merge-xcstrings: {name}: cannot materialize conflict ({error})", file=sys.stderr)


def _materialize_conflict_bytes(
    path: Path, base: bytes, ours: bytes, theirs: bytes, width: int, name: str
) -> None:
    try:
        path.write_bytes(explicit_conflict_bytes(base, ours, theirs, width))
    except OSError as error:
        print(f"merge-xcstrings: {name}: cannot materialize conflict ({error})", file=sys.stderr)


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: merge-xcstrings.py %O %A %B [%P] [%L]", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = (Path(p) for p in argv[1:4])
    name = argv[4] if len(argv) > 4 else str(ours_path)
    try:
        marker_size = max(1, int(argv[5])) if len(argv) > 5 else 7
    except ValueError:
        marker_size = 7
    base_bytes, base_error = _read_bytes(base_path, "base")
    ours_bytes, ours_error = _read_bytes(ours_path, "ours")
    theirs_bytes, theirs_error = _read_bytes(theirs_path, "theirs")
    read_errors = [error for error in (base_error, ours_error, theirs_error) if error is not None]
    if read_errors:
        _materialize_conflict_bytes(ours_path, base_bytes, ours_bytes, theirs_bytes, marker_size, name)
        print(f"merge-xcstrings: {name}: cannot read merge inputs ({read_errors[0]}); falling back", file=sys.stderr)
        return 1
    try:
        base_text = base_bytes.decode("utf-8")
        ours_text = ours_bytes.decode("utf-8")
        theirs_text = theirs_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        _materialize_conflict_bytes(ours_path, base_bytes, ours_bytes, theirs_bytes, marker_size, name)
        print(f"merge-xcstrings: {name}: merge input is not UTF-8 ({error}); falling back", file=sys.stderr)
        return 1
    try:
        merged_text, conflicts, planned = merge_catalog_text(base_text, ours_text, theirs_text)
    except json.JSONDecodeError as error:
        _materialize_conflict(ours_path, base_text, ours_text, theirs_text, marker_size, name)
        print(f"merge-xcstrings: {name}: cannot parse ({error}); falling back", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        _materialize_conflict(ours_path, base_text, ours_text, theirs_text, marker_size, name)
        print(f"merge-xcstrings: {name}: cannot merge ({error}); falling back", file=sys.stderr)
        return 1
    if conflicts:
        _materialize_conflict(ours_path, base_text, ours_text, theirs_text, marker_size, name)
        print(
            f"merge-xcstrings: {name}: {len(conflicts)} key(s) changed on both sides; "
            "materializing a conflict: " + ", ".join(conflicts[:5]),
            file=sys.stderr,
        )
        return 1
    # Assembling text by hand earns a proof that the result is the catalog we
    # planned: valid JSON, with exactly the keys the three-way merge decided on.
    try:
        reparsed = json.loads(merged_text)
    except ValueError as error:
        _materialize_conflict(ours_path, base_text, ours_text, theirs_text, marker_size, name)
        print(f"merge-xcstrings: {name}: refusing to write invalid JSON ({error})", file=sys.stderr)
        return 1
    if list(reparsed.get("strings", {})) != planned:
        _materialize_conflict(ours_path, base_text, ours_text, theirs_text, marker_size, name)
        print(f"merge-xcstrings: {name}: merged key set did not match the plan", file=sys.stderr)
        return 1
    ours_path.write_text(merged_text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
