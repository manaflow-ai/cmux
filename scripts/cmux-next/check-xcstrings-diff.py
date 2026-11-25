#!/usr/bin/env python3
"""Refuse an .xcstrings change that re-serializes the catalog instead of adding, removing or editing keys.

A string catalog is one JSON object of entries. A change should touch only the entries it means to: add a key,
remove one, edit one's value. A tool or a merge that re-renders the file moves or reformats every other entry, and
the diff no longer shows the change: cmux#51769 added 3 keys and showed +147,735 -133,744 in
webviews/src/agent-session/acpmux/Localizable.xcstrings, because its merges of feat-cmux-next ran an older trusted
merge driver (main's copy, installed in the clone's git dir) that kept the branch's text and order over the base's
(cmux#55547).

For each changed catalog, against the old copy:

- the keys both copies have stay in the same order (a key that moved is reported);
- an entry whose value did not change keeps its exact text (indentation, spacing, escaping, locale order);
- the text between two entries that stay neighbours, and the text around the entries, keep their form.

New keys may go anywhere and take any form. Add and remove keys in place with scripts/xcstrings-edit.py.

Modes:
  staged             the pre-commit hook: each staged catalog against HEAD's (MERGE_HEAD's in a merge: the
                     result keeps the merged-in branch's text and order for every key this side did not change)
  range BASE HEAD    CI and the pre-push gate: each catalog BASE..HEAD changes, BASE's copy against HEAD's
                     (--merge-base: compare against merge-base(BASE, HEAD) instead)
  files OLD NEW      two files

An intentional reformat passes with an `Xcstrings-Reformat: <why>` trailer on a commit of the range (range mode;
it exempts every catalog of that range, so put the reformat in its own pull request)
or CMUX_XCSTRINGS_REFORMAT_REASON="<why>" (any mode). Exit 0: clean; 1: a re-serialized catalog; 2: usage.
Runs on the Mac's /usr/bin/python3 (3.9): standard library only, nothing loaded from beside it.
"""
from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import subprocess
import sys
from typing import NamedTuple

DECODER = json.JSONDecoder()
WHITESPACE = " \t\r\n"
TRAILER = re.compile(r"^Xcstrings-Reformat:[ \t]*(\S.*)$", re.MULTILINE)
ENV_REASON = "CMUX_XCSTRINGS_REFORMAT_REASON"
SHOWN = 5


class Entry(NamedTuple):
    key: str
    start: int  # the key's opening quote
    value_start: int
    end: int  # one past the value


class Catalog(NamedTuple):
    text: str
    doc: dict
    entries: list  # [Entry] inside "strings", in file order
    open_index: int  # the `{` of "strings"
    close_index: int  # its `}`


def _skip(text: str, index: int) -> int:
    while index < len(text) and text[index] in WHITESPACE:
        index += 1
    return index


def scan_object(text: str, open_index: int) -> tuple[list[Entry], int]:
    """The members of the object whose `{` is at OPEN_INDEX, and the offset of its `}`, without re-serializing."""
    if text[open_index] != "{":
        raise ValueError(f"expected an object at offset {open_index}")
    index = open_index + 1
    found: list[Entry] = []
    while True:
        index = _skip(text, index)
        if index >= len(text):
            raise ValueError("unterminated object")
        char = text[index]
        if char == "}":
            return found, index
        if char == ",":
            index += 1
            continue
        if char != '"':
            raise ValueError(f"expected a key at offset {index}, found {char!r}")
        start = index
        key, index = DECODER.raw_decode(text, index)
        index = _skip(text, index)
        if index >= len(text) or text[index] != ":":
            raise ValueError(f"expected ':' after key {key!r}")
        index = _skip(text, index + 1)
        value_start = index
        _, index = DECODER.raw_decode(text, index)
        found.append(Entry(key, start, value_start, index))


def parse(text: str) -> Catalog:
    doc = json.loads(text)
    if not isinstance(doc, dict) or not isinstance(doc.get("strings"), dict):
        raise ValueError("not a string catalog (no \"strings\" object)")
    top, _ = scan_object(text, text.index("{"))
    strings = [member for member in top if member.key == "strings"]
    if len(strings) != 1:
        raise ValueError("expected exactly one \"strings\" member")
    entries, close_index = scan_object(text, strings[0].value_start)
    return Catalog(text, doc, entries, strings[0].value_start, close_index)


