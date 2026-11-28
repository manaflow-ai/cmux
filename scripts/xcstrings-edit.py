#!/usr/bin/env python3
"""Add, replace or remove string catalog (.xcstrings) entries in place, leaving every other byte as it was.

Never load a catalog with json.load and write it back with json.dump: that re-renders every entry (indentation,
spacing, escaping, member order), and a three-key change shows as a whole-file rewrite (cmux#51769, cmux#55547).
This tool splices only the entries it is asked to touch. A new entry is written in the style of the entry it lands
beside: one compact line when that entry is one line, otherwise the same indentation and `": "` or `" : "` spacing.
After every edit it re-reads the file and checks with scripts/cmux-next/check-xcstrings-diff.py that nothing else
moved or changed.

  add CATALOG KEY --en "English" [--comment "for translators"]       one English-only entry (manual extraction)
  add CATALOG KEY --entry '{"comment": ..., "localizations": {...}}'  one entry with its full record
  add CATALOG --entries-file new.json                                 every key of a JSON object, in its order
      [--after KEY | --before KEY]  where they go (default: after the last entry)
      [--replace]                   a key that exists takes the new record where it stands (else it is refused)
  remove CATALOG KEY [KEY ...]                                        delete entries (a missing key is refused)

A table kept as one file per key (`<Table>.xcstrings.d/`, scripts/cmux-next/string_catalogs.py) is edited by its
files: CATALOG is the directory, or the old table path beside it. `add` writes each new key's file, `--replace`
rewrites one, `remove` deletes them; --after and --before do not apply (a directory has no order).

For translations of keys the code already uses, ./scripts/localize-changes prepares and imports them in place too.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

CHECKER_PATH = Path(__file__).resolve().parent / "cmux-next" / "check-xcstrings-diff.py"
CATALOGS_PATH = Path(__file__).resolve().parent / "cmux-next" / "string_catalogs.py"


def _load_checker():
    spec = importlib.util.spec_from_file_location("check_xcstrings_diff", CHECKER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


CHECK = _load_checker()


def _string_catalogs():
    spec = importlib.util.spec_from_file_location("string_catalogs", CATALOGS_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def table_directory(catalog: Path) -> Path | None:
    """The one-file-per-key directory CATALOG names: itself, or `<CATALOG>.d` beside an old table path."""
    if catalog.name.endswith(".xcstrings.d") and catalog.is_dir():
        return catalog
    beside = catalog.with_name(catalog.name + ".d")
    return beside if not catalog.exists() and beside.is_dir() else None


def edit_directory(directory: Path, args) -> int:
    sc = _string_catalogs()
    if args.command == "add":
        if args.after or args.before:
            raise EditError(f"{directory}: a one-file-per-key table has no order; drop --after/--before")
        items = _items(args)
        header = sc.load(directory)
        header = {"sourceLanguage": header["sourceLanguage"], "version": header["version"]}
        for key, value in items:
            path = sc.entry_file(directory, key)
            if path.exists() and not args.replace:
                raise EditError(f"{key} exists ({path}); pass --replace to replace it")
        for key, value in items:
            sc.write_if_changed(sc.entry_file(directory, key), sc.entry_text(key, value, header))
        touched = [key for key, _ in items]
    else:
        missing = [key for key in args.keys if not sc.entry_file(directory, key).exists()]
        if missing:
            raise EditError(f"no such key(s) in {directory}: {', '.join(missing)}")
        for key in args.keys:
            sc.entry_file(directory, key).unlink()
        touched = list(args.keys)
    print(f"xcstrings-edit: {args.command} {len(touched)} key(s) in {directory}")
    return 0


class EditError(Exception):
    pass


def _line_indent(text: str, index: int) -> str:
    """The whitespace that starts the line holding INDEX."""
    line_start = text.rfind("\n", 0, index) + 1
    end = line_start
    while end < len(text) and text[end] in " \t":
        end += 1
    return text[line_start:end]


def render_entry(catalog, model, key: str, value: dict) -> str:
    """`"key": value` in the style of MODEL, an existing entry of CATALOG (or a two-space nested default)."""
    text = catalog.text
    if model is None:
        return json.dumps(key, ensure_ascii=False) + ": " + json.dumps(value, ensure_ascii=False, indent=2).replace(
            "\n", "\n    ")
    model_value = text[model.value_start:model.end]
    joiner = text[model.start + len(json.dumps(model.key, ensure_ascii=False)):model.value_start]
    if not joiner.strip() == ":":
        joiner = ": "
    ascii_only = "\\u" in model_value and all(ord(char) < 128 for char in model_value)
    if "\n" not in model_value:
        colon = ":" if '":"' in model_value or "\":{" in model_value else (" : " if '" : ' in model_value else ": ")
        comma = "," if colon == ":" else ", "
        body = json.dumps(value, ensure_ascii=ascii_only, separators=(comma, colon))
    else:
        base = _line_indent(text, model.start)
        first_inner = model_value.index("\n") + 1
        inner = _line_indent(model_value, first_inner)
        step = max(len(inner) - len(base), 1)
        colon = " : " if '" : ' in model_value else ": "
        body = json.dumps(value, ensure_ascii=ascii_only, indent=step, separators=(",", colon))
        body = body.replace("\n", "\n" + base)
    return json.dumps(key, ensure_ascii=ascii_only) + joiner + body


def _separator(catalog, near: int | None) -> str:
    """The text between two entries: the one after entry NEAR, else the first pair's, else a newline and 4 spaces."""
    entries, text = catalog.entries, catalog.text
    if len(entries) >= 2:
        index = near if near is not None and near + 1 < len(entries) else (near - 1 if near else 0)
        index = max(0, min(index, len(entries) - 2))
        return text[entries[index].end:entries[index + 1].start]
    if entries:
        return ",\n" + _line_indent(text, entries[0].start)
    return ",\n    "


