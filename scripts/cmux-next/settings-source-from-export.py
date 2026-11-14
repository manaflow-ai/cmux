#!/usr/bin/env python3
"""Draft schemas/settings/source rows from the exported settings schema (cx-d5b5d).

Moving a group of hand-written Swift settings rows into a source JSON is mostly copying what
schemas/settings/settings-schema.json already says about them. This prints those rows in the
source format scripts/cmux-next/gen-settings-sources.py reads (see its docstring), in export
order, as {"lists": [...]}: one list per run of rows with the same section and group.

    python3 scripts/cmux-next/settings-source-from-export.py tabs.overflow tabs.plusButton
    python3 scripts/cmux-next/settings-source-from-export.py --swift-type BrowserPasswordsSetting

--swift-type T picks the rows whose title catalog key is written in a CmuxNextSettings Swift file
that declares or extends T (the hand-written rows of that type). What the export does not carry,
the draft leaves to you: each row's `swift_owner` and `swift_enum` (the Swift names the parsers
use), `note`, `name` when two rows of a list end in the same key part, the reason of a row kept
off the Settings page but not the palette (`palette_shown`), and `aliases`. Check the drafted
`consumers`: SettingsSchema.sharedWithBrowser adds cmux-browser to its keys in Swift, so those
rows need none.
"""
import argparse, json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
EXPORT = "schemas/settings/settings-schema.json"
SETTINGS_SOURCES = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"


def swift_type_title_keys(type_name, root=ROOT):
    """The quoted strings of every CmuxNextSettings Swift file that declares or extends `type_name`."""
    pattern = re.compile(r"\b(enum|struct|class|extension)\s+%s\b" % re.escape(type_name))
    strings = set()
    for folder, _, files in os.walk(os.path.join(root, SETTINGS_SOURCES)):
        for name in files:
            if not name.endswith(".swift"):
                continue
            with open(os.path.join(folder, name), encoding="utf-8") as handle:
                text = handle.read()
            if pattern.search(text):
                strings.update(re.findall(r'"((?:[^"\\\n]|\\.)*)"', text))
    return strings


def draft_row(row):
    """One export row in the source format (the Swift-only fields left out)."""
    out = {"key": row["key"]}
    for field in ("title", "help", "summary"):
        if row.get(field):
            out[field] = row[field]
    kind = row["kind"]
    if kind == "string_list" and "choices" in row:
        kind = "ordered_choices" if row.get("ordered") else "choice_set"
    out["kind"] = kind
    if "choices" in row:
        out["choices"] = [{"value": choice["value"], "title": choice["title"]} for choice in row["choices"]]
    if "range" in row:
        rng = row["range"]
        out["range"] = {field: rng[field] for field in ("min", "max", "step", "unit")}
        if rng.get("placeholder", rng["min"]) != rng["min"]:
            out["range"]["placeholder"] = rng["placeholder"]
    if "url_key" in row:
        out["url_key"] = row["url_key"]
    out["default"] = row["default"]
    for field in ("default_label", "placeholder"):
        if row.get(field):
            out[field] = row[field]
    out["keywords"] = row.get("keywords", [])
    if row.get("consumers", ["cmux-next"]) != ["cmux-next"]:
        out["consumers"] = row["consumers"]
    palette = row.get("surfaces", {}).get("palette", {})
    reason = palette.get("reason")
    if row.get("page_hidden"):
        out["page_hidden"] = reason or "TODO: the reason (the export does not carry it when the palette offers the row)"
        if palette.get("offered"):
            out["palette_shown"] = True
    elif palette.get("offered") is False and reason and reason != "not_consumed_by_cmux_next":
        out["palette_hidden"] = reason
    return out


def list_name(group_key, taken):
    base = (group_key or "rows").split(".")[-1]
    base = re.sub(r"[^A-Za-z0-9]", "", base) or "rows"
    base = base[:1].lower() + base[1:]
    name, index = base, 2
    while name in taken:
        name, index = "%s%d" % (base, index), index + 1
    taken.add(name)
    return name


def draft(rows):
    """{"lists": [...]}: runs of rows with the same section and group, in the order given."""
    lists, taken = [], set()
    for row in rows:
        group = row["group"]
        if not lists or lists[-1]["section"] != row["section"] or lists[-1]["group"] != group:
            lists.append({"name": list_name(group.get("key"), taken), "section": row["section"], "group": group, "rows": []})
        drafted = draft_row(row)
        names = {r.get("name", r["key"].split(".")[-1]) for r in lists[-1]["rows"]}
        last = row["key"].split(".")[-1]
        if last in names:
            parts = row["key"].split(".")
            drafted = {"key": row["key"], "name": parts[-2] + parts[-1][:1].upper() + parts[-1][1:], **{k: v for k, v in drafted.items() if k != "key"}}
        lists[-1]["rows"].append(drafted)
    return {"lists": lists}


def select(export_rows, keys=(), swift_types=(), root=ROOT):
    wanted = set(keys)
    strings = set()
    for type_name in swift_types:
        found = swift_type_title_keys(type_name, root)
        if not found:
            raise SystemExit("no CmuxNextSettings Swift file declares or extends %s" % type_name)
        strings |= found
    picked = [row for row in export_rows if row["key"] in wanted or (row.get("title") or {}).get("key") in strings]
    missing = wanted - {row["key"] for row in picked}
    if missing:
        raise SystemExit("not in %s: %s" % (EXPORT, ", ".join(sorted(missing))))
    return picked


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("keys", nargs="*", help="dotted setting keys")
    parser.add_argument("--swift-type", action="append", default=[], help="a Swift schema type whose rows to draft")
    parser.add_argument("--export", default=os.path.join(ROOT, EXPORT), help="the settings schema export to read")
    args = parser.parse_args(argv)
    if not args.keys and not args.swift_type:
        parser.error("name keys or --swift-type")
    with open(args.export, encoding="utf-8") as handle:
        rows = json.load(handle)["rows"]
    picked = select(rows, args.keys, args.swift_type)
    if not picked:
        raise SystemExit("no rows matched")
    sys.stdout.write(json.dumps(draft(picked), indent=2, ensure_ascii=False) + "\n")
    print("drafted %d rows; add swift_owner / swift_enum per row (see gen-settings-sources.py)" % len(picked), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