def _block(catalog: Catalog, entry: Entry) -> str:
    return catalog.text[entry.start:entry.end]


def _moved(old_keys: list[str], new_keys: list[str]) -> list[str]:
    """Keys of NEW_KEYS (all also in OLD_KEYS) outside one longest run that keeps OLD_KEYS' order."""
    position = {key: index for index, key in enumerate(old_keys)}
    sequence = [position[key] for key in new_keys]
    tails: list[int] = []
    tail_at: list[int] = []
    parent = [-1] * len(sequence)
    for index, value in enumerate(sequence):
        slot = bisect.bisect_left(tails, value)
        if slot == len(tails):
            tails.append(value)
            tail_at.append(index)
        else:
            tails[slot] = value
            tail_at[slot] = index
        parent[index] = tail_at[slot - 1] if slot else -1
    kept: set[int] = set()
    index = tail_at[-1] if tail_at else -1
    while index >= 0:
        kept.add(index)
        index = parent[index]
    return [key for index, key in enumerate(new_keys) if index not in kept]


def _same(old_value, new_value) -> bool:
    """The same JSON value; exact, where Python's == calls true and 1, or 1 and 1.0, equal."""
    return json.dumps(old_value, sort_keys=True) == json.dumps(new_value, sort_keys=True)


def _sample(keys: list[str]) -> str:
    shown = ", ".join(keys[:SHOWN])
    return shown + (f" and {len(keys) - SHOWN} more" if len(keys) > SHOWN else "")


def problems(old_text: str, new_text: str) -> list[str]:
    """How NEW_TEXT re-serializes OLD_TEXT beyond adding, removing and editing entries; empty when it does not."""
    try:
        old = parse(old_text)
    except ValueError:
        return []  # nothing to preserve
    try:
        new = parse(new_text)
    except ValueError as error:
        return [f"not a valid string catalog: {error}"]
    found: list[str] = []
    old_by_key = {entry.key: entry for entry in old.entries}
    new_by_key = {entry.key: entry for entry in new.entries}
    old_shared = [entry.key for entry in old.entries if entry.key in new_by_key]
    new_shared = [entry.key for entry in new.entries if entry.key in old_by_key]
    if old_shared != new_shared:
        moved = _moved(old_shared, new_shared)
        found.append(f"{len(moved)} existing key(s) moved: {_sample(moved)}")
    old_values, new_values = old.doc["strings"], new.doc["strings"]
    rewritten = [key for key in new_shared
                 if _block(old, old_by_key[key]) != _block(new, new_by_key[key])
                 and _same(old_values.get(key), new_values.get(key))]
    if rewritten:
        found.append(f"{len(rewritten)} existing entr{'y' if len(rewritten) == 1 else 'ies'} rewritten with no value "
                     f"change (indentation, spacing, escaping or member order): {_sample(rewritten)}")
    # The text between two entries that are neighbours in both copies.
    old_next = {a.key: (b.key, old.text[a.end:b.start]) for a, b in zip(old.entries, old.entries[1:])}
    respaced = [a.key for a, b in zip(new.entries, new.entries[1:])
                if old_next.get(a.key, (None,))[0] == b.key and old_next[a.key][1] != new.text[a.end:b.start]]
    if respaced:
        found.append(f"the separator after {len(respaced)} entr{'y' if len(respaced) == 1 else 'ies'} changed: "
                     f"{_sample(respaced)}")
    # The text around the entries: everything outside "strings", and the lead and tail inside it.
    def frame(catalog: Catalog) -> tuple[str, str]:
        head_end = catalog.entries[0].start if catalog.entries else catalog.close_index
        tail_start = catalog.entries[-1].end if catalog.entries else catalog.close_index
        return catalog.text[:head_end], catalog.text[tail_start:]
    others = lambda doc: {k: v for k, v in doc.items() if k != "strings"}  # noqa: E731
    if old.entries and new.entries and others(old.doc) == others(new.doc):
        (old_head, old_tail), (new_head, new_tail) = frame(old), frame(new)
        if old_head != new_head:
            found.append("the text before the first entry changed (header re-serialized)")
        if old_tail != new_tail:
            found.append("the text after the last entry changed (footer re-serialized)")
    return found


# --- git -------------------------------------------------------------------------------------------------------