def add_entries(text: str, items: list[tuple[str, dict]], after: str | None = None, before: str | None = None,
                replace: bool = False) -> str:
    if after is not None and before is not None:
        raise EditError("pass --after or --before, not both")
    for key, value in items:
        if not isinstance(value, dict):
            raise EditError(f"{key}: an entry's record is a JSON object")
    catalog = CHECK.parse(text)
    position = {entry.key: index for index, entry in enumerate(catalog.entries)}
    anchor = after if after is not None else before
    if anchor is not None and anchor not in position:
        raise EditError(f"no entry {anchor!r} to place the new keys beside")
    if anchor is not None and anchor in dict(items):
        raise EditError(f"{anchor!r} cannot be both the anchor and a key being added")
    seen: set[str] = set()
    for key, _ in items:
        if key in seen:
            raise EditError(f"{key!r} is given twice")
        seen.add(key)
    changes: list[tuple[int, int, str]] = []
    new_items: list[tuple[str, dict]] = []
    for key, value in items:
        if key in position:
            if not replace:
                raise EditError(f"{key!r} already exists; pass --replace to take the new record where it stands")
            entry = catalog.entries[position[key]]
            rendered = render_entry(catalog, entry, key, value)
            changes.append((entry.start, entry.end, rendered))
        else:
            new_items.append((key, value))
    if new_items:
        entries = catalog.entries
        if not entries:
            lead = catalog.text[catalog.open_index + 1:catalog.close_index]
            indent = "\n    "
            closing = lead if lead.strip() == "" and "\n" in lead else "\n  "
            body = ("," + indent).join(render_entry(catalog, None, key, value) for key, value in new_items)
            changes.append((catalog.open_index + 1, catalog.close_index, indent + body + closing))
        else:
            if before is not None:
                index = position[before]
                model = entries[index]
                separator = _separator(catalog, index - 1 if index else 0)
                rendered = [render_entry(catalog, model, key, value) for key, value in new_items]
                changes.append((model.start, model.start, separator.join(rendered) + separator))
            else:
                index = position[after] if after is not None else len(entries) - 1
                model = entries[index]
                separator = _separator(catalog, index)
                rendered = [render_entry(catalog, model, key, value) for key, value in new_items]
                changes.append((model.end, model.end, "".join(separator + block for block in rendered)))
    return _apply(text, changes)


def remove_entries(text: str, keys: list[str]) -> str:
    catalog = CHECK.parse(text)
    entries = catalog.entries
    position = {entry.key: index for index, entry in enumerate(entries)}
    missing = [key for key in keys if key not in position]
    if missing:
        raise EditError(f"no entr{'y' if len(missing) == 1 else 'ies'} {', '.join(map(repr, missing))}")
    drop = sorted({position[key] for key in keys})
    keep = [index for index in range(len(entries)) if index not in set(drop)]
    if not keep:
        lead_end = entries[0].start
        tail_start = entries[-1].end
        lead = text[catalog.open_index + 1:lead_end]
        tail = text[tail_start:catalog.close_index]
        return text[:catalog.open_index + 1] + (tail if "\n" in tail else lead.rstrip(" \t")) + text[catalog.close_index:]
    changes: list[tuple[int, int, str]] = []
    # A run of dropped entries from the first: cut up to the first kept entry, so it starts where the first did.
    leading = keep[0]
    if leading:
        changes.append((entries[0].start, entries[leading].start, ""))
    # Any other entry takes the separator before it with it, so its neighbours keep their own separators.
    changes.extend((entries[index - 1].end, entries[index].end, "") for index in drop if index > leading)
    return _apply(text, _merge_overlaps(changes))


def _merge_overlaps(changes: list[tuple[int, int, str]]) -> list[tuple[int, int, str]]:
    merged: list[tuple[int, int, str]] = []
    for start, end, replacement in sorted(changes):
        if merged and start <= merged[-1][1]:
            previous = merged[-1]
            merged[-1] = (previous[0], max(previous[1], end), "")
        else:
            merged.append((start, end, replacement))
    return merged


def _apply(text: str, changes: list[tuple[int, int, str]]) -> str:
    pieces: list[str] = []
    cursor = 0
    for start, end, replacement in sorted(changes, key=lambda change: (change[0], change[1])):
        if start < cursor:
            raise EditError("overlapping edits")
        pieces.extend((text[cursor:start], replacement))
        cursor = end
    pieces.append(text[cursor:])
    return "".join(pieces)


def verify(old: str, new: str, touched: set[str]) -> None:
    """NEW parses, and against OLD only TOUCHED keys changed (the guard CI runs, applied to this one edit)."""
    catalog = CHECK.parse(new)
    found = CHECK.problems(old, new)
    if found:
        raise EditError("the edit would re-serialize the catalog: " + "; ".join(found))
    old_doc = json.loads(old)["strings"]
    changed = {key for key in set(old_doc) | set(catalog.doc["strings"])
               if old_doc.get(key) != catalog.doc["strings"].get(key)}
    if not changed <= touched:
        raise EditError(f"keys changed that were not asked for: {sorted(changed - touched)[:5]}")


def atomic_write(path: Path, text: str) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _items(args) -> list[tuple[str, dict]]:
    if args.entries_file is not None:
        if args.key or args.en is not None or args.entry is not None:
            raise EditError("--entries-file takes no KEY, --en or --entry")
        with open(args.entries_file, encoding="utf-8") as handle:
            records = json.load(handle)  # a dict keeps the file's key order
        if not isinstance(records, dict):
            raise EditError("--entries-file must hold a JSON object of key: record")
        return list(records.items())
    if not args.key:
        raise EditError("give KEY with --en or --entry, or --entries-file")
    if (args.en is None) == (args.entry is None):
        raise EditError("give exactly one of --en or --entry")
    if args.entry is not None:
        value = json.loads(args.entry)
    else:
        value = {"extractionState": "manual",
                 "localizations": {"en": {"stringUnit": {"state": "translated", "value": args.en}}}}
        if args.comment:
            value = {"comment": args.comment, **value}
    return [(args.key, value)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    add.add_argument("catalog", type=Path)
    add.add_argument("key", nargs="?")
    add.add_argument("--en")
    add.add_argument("--comment")
    add.add_argument("--entry")
    add.add_argument("--entries-file")
    add.add_argument("--after")
    add.add_argument("--before")
    add.add_argument("--replace", action="store_true")
    remove = sub.add_parser("remove")
    remove.add_argument("catalog", type=Path)
    remove.add_argument("keys", nargs="+")
    args = parser.parse_args(argv)
    directory = table_directory(args.catalog)
    if directory is not None:
        try:
            return edit_directory(directory, args)
        except (EditError, ValueError, OSError) as error:
            print(f"xcstrings-edit: {error}", file=sys.stderr)
            return 1
    try:
        old = args.catalog.read_bytes().decode("utf-8")  # not read_text: it would turn CRLF into LF
        if args.command == "add":
            items = _items(args)
            new = add_entries(old, items, args.after, args.before, args.replace)
            touched = {key for key, _ in items}
        else:
            new = remove_entries(old, args.keys)
            touched = set(args.keys)
        verify(old, new, touched)
    except (EditError, ValueError, OSError) as error:
        print(f"xcstrings-edit: {error}", file=sys.stderr)
        return 1
    if new != old:
        atomic_write(args.catalog, new)
    print(f"xcstrings-edit: {args.command} {len(touched)} key(s) in {args.catalog}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