def git(*args: str, check: bool = True) -> bytes:
    result = subprocess.run(["git", *args], capture_output=True)
    if check and result.returncode != 0:
        raise SystemExit(f"check-xcstrings-diff: git {' '.join(args)} failed: "
                         f"{result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def blob(spec: str) -> str | None:
    result = subprocess.run(["git", "cat-file", "blob", spec], capture_output=True)
    return result.stdout.decode("utf-8", "replace") if result.returncode == 0 else None


def catalogs_changed(*diff_args: str) -> list[str]:
    out = git("diff", "--name-only", "--no-renames", "--diff-filter=M", "-z", *diff_args, "--", "*.xcstrings")
    return sorted(name for name in out.decode().split("\0") if name.endswith(".xcstrings"))


def report(results: dict[str, list[str]], base_label: str) -> int:
    bad = {path: found for path, found in results.items() if found}
    if not bad:
        return 0
    print(f"check-xcstrings-diff: {len(bad)} string catalog(s) re-serialized against {base_label} "
          "(a change should only add, remove or edit entries; cmux#55547):", file=sys.stderr)
    for path, found in bad.items():
        for line in found:
            print(f"  {path}: {line}", file=sys.stderr)
    print("Fix: take the old copy's text back (git checkout <base> -- <catalog>) and add or remove your keys in place\n"
          "with scripts/xcstrings-edit.py (or ./scripts/localize-changes). After a base merge, rerun\n"
          "scripts/install-git-hooks.sh from a feat-cmux-next checkout so the trusted merge driver is current, then\n"
          "redo the merge. A deliberate reformat: an `Xcstrings-Reformat: <why>` commit trailer, or\n"
          f"{ENV_REASON}=\"<why>\" for this run.", file=sys.stderr)
    return 1


def env_override() -> bool:
    reason = os.environ.get(ENV_REASON, "").strip()
    if reason:
        print(f"check-xcstrings-diff: skipped ({ENV_REASON}: {reason})", file=sys.stderr)
    return bool(reason)


def run_staged() -> int:
    paths = catalogs_changed("--cached")
    if not paths:
        return 0
    merging = subprocess.run(["git", "rev-parse", "-q", "--verify", "MERGE_HEAD"], capture_output=True).returncode == 0
    reference = "MERGE_HEAD" if merging else "HEAD"
    results: dict[str, list[str]] = {}
    for path in paths:
        old, new = blob(f"{reference}:{path}"), blob(f":{path}")
        if old is not None and new is not None:
            results[path] = problems(old, new)
    return report(results, reference)


def run_range(base: str, head: str, merge_base: bool) -> int:
    if merge_base:
        fork = git("merge-base", base, head, check=False).decode().strip()
        if not fork:
            print(f"check-xcstrings-diff: no merge base of {base} and {head}; nothing checked", file=sys.stderr)
            return 0
        base = fork
    paths = catalogs_changed(base, head)
    if not paths:
        return 0
    messages = git("log", "--format=%B%x00", f"{base}..{head}", check=False).decode(errors="replace")
    trailer = TRAILER.search(messages)
    if trailer:
        print(f"check-xcstrings-diff: skipped (Xcstrings-Reformat: {trailer.group(1).strip()})", file=sys.stderr)
        return 0
    results: dict[str, list[str]] = {}
    for path in paths:
        old, new = blob(f"{base}:{path}"), blob(f"{head}:{path}")
        if old is not None and new is not None:
            results[path] = problems(old, new)
    return report(results, base[:12])


def run_files(old_path: str, new_path: str) -> int:
    with open(old_path, encoding="utf-8", newline="") as handle:
        old = handle.read()
    with open(new_path, encoding="utf-8", newline="") as handle:
        new = handle.read()
    return report({new_path: problems(old, new)}, old_path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("staged")
    ranged = sub.add_parser("range")
    ranged.add_argument("base")
    ranged.add_argument("head")
    ranged.add_argument("--merge-base", action="store_true")
    pair = sub.add_parser("files")
    pair.add_argument("old")
    pair.add_argument("new")
    args = parser.parse_args(argv)
    if env_override():
        return 0
    if args.mode == "staged":
        return run_staged()
    if args.mode == "range":
        return run_range(args.base, args.head, args.merge_base)
    return run_files(args.old, args.new)


if __name__ == "__main__":
    sys.exit(main())
