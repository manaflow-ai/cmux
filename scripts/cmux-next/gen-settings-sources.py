#!/usr/bin/env python3
"""Write the generated copies of the hand-edited settings sources in schemas/settings (cx-d5b5d).

schemas/settings is the one hand-edited source of the cmux-next settings data that more than one
layer reads. The daemon (cmux-tui/crates/cmux-config) embeds the JSON with include_str!; this
script writes the copies the app's Swift modules compile in. Sources so far:

- schemas/settings/retired-keys.json: cmux.json keys cmux no longer reads, with why
  (Swift: SettingsSchema+RetiredKeys.generated.swift, `SettingsSchema.retiredKeys`).
- schemas/settings/source/<section>.json: the rows of one settings section. Swift gets the
  descriptors AND the parser constants (paths, defaults, ranges, choice values and enums, legacy
  aliases), so a value has one definition. schemas/settings/generator/<section>.json maps the file to
  its Swift schema type and each list's static var and owner type (one file per section).
  schemas/settings/settings-schema.json is still exported from Swift (SettingsSchemaExportTests);
  moving a section must not change it.
  scripts/cmux-next/settings-source-from-export.py drafts rows from that export.
- schemas/settings/source/sections.json: the Settings sections in sidebar order (Swift: the
  SettingsSection enum, SettingsSection.generated.swift). Every row's section must be listed there.
- schemas/settings/source/page-layout.json: the Settings page layout (categories, group cards, their
  order and titles, sidebar sections, default category, dev_only) and each section's action buttons
  (Swift: SettingsPageLayout and SettingsSchema.actions(in:), SettingsSchema+PageLayout*.generated.swift).
  The export resolves it against the rows into settings-schema.json's `page`
  (SettingsPageLayout+Categories.swift).
- schemas/settings/source/agent-policy.json: which keys an agent may change, and why not
  (Swift: SettingsSchema+AgentPolicy.generated.swift). Every row of a section source needs a group.
- schemas/settings/source/row-facts.json: the keys Reset All keeps and cmux-browser shares, and each
  row's validation domain (Swift: SettingsSchema+RowFacts.generated.swift).
- schemas/settings/source/samples.json: the values per row kind and validation domain a validator
  must accept and refuse (Swift: SettingsSchema+Samples.generated.swift; the export's accepts/refuses).

A section source is {"$comment", "lists": [list]}. A list is one `static var` of the schema type:
{name, section, group: text, note?, rows: [row]}; SettingsSchema.all concatenates the lists, so a
group whose rows are not contiguous in the export is two lists with the same group text. A section
whose rows span several groups may name a `joined` var in its generator file: the generator writes it as the
concatenation of every list in source order, so its readers keep one var (`descriptors`). A text is
{key, text}: key is the string catalog key, or null for text that is not translated (a product
name, a syntax example). A row:

  key            dotted cmux.json path (unique across every source)
  name           identifier for the row's constants; default the last path part
  note           developer note (doc comment of the constants and a generated enum), never shown
  title          text; help, summary, default_label, placeholder: optional texts (placeholder is
                 what an empty list field shows)
  kind           toggle | number | choice | choice_or_number | choice_or_url | color | sound | url |
                 host_list | folder_list | time_range | theme | font_family | text | number_list |
                 string_map | sound_rules | string_list | ordered_choices | choice_set
                 (the SettingKind cases; ordered_choices and choice_set export as a string_list with
                 choices and `ordered`)
  choices        [{value, title: text, note?, swift_case?}]: choice, choice_or_number,
                 choice_or_url, ordered_choices and choice_set rows, and only those. On a row with a
                 hand-written swift_enum, "swift_case": null marks a value that is no case of the
                 enum (the descriptor writes the string; it cannot be the default)
  choices_from   choice kinds: "Type.member", a Swift [SettingChoice] listed after `choices`, for
                 choices another source defines (a catalog in Swift, another schemas table);
                 `choices` may then be empty, and the default may be one of them
  range          {min, max, step, unit, placeholder?}: number, choice_or_number and number_list rows;
                 unit is points | milliseconds | seconds | minutes | days | count | fraction;
                 placeholder (default min) is where the control sits while a null default is unset
  url_key        choice_or_url only: the object member that holds the address
  default        required; the value an absent key means, or null when it is derived at run time
                 (then name it in default_label)
  aliases        {old value: choice value}: older values a generated enum reads (legacyValues)
  keywords       extra words the Settings search matches
  consumers      apps that read the key, ["cmux-next"] when absent (e.g. ["cmux-browser", "cmux-next"])
  page_hidden    reason: kept off the Settings page and the palette (hiddenFromSettingsPage)
  palette_shown  true beside page_hidden: off the page only, still in the palette (keptOffSettingsPage)
  palette_hidden reason: kept off the palette only (hiddenFromPalette)
  swift_enum     choice kinds: {name, generated (default true)}. Generated: this script writes the
                 enum (cases from the values in camel case, or each choice's swift_case; doc from
                 note) into <file>Choices*.generated.swift, at most 3 per file. generated false: a
                 hand-written enum (it has logic, more cases, or lives in another module; it may be
                 nested, `Outer.Inner`); the
                 descriptor names its cases (`Enum.case.rawValue`) and the default is typed by it;
                 module names the module that declares it when that is not CmuxNextSettings (the
                 generated files `public import` it).
                 Absent: plain string values, plus a `values` constant.
  swift_owner    the type that gets the row's constants. Absent: the list's owner type from
                 its generator file, with prefixed names (<name>Path, <name>Default, <name>Range,
                 <name>Placeholder, <name>Values). "Type": that type with plain names (configPath,
                 fallback, range, placeholder, values), the hand-written parser's own names.
                 {"type": "Type", "prefixed": true}: that type with prefixed names.

A row's constants: the path ([String]); the default when not null (Bool, Double, String, the enum,
[String], [Double], else a JSONValue); the range (ClosedRange<Double>) and placeholder (Double) of a
range kind; the values ([String]) of a choice kind with no swift_enum. The hand-written parser
reads them, so no default literal is left in Swift. A section's Swift stays one file while it fits
in MAX_LINES lines; past that it is split into <file>2.generated.swift and on (a list too long for
one file becomes <var>Part1 + <var>Part2...), so a source of any size keeps the god-file limits.
The constants are `public` when the owner type is: an owner declared without `public` in
CmuxNextSettings (a section type, or a hand-written internal parser) gets internal constants, since
a public constant on an internal type can name a type that is itself internal.

A generated Swift file this script no longer writes (for example a choices file after a section
lost its choice rows) counts as drift under --check and is deleted when writing.

    python3 scripts/cmux-next/gen-settings-sources.py           # write the copies
    python3 scripts/cmux-next/gen-settings-sources.py --check   # exit 1 when a copy drifted
"""
import json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
RETIRED_SOURCE = "schemas/settings/retired-keys.json"
RETIRED_SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+RetiredKeys.generated.swift"
HEADER = "GENERATED by scripts/cmux-next/gen-settings-sources.py from\n{c} {src}. Do not edit; edit the JSON and rerun."


def swift_string(text):
    """A Swift string literal: JSON escapes for quote and backslash; no other escapes allowed."""
    if any(ord(ch) < 0x20 for ch in text):
        raise SystemExit("control character in %r: Swift copy would need a \\u{} escape" % text)
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def load_retired():
    with open(os.path.join(ROOT, RETIRED_SOURCE), encoding="utf-8") as handle:
        data = json.load(handle)
    entries = data["retired"]
    seen = set()
    for entry in entries:
        if set(entry) - {"key", "reason", "why"} or not {"key", "reason"} <= set(entry):
            raise SystemExit("%s: entry needs key, reason (and optional why): %r" % (RETIRED_SOURCE, entry))
        key = entry["key"]
        parts = key.split(".")
        if not key or any(not part for part in parts):
            raise SystemExit("%s: bad dotted key %r" % (RETIRED_SOURCE, key))
        if key in seen:
            raise SystemExit("%s: duplicate key %r" % (RETIRED_SOURCE, key))
        if not entry["reason"].strip():
            raise SystemExit("%s: empty reason for %r" % (RETIRED_SOURCE, key))
        for field in ("key", "reason", "why"):
            if any(ord(ch) < 0x20 for ch in entry.get(field, "")):
                raise SystemExit("%s: control character in %s of %r" % (RETIRED_SOURCE, field, key))
        seen.add(key)
    return entries


def retired_swift(entries):
    rows = []
    for entry in entries:
        if entry.get("why"):
            rows.append("        // " + entry["why"])
        rows.append("        %s: %s," % (swift_string(entry["key"]), swift_string(entry["reason"])))
    return """// {header}

extension SettingsSchema {{
    /// cmux.json keys cmux used to read and no longer does, with why. The
    /// loader drops them without a diagnostic (an old file keeps loading
    /// cleanly), the schema export and Settings never list them, and a
    /// write through `settings.set` or the palette is refused as removed
    /// (`SettingRetired`), not as unknown.
    public static let retiredKeys: [String: String] = [
{rows}
    ]
}}
""".format(header=HEADER.format(c="//", src=RETIRED_SOURCE), rows="\n".join(rows))


# Swift names per section source, one file per source in schemas/settings/generator/<stem>.json (one
# file each, so two PRs that add sections never edit the same lines): the source, the generated Swift
# file, the schema type, and each list's static var and the type that owns its rows' constants
# (null: every row of the list names its own `swift_owner`). `joined` (optional) names a static var
# that concatenates every list in source order. A choice row's Swift enum is the row's `swift_enum`
# (see the module docstring). Output does not depend on the order, so the files load sorted by name.
SCHEMA_DIR = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema"
SECTIONS_SOURCE = "schemas/settings/source/sections.json"
SECTIONS_SWIFT = SCHEMA_DIR + "/SettingsSection.generated.swift"
GENERATOR_DIR = "schemas/settings/generator"
GENERATOR_FIELDS = {"source", "swift", "type", "lists", "joined"}


def load_generator_sections():
    """SECTIONS, read from GENERATOR_DIR: each file names its own source, Swift file and lists."""
    sections = []
    for name in sorted(os.listdir(os.path.join(ROOT, GENERATOR_DIR))):
        if not name.endswith(".json"):
            continue
        src = GENERATOR_DIR + "/" + name
        with open(os.path.join(ROOT, src), encoding="utf-8") as handle:
            entry = json.load(handle)
        if not isinstance(entry, dict) or not {"source", "swift", "type", "lists"} <= set(entry) <= GENERATOR_FIELDS:
            fail(src, "fields are source, swift, type, lists and an optional joined")
        if entry["source"] != "schemas/settings/source/" + name or not entry["swift"].startswith(SCHEMA_DIR + "/") \
                or not entry["swift"].endswith(".generated.swift"):
            fail(src, "source is schemas/settings/source/%s and swift a .generated.swift file in %s" % (name, SCHEMA_DIR))
        lists = entry["lists"]
        if not isinstance(lists, dict) or not lists or not all(
                isinstance(value, list) and len(value) == 2 and isinstance(value[0], str)
                and (value[1] is None or isinstance(value[1], str)) for value in lists.values()):
            fail(src, "lists maps each list name to [static var, owner type or null]")
        entry["lists"] = {key: tuple(value) for key, value in lists.items()}
        sections.append(entry)
    return sections


SYMBOL = __import__("re").compile(r"^[a-z0-9]+(\.[a-z0-9]+)*$")
MEMBER = __import__("re").compile(r"^[A-Z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*$")
UNITS = {"points", "milliseconds", "seconds", "minutes", "days", "count", "fraction"}
ROW_FIELDS = {"key", "name", "note", "title", "help", "summary", "kind", "choices", "choices_from", "range", "url_key", "default",
              "default_label", "placeholder", "aliases", "keywords", "consumers", "palette_hidden", "page_hidden",
              "palette_shown", "swift_enum", "swift_owner"}
IDENT = __import__("re").compile(r"^[a-z][A-Za-z0-9]*$")
TYPE = __import__("re").compile(r"^[A-Z][A-Za-z0-9]*$")
# A hand-written enum may be nested in another type (`SidebarNavigationSettings.Scope`).
NESTED_TYPE = __import__("re").compile(r"^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$")
# Each source kind and its SettingKind case (None: the case takes arguments, built in kind_swift).
KINDS = {"toggle": ".toggle", "number": None, "choice": None, "choice_or_number": None, "choice_or_url": None,
         "color": ".color", "sound": ".sound", "url": ".url", "host_list": ".hostList", "folder_list": ".folderList",
         "time_range": ".timeRange", "theme": ".theme", "font_family": ".fontFamily", "text": ".text",
         "number_list": None, "string_map": ".stringMap", "sound_rules": ".soundRules", "string_list": ".stringList",
         "ordered_choices": None, "choice_set": None}
CHOICE_KINDS = {"choice", "choice_or_number", "choice_or_url", "ordered_choices", "choice_set"}
RANGE_KINDS = {"number", "choice_or_number", "number_list"}
CONSUMERS = {"cmux-next": ".cmuxNext", "cmux-browser": ".cmuxBrowser"}
# A generated Swift file holds at most this many lines (check-no-godfiles.sh allows 400).
MAX_LINES = 390


def fail(src, message):
    raise SystemExit("%s: %s" % (src, message))


def check_text(src, where, text, optional=False):
    """{key, text}; key is a string catalog key, or null for text that is not translated."""
    if text is None and optional:
        return
    if not isinstance(text, dict) or set(text) != {"key", "text"} or not text["text"] or text["key"] == "":
        fail(src, "%s needs {key, text} (key null when not translated): %r" % (where, text))
    for value in text.values():
        if value is not None and (any(ord(ch) < 0x20 for ch in value) or "\\(" in value):
            fail(src, "%s has a control character or an interpolation: %r" % (where, value))


SWIFT_KEYWORDS = {"associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
                  "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows",
                  "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default",
                  "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch",
                  "where", "while", "as", "any", "catch", "false", "is", "nil", "super", "self", "Self", "throw",
                  "throws", "true", "try"}
# Names that stay special even after a dot (`Enum.self`), so no enum case may take them.
DOT_RESERVED = {"self", "Self", "init", "Type", "Protocol"}


def check_note(src, where, note):
    if note is not None and (not isinstance(note, str) or any(ord(ch) < 0x20 for ch in note)):
        fail(src, "%s: note is one line of text" % where)


def camel(value):
    parts = value.split("-")
    name = parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])
    if not IDENT.match(name) or name in DOT_RESERVED:
        raise SystemExit("choice value %r gives no Swift case name: give the choice a swift_case" % value)
    return name


def no_case(choice):
    """Whether a hand-written enum's row lists this value with no case of the enum ("swift_case": null)."""
    return "swift_case" in choice and choice["swift_case"] is None


def case_name(choice):
    """The Swift case of a choice: its swift_case, else the value in camel case."""
    name = choice.get("swift_case") or camel(choice["value"])
    if not IDENT.match(name) or name in DOT_RESERVED:
        raise SystemExit("bad swift_case %r" % name)
    return name


def number_literal(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SystemExit("not a number: %r" % value)
    if float(value).is_integer():
        whole = int(value)
        return "{:_}".format(whole) if abs(whole) >= 10000 else str(whole)
    return repr(float(value))


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def json_swift(value):
    """A JSONValue literal of `value`."""
    if value is None:
        return ".null"
    if isinstance(value, bool):
        return ".bool(%s)" % ("true" if value else "false")
    if is_number(value):
        return ".number(%s)" % number_literal(value)
    if isinstance(value, str):
        return ".string(%s)" % swift_string(value)
    if isinstance(value, list):
        return ".array([%s])" % ", ".join(json_swift(item) for item in value)
    if not value:
        return ".object([:])"
    return ".object([%s])" % ", ".join("%s: %s" % (swift_string(k), json_swift(v)) for k, v in value.items())


def load_sections():
    """The section list; ids are lowercase identifiers, unique, in sidebar order."""
    src = SECTIONS_SOURCE
    with open(os.path.join(ROOT, src), encoding="utf-8") as handle:
        data = json.load(handle)
    if set(data) - {"$comment", "sections"} or not data.get("sections"):
        fail(src, "needs a non-empty sections list")
    ids = []
    for entry in data["sections"]:
        if set(entry) != {"id", "title", "symbol"}:
            fail(src, "a section has exactly id, title, symbol: %r" % entry)
        if not IDENT.match(entry["id"]) or entry["id"] in ids or entry["id"] in SWIFT_KEYWORDS:
            fail(src, "bad or duplicate section id %r" % entry["id"])
        if not SYMBOL.match(entry["symbol"]):
            fail(src, "bad symbol %r" % entry["symbol"])
        check_text(src, entry["id"] + ".title", entry["title"])
        if entry["title"]["key"] != "settings.section." + entry["id"]:
            fail(src, "%s: the title key is settings.section.<id> (SettingsSection.titleKey)" % entry["id"])
        ids.append(entry["id"])
    return data["sections"]


def sections_swift(sections):
    def cases(body):
        return "\n".join("        case .%s: %s" % (entry["id"], body(entry)) for entry in sections)
    return """// {header}

/// The Settings window's sections, in sidebar order. The raw value is the
/// `section` argument of Settings… (`cmux settings open --section keyboard`).
public nonisolated enum SettingsSection: String, Sendable, Hashable, CaseIterable, Identifiable {{
    case {ids}

    public var id: String {{ rawValue }}

    /// The string catalog key of `title`.
    public var titleKey: String {{ "settings.section.\\(rawValue)" }}

    public var title: String {{
        switch self {{
{titles}
        }}
    }}

    /// SF Symbol for the sidebar row.
    public var symbol: String {{
        switch self {{
{symbols}
        }}
    }}
}}
""".format(header=HEADER.format(c="//", src=SECTIONS_SOURCE), ids=", ".join(e["id"] for e in sections),
           titles=cases(lambda e: "SettingsText.text(%s, %s)" % (swift_string(e["title"]["key"]), swift_string(e["title"]["text"]))),
           symbols=cases(lambda e: swift_string(e["symbol"])))


def constant_names(row, list_owner):
    """(owner type, {constant: Swift name}) of a row: see `swift_owner` in the module docstring."""
    owner, prefixed = list_owner, True
    spec = row.get("swift_owner")
    if isinstance(spec, str):
        owner, prefixed = spec, False
    elif isinstance(spec, dict):
        owner, prefixed = spec["type"], spec.get("prefixed", False)
    if prefixed:
        name = row["_name"]
        return owner, {part: name + part[:1].upper() + part[1:] for part in ("path", "default", "range", "placeholder", "values")}
    return owner, {"path": "configPath", "default": "fallback", "range": "range", "placeholder": "placeholder", "values": "values"}


def check_default(src, key, kind, row, values):
    """The default fits the kind; null means a default derived at run time."""
    default, rng = row["default"], row.get("range") or {}
    if default is None:
        return
    in_range = is_number(default) and rng.get("min", default) <= default <= rng.get("max", default)
    strings = isinstance(default, list) and all(isinstance(item, str) and item.strip() for item in default)
    if row.get("choices_from") and isinstance(default, str):
        values = values + [default]  # one of the Swift-listed choices: the Swift type checks it
    ok = {
        "toggle": isinstance(default, bool),
        "number": in_range,
        "choice": default in values,
        "choice_or_number": default in values or in_range,
        "choice_or_url": default in values or (isinstance(default, dict) and set(default) == {row.get("url_key")}),
        "ordered_choices": isinstance(default, list) and all(item in values for item in default),
        "choice_set": isinstance(default, list) and all(item in values for item in default),
        "string_list": strings,
        "host_list": strings,
        "folder_list": strings and all(item.startswith("/") or item.startswith("~/") for item in default),
        "number_list": isinstance(default, list) and all(is_number(item) and rng["min"] <= item <= rng["max"] for item in default),
        "string_map": isinstance(default, dict) and all(isinstance(item, str) for item in default.values()),
        "sound_rules": isinstance(default, dict),
        "time_range": isinstance(default, dict),
        "text": True,
    }.get(kind, isinstance(default, str))
    if not ok:
        fail(src, "%s: default %r does not fit a %s row" % (key, default, kind))


def check_row(src, row, seen_keys, idents):
    """Validates one source row and records its constant name in row["_name"]."""
    key = row.get("key", "")
    if set(row) - ROW_FIELDS:
        fail(src, "%s: unknown fields %s" % (key, sorted(set(row) - ROW_FIELDS)))
    if not key or any(not part for part in key.split(".")) or key in seen_keys:
        fail(src, "bad or duplicate key %r" % key)
    seen_keys.add(key)
    name = row.get("name", key.split(".")[-1])
    if not IDENT.match(name) or name in idents:
        fail(src, "%s: bad or duplicate name %r" % (key, name))
    idents.add(name)
    row["_name"] = name
    check_note(src, key, row.get("note"))
    check_text(src, key + ".title", row.get("title"))
    for field in ("help", "summary", "default_label", "placeholder"):
        check_text(src, key + "." + field, row.get(field), optional=True)
    kind = row.get("kind")
    if kind not in KINDS:
        fail(src, "%s: unknown kind %r (one of %s)" % (key, kind, sorted(KINDS)))
    if "default" not in row:
        fail(src, "%s: default is required (null: derived at run time, name it in default_label)" % key)
    if ("choices" in row) != (kind in CHOICE_KINDS) or ("range" in row) != (kind in RANGE_KINDS):
        fail(src, "%s: a %s row has %s" % (key, kind, " and ".join(
            (["choices"] if kind in CHOICE_KINDS else []) + (["range"] if kind in RANGE_KINDS else [])) or "no choices or range"))
    if ("url_key" in row) != (kind == "choice_or_url"):
        fail(src, "%s: url_key belongs to choice_or_url rows, which need it" % key)
    values = []
    if kind in CHOICE_KINDS:
        values = [choice.get("value") for choice in row["choices"]]
        if (not values and not row.get("choices_from")) or len(set(values)) != len(values) \
                or not all(isinstance(v, str) and v for v in values):
            fail(src, "%s: choices need unique non-empty string values" % key)
        for choice in row["choices"]:
            if set(choice) - {"value", "title", "note", "swift_case"}:
                fail(src, "%s choice %r: fields are value, title, note, swift_case" % (key, choice["value"]))
            check_text(src, key + " choice " + choice["value"], choice.get("title"))
            check_note(src, key + " choice " + choice["value"], choice.get("note"))
    if kind in RANGE_KINDS:
        rng = row["range"]
        if set(rng) - {"min", "max", "step", "unit", "placeholder"} or not {"min", "max", "step", "unit"} <= set(rng) \
                or rng["unit"] not in UNITS or not rng["min"] <= rng["max"]:
            fail(src, "%s: range needs min <= max, step, unit (one of %s), optional placeholder" % (key, sorted(UNITS)))
    if "choices_from" in row and (kind not in CHOICE_KINDS or not isinstance(row["choices_from"], str)
                                  or not MEMBER.match(row["choices_from"])):
        fail(src, "%s: choices_from is \"Type.member\" on a choice row" % key)
    check_default(src, key, kind, row, values)
    enum = row.get("swift_enum")
    if enum is not None:
        if kind not in CHOICE_KINDS or not isinstance(enum, dict) or set(enum) - {"name", "generated", "module"} \
                or not (TYPE if enum.get("generated", True) else NESTED_TYPE).match(enum.get("name", "")) \
                or not isinstance(enum.get("generated", True), bool) \
                or ("module" in enum and (enum.get("generated", True) or not TYPE.match(enum["module"]))):
            fail(src, "%s: swift_enum is {name, generated (default true), module (a hand-written enum's module)} on a choice row" % key)
        for choice in row["choices"]:
            if no_case(choice):
                if enum.get("generated", True) or choice["value"] == row["default"]:
                    fail(src, "%s choice %r: swift_case null needs a hand-written enum and a value that is not the default"
                         % (key, choice["value"]))
                continue
            case_name(choice)
    elif any(no_case(choice) for choice in row.get("choices", [])):
        fail(src, "%s: swift_case null belongs to rows with a hand-written swift_enum" % key)
    if "aliases" in row:
        if kind != "choice" or not enum or not enum.get("generated", True):
            fail(src, "%s: only choice rows with a generated swift_enum have aliases" % key)
        for old, new in row["aliases"].items():
            if new not in values or old in values:
                fail(src, "%s: alias %r -> %r must map an old value to a choice" % (key, old, new))
    owner = row.get("swift_owner")
    if owner is not None and not (isinstance(owner, str) and TYPE.match(owner)) and not (
            isinstance(owner, dict) and set(owner) <= {"type", "prefixed"} and TYPE.match(owner.get("type", ""))
            and isinstance(owner.get("prefixed", False), bool)):
        fail(src, "%s: swift_owner is a type name or {type, prefixed}" % key)
    consumers = row.get("consumers")
    if consumers is not None and (not consumers or not set(consumers) <= set(CONSUMERS) or len(set(consumers)) != len(consumers)):
        fail(src, "%s: consumers is a non-empty list of %s" % (key, sorted(CONSUMERS)))
    for field in ("palette_hidden", "page_hidden"):
        if field in row and (not isinstance(row[field], str) or not row[field].strip()):
            fail(src, "%s: %s is the reason, one line of text" % (key, field))
    if "palette_shown" in row and (row["palette_shown"] is not True or "page_hidden" not in row or "palette_hidden" in row):
        fail(src, "%s: palette_shown is true, only beside page_hidden (and never with palette_hidden)" % key)
    if not isinstance(row.get("keywords", []), list) or not all(isinstance(k, str) for k in row.get("keywords", [])):
        fail(src, "%s: keywords is a list of strings" % key)


def check_section(section, data, seen_keys, section_ids, src):
    if set(data) - {"$comment", "lists"}:
        fail(src, "unknown top-level fields %s" % sorted(set(data) - {"$comment", "lists"}))
    names = [entry["name"] for entry in data["lists"]]
    if sorted(names) != sorted(section["lists"]):
        fail(src, "lists %s do not match its generator file's lists %s" % (names, sorted(section["lists"])))
    list_vars = [var for var, _ in section["lists"].values()]
    if len(set(list_vars)) != len(list_vars) or section.get("joined") in list_vars:
        fail(src, "each list has its own var in its generator file, and the joined var is none of them")
    for entry in data["lists"]:
        if entry["section"] not in section_ids:
            fail(src, "unknown section %r" % entry["section"])
        check_text(src, entry["name"] + ".group", entry["group"])
        check_note(src, entry["name"], entry.get("note"))
        idents = set()
        for row in entry["rows"]:
            check_row(src, row, seen_keys, idents)
            if section["lists"][entry["name"]][1] is None and "swift_owner" not in row:
                fail(src, "%s: list %s has no owner type in its generator file, so the row needs a swift_owner" % (row["key"], entry["name"]))
    return data


def load_section(section, seen_keys, section_ids):
    src = section["source"]
    with open(os.path.join(ROOT, src), encoding="utf-8") as handle:
        data = json.load(handle)
    return check_section(section, data, seen_keys, section_ids, src)


def keyed(text):
    if text["key"] is None:
        return "SettingText(key: nil, text: %s)" % swift_string(text["text"])
    return "SettingsText.keyed(%s, %s)" % (swift_string(text["key"]), swift_string(text["text"]))


def doc(text, indent):
    return "%s/// %s\n" % (indent, text) if text else ""


def generated_enum(row):
    enum = row.get("swift_enum")
    return enum["name"] if enum and enum.get("generated", True) else None


def choices_swift(section, data):
    """{path: text} of the choice enum files, at most 3 enums per file (check-no-godfiles.sh)."""
    rows = [row for entry in data["lists"] for row in entry["rows"] if generated_enum(row)]
    files = {}
    for index in range(0, len(rows), 3):
        suffix = "Choices" if index == 0 else "Choices%d" % (index // 3 + 1)
        path = section["swift"].replace(".generated.swift", suffix + ".generated.swift")
        files[path] = enums_swift(section, rows[index:index + 3])
    return files


def enums_swift(section, rows):
    out = ["// " + HEADER.format(c="//", src=section["source"]), ""]
    for row in rows:
        enum = generated_enum(row)
        out.append(doc(row.get("note"), "").rstrip("\n") or "/// The values of `%s`." % row["key"])
        out.append("public nonisolated enum %s: String, Sendable, Hashable, CaseIterable {" % enum)
        for choice in row["choices"]:
            case = case_name(choice)
            if choice.get("note"):
                out.append("    /// " + choice["note"])
            declared = "`%s`" % case if case in SWIFT_KEYWORDS else case
            out.append("    case %s%s" % (declared, "" if case == choice["value"] else " = " + swift_string(choice["value"])))
        if row.get("aliases"):
            out.append("")
            out.append("    /// Values older files may hold, read as their replacement without a")
            out.append("    /// diagnostic.")
            pairs = ", ".join("%s: .%s" % (swift_string(old), case_name(next(c for c in row["choices"] if c["value"] == new)))
                              for old, new in sorted(row["aliases"].items()))
            out.append("    static let legacyValues: [String: Self] = [%s]" % pairs)
        out.append("}")
        out.append("")
    return "\n".join(out[:-1]) + "\n"


def default_constant(row):
    """(Swift type annotation or None, literal, descriptor default expression with {c} for the constant), or None."""
    default, kind = row["default"], row["kind"]
    enum = row.get("swift_enum")
    if default is None:
        return None
    if isinstance(default, bool):
        return None, "true" if default else "false", ".bool({c})"
    if enum and isinstance(default, str) and kind in ("choice", "choice_or_number", "choice_or_url"):
        # A default among the Swift-listed choices (choices_from) is the value's camel-case case.
        choice = next((c for c in row["choices"] if c["value"] == default), {"value": default})
        return enum["name"], "." + case_name(choice), ".string({c}.rawValue)"
    if is_number(default):
        return "Double", number_literal(default), ".number({c})"
    if isinstance(default, str):
        return None, swift_string(default), ".string({c})"
    if isinstance(default, list) and kind == "number_list" and all(is_number(item) for item in default):
        return "[Double]", "[%s]" % ", ".join(number_literal(item) for item in default), ".array({c}.map { .number($0) })"
    if isinstance(default, list) and all(isinstance(item, str) for item in default):
        return "[String]", "[%s]" % ", ".join(swift_string(item) for item in default), ".array({c}.map { .string($0) })"
    return "JSONValue", json_swift(default), "{c}"


SETTINGS_SWIFT_DIR = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
_TYPE_ACCESS = {}


def owner_is_public(owner):
    """True when CmuxNextSettings declares `owner` public (or does not declare it: a public type of
    an imported module). A section type the generator declares itself is internal."""
    if owner in {section["type"] for section in SECTIONS if section.get("type")}:
        return False
    if not _TYPE_ACCESS:
        decl = re.compile(r"^\s*((?:public|package|internal|fileprivate|private|open)\s+)?"
                          r"(?:(?:nonisolated|final|indirect)\s+)*(?:enum|struct|class|actor)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
        for base, _, files in os.walk(os.path.join(ROOT, SETTINGS_SWIFT_DIR)):
            for name in sorted(files):
                if not name.endswith(".swift") or name.endswith(".generated.swift"):
                    continue
                with open(os.path.join(base, name)) as handle:
                    for line in handle:
                        match = decl.match(line)
                        if match:
                            _TYPE_ACCESS.setdefault(match.group(2), (match.group(1) or "").strip() in ("public", "open"))
        _TYPE_ACCESS.setdefault("", True)
    return _TYPE_ACCESS.get(owner.split(".")[-1], True)


def constants_swift(row, names, public=True):
    """The parser constants of one row, as lines of an extension body."""
    kind, out = row["kind"], []
    access = "    public " if public else "    "
    out.append("    /// `%s`%s" % (row["key"], (": " + row["note"]) if row.get("note") else "."))
    out.append(access + "nonisolated static let %s = [%s]" % (names["path"], ", ".join(swift_string(p) for p in row["key"].split("."))))
    constant = default_constant(row)
    if constant:
        swift_type, literal, _ = constant
        out.append(access + "nonisolated static let %s%s = %s" % (names["default"], ": " + swift_type if swift_type else "", literal))
    if kind in RANGE_KINDS:
        rng = row["range"]
        out.append(access + "nonisolated static let %s: ClosedRange<Double> = %s...%s"
                   % (names["range"], number_literal(rng["min"]), number_literal(rng["max"])))
        if "placeholder" in rng:
            out.append(access + "nonisolated static let %s: Double = %s" % (names["placeholder"], number_literal(rng["placeholder"])))
    if kind in CHOICE_KINDS and not row.get("swift_enum") and not row.get("choices_from"):
        out.append(access + "nonisolated static let %s = [%s]" % (names["values"], ", ".join(swift_string(c["value"]) for c in row["choices"])))
    return out


def kind_swift(row, owner, names):
    kind = row["kind"]
    if KINDS[kind]:
        return KINDS[kind]
    enum = row.get("swift_enum")

    def number():
        rng = row["range"]
        extra = (", placeholder: %s.%s" % (owner, names["placeholder"])) if "placeholder" in rng else ""
        return "SettingNumber(%s.%s, step: %s, unit: .%s%s)" % (owner, names["range"], number_literal(rng["step"]), rng["unit"], extra)

    def choices():
        def title(choice):
            text = choice["title"]
            return swift_string(text["text"]) if text["key"] is None else keyed(text)
        def value(choice):
            return "%s.%s.rawValue" % (enum["name"], case_name(choice)) if enum and not no_case(choice) else swift_string(choice["value"])
        listed = "[%s\n                ]" % "".join("\n                    SettingChoice(%s, %s)," % (value(c), title(c)) for c in row["choices"])
        if row.get("choices_from"):
            return "%s + %s" % (listed, row["choices_from"]) if row["choices"] else row["choices_from"]
        return listed

    return {
        "number": lambda: ".number(%s)" % number(),
        "number_list": lambda: ".numberList(%s)" % number(),
        "choice": lambda: ".choice(%s)" % choices(),
        "ordered_choices": lambda: ".orderedChoices(%s)" % choices(),
        "choice_set": lambda: ".choiceSet(%s)" % choices(),
        "choice_or_number": lambda: ".choiceOrNumber(%s, %s)" % (choices(), number()),
        "choice_or_url": lambda: ".choiceOrURL(%s, urlKey: %s)" % (choices(), swift_string(row["url_key"])),
    }[kind]()


def descriptor_swift(row, section_id, list_owner):
    """The lines of one SettingDescriptor in a list literal."""
    owner, names = constant_names(row, list_owner)
    args = ["%s.%s" % (owner, names["path"]), "section: .%s" % section_id, "group: group", "title: " + keyed(row["title"])]
    if row.get("help"):
        args.append("help: " + keyed(row["help"]))
    if row.get("summary"):
        args.append("summary: " + keyed(row["summary"]))
    args.append("kind: " + kind_swift(row, owner, names))
    constant = default_constant(row)
    args.append("default: " + (constant[2].replace("{c}", "%s.%s" % (owner, names["default"])) if constant else "nil"))
    if row.get("default_label"):
        args.append("defaultLabel: " + keyed(row["default_label"]))
    args.append("keywords: [%s]" % ", ".join(swift_string(k) for k in row.get("keywords", [])))
    if row.get("placeholder"):
        # What the row's empty list field shows (SettingDescriptor.placeholder).
        args.append("placeholder: " + keyed(row["placeholder"]))
    modifiers = ""
    if row.get("consumers") and row["consumers"] != ["cmux-next"]:
        modifiers += ".consumed(by: [%s])" % ", ".join(CONSUMERS[c] for c in row["consumers"])
    if row.get("page_hidden"):
        modifiers += "%s(%s)" % (".keptOffSettingsPage" if row.get("palette_shown") else ".hiddenFromSettingsPage", swift_string(row["page_hidden"]))
    if row.get("palette_hidden"):
        modifiers += ".hiddenFromPalette(%s)" % swift_string(row["palette_hidden"])
    return ["            SettingDescriptor(", "                " + ",\n                ".join(args), "            )%s," % modifiers]


def list_var_swift(var, entry, rows, list_owner):
    """`static var <var>` returning the descriptors of `rows`."""
    out = ["    static var %s: [SettingDescriptor] {" % var, "        let group = %s" % keyed(entry["group"]), "        return ["]
    for row in rows:
        out += descriptor_swift(row, entry["section"], list_owner)
    return out + ["        ]", "    }"]


def joined_var_swift(section, data):
    """`static var <joined>`: every list of the section in source order (SECTIONS `joined`)."""
    names = [section["lists"][entry["name"]][0] for entry in data["lists"]]
    if section["joined"] in names:
        raise SystemExit("%s: joined var %s is also a list's var" % (section["source"], section["joined"]))
    return ["    /// Every list of %s, in order." % section["source"],
            "    static var %s: [SettingDescriptor] {" % section["joined"],
            "        [%s].flatMap { $0 }" % ", ".join(names),
            "    }"]


def line_count(lines):
    return sum(line.count("\n") + 1 for line in lines)


def section_swift(section, data):
    """{path: text} of the section's descriptors and constants: one file while it fits in MAX_LINES lines,
    else split (constants and lists in order, a list too long for a file in parts joined by its var)."""
    header = ["// " + HEADER.format(c="//", src=section["source"]), ""]
    modules = sorted({row["swift_enum"]["module"] for entry in data["lists"] for row in entry["rows"]
                      if row.get("swift_enum", {}).get("module")})
    if modules:
        header += ["public import %s" % module for module in modules] + [""]
    # Parser constants: per list, one extension per owner type, in first-row order.
    constant_blocks = []
    for entry in data["lists"]:
        _, list_owner = section["lists"][entry["name"]]
        blocks = {}
        for row in entry["rows"]:
            owner, names = constant_names(row, list_owner)
            blocks.setdefault(owner, []).extend(constants_swift(row, names, owner_is_public(owner)))
        for owner, lines in blocks.items():
            constant_blocks.append(["extension %s {" % owner] + lines + ["}", ""])
    lists = []
    for entry in data["lists"]:
        var, list_owner = section["lists"][entry["name"]]
        lists.append((["    /// " + entry["note"]] if entry.get("note") else []) + list_var_swift(var, entry, entry["rows"], list_owner))
    if section.get("joined"):
        lists.append(joined_var_swift(section, data))
    intro = ["/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).",
             "nonisolated enum %s {" % section["type"]]
    single = header + [line for block in constant_blocks for line in block] + intro
    for index, lines in enumerate(lists):
        single += ([""] if index else []) + lines
    single.append("}")
    if line_count(single) <= MAX_LINES:
        return {section["swift"]: "\n".join(single) + "\n"}
    # Split: pieces packed in order into files of at most MAX_LINES lines.
    pieces = list(constant_blocks)
    for entry in data["lists"]:
        var, list_owner = section["lists"][entry["name"]]
        note = ["    /// " + entry["note"]] if entry.get("note") else []
        whole = note + list_var_swift(var, entry, entry["rows"], list_owner)
        if line_count(whole) + len(header) + 3 <= MAX_LINES:
            pieces.append(("list", whole))
            continue
        parts, current = [], []
        for row in entry["rows"]:
            trial = current + [row]
            if current and line_count(list_var_swift(var + "Part", entry, trial, list_owner)) + len(header) + 3 > MAX_LINES:
                parts.append(current)
                trial = [row]
            current = trial
        parts.append(current)
        joined = " + ".join("%sPart%d" % (var, n + 1) for n in range(len(parts)))
        pieces.append(("list", note + ["    static var %s: [SettingDescriptor] { %s }" % (var, joined)]))
        for n, rows in enumerate(parts):
            pieces.append(("list", list_var_swift("%sPart%d" % (var, n + 1), entry, rows, list_owner)))
    if section.get("joined"):
        pieces.append(("list", joined_var_swift(section, data)))
    files, current, declared = [], list(header), False
    for piece in pieces:
        if isinstance(piece, tuple):
            body = (intro if not declared else ["extension %s {" % section["type"]]) + piece[1] + ["}", ""]
            declared = True
        else:
            body = piece
        if line_count(current) + line_count(body) > MAX_LINES + 1 and len(current) > len(header):
            files.append(current)
            current = list(header)
        current = current + body
    files.append(current)
    out = {}
    for index, lines in enumerate(files):
        while lines and lines[-1] == "":
            lines = lines[:-1]
        path = section["swift"] if index == 0 else section["swift"].replace(".generated.swift", "%d.generated.swift" % (index + 1))
        out[path] = "\n".join(lines) + "\n"
    return out


def check_constant_names(sections):
    """No two rows define the same constant on the same owner type."""
    seen = {}
    for section, data in sections:
        for entry in data["lists"]:
            _, list_owner = section["lists"][entry["name"]]
            for row in entry["rows"]:
                owner, names = constant_names(row, list_owner)
                for name in (names["path"], names["default"]):
                    where = seen.setdefault((owner, name), row["key"])
                    if where != row["key"]:
                        raise SystemExit("%s and %s both define %s.%s: give one a swift_owner or a name" % (where, row["key"], owner, name))


# The Settings page layout and the section action buttons (schemas/settings/source/page-layout.json).
PAGE_SOURCE = "schemas/settings/source/page-layout.json"
PAGE_SWIFT = SCHEMA_DIR + "/SettingsSchema+PageLayout.generated.swift"
PAGE_CATEGORIES_SWIFT = SCHEMA_DIR + "/SettingsSchema+PageLayoutCategories.generated.swift"
PAGE_FIELDS = {"$comment", "default_category", "max_rows_per_card", "cards", "section_actions", "sidebar_sections"}
PAGE_CATEGORY_FIELDS = {"id", "title", "symbol", "note", "groups", "lead", "trail", "actions", "aliases", "dev_only"}
PAGE_GROUP_FIELDS = {"group", "keys", "lead_keys", "title", "note"}
ACTION_ID = __import__("re").compile(r"^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)*$")


def load_page_layout(section_ids):
    """The page layout, checked: every id it names exists, and no row key is claimed twice."""
    src = PAGE_SOURCE
    with open(os.path.join(ROOT, src), encoding="utf-8") as handle:
        data = json.load(handle)
    if set(data) != PAGE_FIELDS:
        fail(src, "top-level fields are %s" % sorted(PAGE_FIELDS))
    max_rows = data["max_rows_per_card"]
    if isinstance(max_rows, bool) or not isinstance(max_rows, int) or max_rows < 1:
        fail(src, "max_rows_per_card is a positive integer")
    cards = []
    for card in data["cards"]:
        if set(card) - {"id", "note"} or not IDENT.match(card.get("id", "")) or card["id"] in cards \
                or card["id"] in SWIFT_KEYWORDS:
            fail(src, "a card has a unique identifier id and an optional note: %r" % card)
        check_note(src, "card " + card["id"], card.get("note"))
        cards.append(card["id"])
    actions = data["section_actions"]
    if not isinstance(actions, dict) or set(actions) != section_ids:
        fail(src, "section_actions lists every section of sections.json exactly once")
    for section, ids in actions.items():
        if not isinstance(ids, list) or len(set(ids)) != len(ids) or not all(isinstance(i, str) and ACTION_ID.match(i) for i in ids):
            fail(src, "section_actions.%s is a list of unique action ids" % section)
    category_ids, group_keys, claimed = [], set(), set()
    for run in data["sidebar_sections"]:
        if set(run) != {"id", "title", "categories"} or not IDENT.match(run["id"]) or not run["categories"]:
            fail(src, "a sidebar section has id, title (or null) and a non-empty categories list: %r" % run.get("id"))
        check_text(src, run["id"] + ".title", run["title"], optional=True)
        for category in run["categories"]:
            cid = category.get("id", "")
            if set(category) - PAGE_CATEGORY_FIELDS or not {"id", "title", "symbol", "groups"} <= set(category):
                fail(src, "category %r: fields are %s (id, title, symbol, groups required)" % (cid, sorted(PAGE_CATEGORY_FIELDS)))
            if not IDENT.match(cid) or cid in category_ids:
                fail(src, "bad or duplicate category id %r" % cid)
            category_ids.append(cid)
            title = category["title"]
            if isinstance(title, dict) and set(title) == {"section"}:
                if title["section"] not in section_ids:
                    fail(src, "%s: unknown title section %r" % (cid, title["section"]))
            else:
                check_text(src, cid + ".title", title)
            if not SYMBOL.match(category["symbol"]):
                fail(src, "%s: bad symbol %r" % (cid, category["symbol"]))
            check_note(src, cid, category.get("note"))
            for field, known in (("lead", cards), ("trail", cards), ("actions", section_ids), ("aliases", section_ids)):
                values = category.get(field, [])
                if not isinstance(values, list) or len(set(values)) != len(values) or any(v not in known for v in values):
                    fail(src, "%s.%s: unique ids of %s" % (cid, field, "cards" if known is cards else "sections"))
            if not isinstance(category.get("dev_only", False), bool):
                fail(src, "%s.dev_only is a bool" % cid)
            for index, group in enumerate(category["groups"]):
                where = "%s group %d" % (cid, index)
                if set(group) - PAGE_GROUP_FIELDS or not ("group" in group or "title" in group):
                    fail(src, "%s: fields are %s, with a group or a title" % (where, sorted(PAGE_GROUP_FIELDS)))
                key = group.get("group", "%s.%d" % (cid, index))
                if not key or key in group_keys:
                    fail(src, "%s: duplicate card key %r" % (where, key))
                group_keys.add(key)
                check_text(src, where + ".title", group.get("title"), optional=True)
                check_note(src, where, group.get("note"))
                for field in ("lead_keys", "keys"):
                    for row in group.get(field, []):
                        if not isinstance(row, str) or not row or any(not part for part in row.split(".")) or row in claimed:
                            fail(src, "%s: bad row key or a row claimed twice: %r" % (where, row))
                        claimed.add(row)
    if data["default_category"] not in category_ids:
        fail(src, "default_category %r is not a category" % data["default_category"])
    return data


def swift_list(values, render=swift_string):
    return "[" + ", ".join(render(value) for value in values) + "]"


def page_layout_swift(data, sections):
    cards = []
    for card in data["cards"]:
        if card.get("note"):
            cards.append("        /// " + card["note"])
        cards.append("        case %s" % card["id"])
    actions = "\n".join("        case .%s: %s" % (entry["id"], swift_list(data["section_actions"][entry["id"]]))
                        for entry in sections)
    return """// {header}

public import CmuxNextActions

/// The Settings page's navigation (SETTINGS-PAGE-FIRST-PRINCIPLES P2, P4): categories by user
/// task, each a list of group cards, in `sidebarSections` (SettingsSchema+PageLayoutCategories).
/// Exported as the schema's `page` (`SettingsSchemaExport`), resolved by `categories(rows:)`;
/// the web Settings page and the GPUI client render it from the export and copy nothing
/// (layer-ownership.md L5). Every row the page shows has exactly one card.
public nonisolated struct SettingsPageLayout: Sendable {{
    /// A part of a category that is not a schema row (host lists, the theme
    /// studio, file actions). Raw values are the export's card ids.
    public nonisolated enum Card: String, Sendable, Hashable, CaseIterable {{
{cards}
    }}

    /// A group card as the layout states it: rows claimed by key to lead it, the rows
    /// of a schema group (minus rows another card claims), then rows claimed by key.
    public nonisolated struct GroupSpec: Sendable {{
        /// A schema group key: its title, and every row of it no other card claims.
        public var group: String?
        /// Rows by key, moved here from their schema group; `title` names the card then.
        public var keys: [String] = []
        public var title: SettingText?
        /// Rows by key, claimed like `keys` but drawn first, before the schema group's own rows.
        public var leadKeys: [String] = []
    }}

    public nonisolated struct CategorySpec: Sendable {{
        public var id: String
        public var title: SettingText
        public var symbol: String
        public var groups: [GroupSpec]
        /// Cards drawn before the groups, and after them.
        public var lead: [Card] = []
        public var trail: [Card] = []
        /// The sections whose registry buttons (cmux.settings.section.actions) show at the end.
        public var actions: [SettingsSection] = []
        /// The section ids (`cmux settings open --section`, old links) that open this category.
        public var aliases: [SettingsSection] = []
        /// Shown only in DEV builds: the page hides it when the host says it is not one.
        public var devOnly = false
    }}

    /// A titled run of categories in the page's sidebar (the lead run is untitled).
    public nonisolated struct SidebarSection: Sendable {{
        /// A stable id for tests and the export (`look`, `tools`).
        public var id: String
        /// The small header above the run; nil for the untitled lead run.
        public var title: SettingText?
        /// The categories of the run, in sidebar order.
        public var categories: [CategorySpec]
    }}

    /// A resolved group card: its rows in display order.
    public nonisolated struct Group: Sendable, Hashable {{
        public let key: String
        public let title: SettingText
        public let rows: [String]
    }}

    public nonisolated struct Category: Sendable {{
        public let spec: CategorySpec
        public let groups: [Group]
    }}

    public static let defaultCategory = {default}

    /// The most rows one card holds: a longer card is split into titled cards a person can scan.
    /// `SettingsPageSectionsTests` holds it.
    public static let maxRowsPerCard = {max_rows}

    public init() {{}}

    /// Every category in sidebar order: the sections' categories, one after another.
    static var specs: [CategorySpec] {{ sidebarSections.flatMap(\\.categories) }}
}}

extension SettingsSchema {{
    /// Actions shown as buttons at the end of a section (their titles and
    /// availability come from the action registry).
    public static func actions(in section: SettingsSection) -> [ActionID] {{
        switch section {{
{actions}
        }}
    }}
}}
""".format(header=HEADER.format(c="//", src=PAGE_SOURCE), cards="\n".join(cards), default=swift_string(data["default_category"]),
           max_rows=data["max_rows_per_card"], actions=actions)


def page_categories_swift(data):
    def title(text):
        if text is None:
            return "nil"
        if set(text) == {"section"}:
            return "section(.%s)" % text["section"]
        return keyed(text)

    def cases(values):
        return swift_list(values, lambda value: "." + value)

    out = ["// " + HEADER.format(c="//", src=PAGE_SOURCE), "", "extension SettingsPageLayout {",
           "    /// The sidebar's sections: what a person looks for together sits together under one small header.",
           "    public static let sidebarSections: [SidebarSection] = ["]
    for run in data["sidebar_sections"]:
        out.append("        SidebarSection(id: %s, title: %s, categories: %s)," % (
            swift_string(run["id"]), title(run["title"]), swift_list(run["categories"], lambda c: c["id"] + "Category")))
    out += ["    ]", "", "    private static func section(_ section: SettingsSection) -> SettingText {",
            "        SettingText(key: section.titleKey, text: section.title)", "    }"]
    for run in data["sidebar_sections"]:
        for category in run["categories"]:
            out.append("")
            if category.get("note"):
                out.append("    /// " + category["note"])
            out.append("    private static let %sCategory = CategorySpec(" % category["id"])
            out.append("        id: %s, title: %s, symbol: %s," % (
                swift_string(category["id"]), title(category["title"]), swift_string(category["symbol"])))
            if category["groups"]:
                out.append("        groups: [")
                for group in category["groups"]:
                    if group.get("note"):
                        out.append("            // " + group["note"])
                    args = []
                    if "group" in group:
                        args.append("group: " + swift_string(group["group"]))
                    if group.get("keys"):
                        args.append("keys: " + swift_list(group["keys"]))
                    if group.get("title"):
                        args.append("title: " + keyed(group["title"]))
                    if group.get("lead_keys"):
                        args.append("leadKeys: " + swift_list(group["lead_keys"]))
                    out.append("            GroupSpec(%s)," % ", ".join(args))
                out.append("        ]" + ("," if any(category.get(f) for f in ("lead", "trail", "actions", "aliases", "dev_only")) else ""))
            else:
                out.append("        groups: []" + ("," if any(category.get(f) for f in ("lead", "trail", "actions", "aliases", "dev_only")) else ""))
            rest = []
            for field, label in (("lead", "lead"), ("trail", "trail"), ("actions", "actions"), ("aliases", "aliases")):
                if category.get(field):
                    rest.append("%s: %s" % (label, cases(category[field])))
            if category.get("dev_only"):
                rest.append("devOnly: true")
            if rest:
                out.append("        " + ", ".join(rest))
            out.append("    )")
    out.append("}")
    return "\n".join(out) + "\n"


# Per-row facts the schema export writes beside each row's definition: the agent policy, the keys
# Reset All keeps and cmux-browser shares, validation domains and the conformance samples.
POLICY_SOURCE = "schemas/settings/source/agent-policy.json"
POLICY_SWIFT = SCHEMA_DIR + "/SettingsSchema+AgentPolicy.generated.swift"
REFUSALS_SWIFT = SCHEMA_DIR + "/SettingsSchema+AgentRefusals.generated.swift"
FACTS_SOURCE = "schemas/settings/source/row-facts.json"
FACTS_SWIFT = SCHEMA_DIR + "/SettingsSchema+RowFacts.generated.swift"
SAMPLES_SOURCE = "schemas/settings/source/samples.json"
SAMPLES_SWIFT = SCHEMA_DIR + "/SettingsSchema+Samples.generated.swift"
# The export's row kinds, plus choice_list (a string_list row with choices).
SAMPLE_KINDS = {"toggle", "choice", "choice_or_number", "choice_or_url", "number", "color", "sound", "url", "host_list",
                "folder_list", "time_range", "theme", "font_family", "text", "number_list", "string_map", "sound_rules",
                "string_list", "choice_list"}
SAMPLE_TOKENS = {"choices", "choices_reversed", "first_choice", "min", "max", "mid", "below", "above", "url_key"}
DOMAIN = __import__("re").compile(r"^(portable|domain:[a-z][a-z_]*)$")


def load_json(src):
    with open(os.path.join(ROOT, src), encoding="utf-8") as handle:
        return json.load(handle)


def check_key(src, key):
    if not isinstance(key, str) or not key or any(not part for part in key.split(".")) or any(ord(ch) < 0x20 for ch in key):
        fail(src, "bad dotted key %r" % key)


def wrap(items, indent, width=120):
    """Swift literals joined with ", " into lines of at most `width` columns, each ending with a comma."""
    lines, line = [], ""
    for item in items:
        candidate = (line + " " + item + ",") if line else (indent + item + ",")
        if line and len(candidate) > width:
            lines.append(line)
            candidate = indent + item + ","
        line = candidate
    if line:
        lines.append(line)
    return lines


def section_row_keys():
    keys = set()
    for section in SECTIONS:
        for entry in load_json(section["source"])["lists"]:
            keys.update(row["key"] for row in entry["rows"])
    return keys


def load_agent_policy():
    src = POLICY_SOURCE
    data = load_json(src)
    if set(data) != {"$comment", "refusals", "groups"}:
        fail(src, "fields are $comment, refusals, groups")
    reasons = []
    for refusal in data["refusals"]:
        if set(refusal) != {"id", "doc"} or not IDENT.match(refusal["id"]) or refusal["id"] in SWIFT_KEYWORDS \
                or refusal["id"] in reasons or refusal["id"] == "settable":
            fail(src, "a refusal is {id, doc} with a unique identifier id: %r" % refusal)
        check_note(src, refusal["id"], refusal["doc"])
        reasons.append(refusal["id"])
    seen = set()
    for group in data["groups"]:
        if set(group) - {"agent", "why", "keys"} or not group.get("keys"):
            fail(src, "a group is {agent, why, keys} with keys: %r" % group)
        if group["agent"] != "settable" and group["agent"] not in reasons:
            fail(src, "agent %r is settable or a refusal id" % group["agent"])
        check_note(src, "why", group.get("why"))
        for key in group["keys"]:
            check_key(src, key)
            if key in seen:
                fail(src, "%s is in two groups" % key)
            seen.add(key)
    retired = {entry["key"] for entry in load_retired()} & seen
    if retired:
        fail(src, "retired keys have no policy: %s" % sorted(retired))
    missing = section_row_keys() - seen
    if missing:
        fail(src, "rows with no agent policy: %s" % sorted(missing))
    return data


def agent_policy_swift(data):
    cases = []
    for refusal in data["refusals"]:
        cases += ["        /// " + refusal["doc"], "        case " + refusal["id"]]
    settable, refused = [], []
    for group in data["groups"]:
        target = settable if group["agent"] == "settable" else refused
        if group.get("why"):
            target.append("        // " + group["why"])
        if group["agent"] == "settable":
            target += wrap([swift_string(key) for key in group["keys"]], "        ")
        else:
            target += wrap(["%s: .%s" % (swift_string(key), group["agent"]) for key in group["keys"]], "        ")
    header = HEADER.format(c="//", src=POLICY_SOURCE)
    policy = """// {header}

/// Which schema keys an agent may change (MCP `settings_set` and
/// `settings_reset`; plans/cmux-next/settings-react.md section 3). Every key
/// is in exactly one of the two tables (`agentRefusedKeys`:
/// SettingsSchema+AgentRefusals.generated.swift), with no default:
/// `SettingsSchemaExportTests` fails on a key in neither or both, so a new
/// setting cannot reach agents without a decision. Enforced at the one write
/// path, `SettingsController.setSetting(_:to:by:)` (`SettingWriter`): every
/// caller that is not the user (socket cli/mcp/script/remote, palette actions
/// run from the socket, pages without a user gesture) may change only these keys.
extension SettingsSchema {{
    /// Why an agent may not change a key.
    public nonisolated enum AgentRefusal: String, Sendable, Hashable {{
{cases}
    }}

    /// Keys an agent may set and reset.
    public static let agentSettableKeys: Set<String> = [
{settable}
    ]

    /// True when an agent may change `descriptor`, false when it may not, nil
    /// when the key is in neither table (a schema error the tests catch).
    public static func agentSettable(_ descriptor: SettingDescriptor) -> Bool? {{
        if agentSettableKeys.contains(descriptor.id) {{ return true }}
        if agentRefusedKeys[descriptor.id] != nil {{ return false }}
        return nil
    }}
}}
""".format(header=header, cases="\n".join(cases), settable="\n".join(settable))
    refusals = """// {header}

extension SettingsSchema {{
    /// Keys an agent may not set or reset, with the reason.
    public static let agentRefusedKeys: [String: AgentRefusal] = [
{refused}
    ]
}}
""".format(header=header, refused="\n".join(refused))
    return {POLICY_SWIFT: policy, REFUSALS_SWIFT: refusals}


def load_row_facts():
    src = FACTS_SOURCE
    data = load_json(src)
    if set(data) != {"$comment", "kept_on_reset_all", "shared_with_browser", "validation", "former_defaults"}:
        fail(src, "fields are $comment, kept_on_reset_all, shared_with_browser, validation, former_defaults")
    for field in ("kept_on_reset_all", "shared_with_browser"):
        if len(set(data[field])) != len(data[field]):
            fail(src, "%s lists a key twice" % field)
        for key in data[field]:
            check_key(src, key)
    validation = data["validation"]
    if set(validation) != {"keys", "kinds", "default"}:
        fail(src, "validation fields are keys, kinds, default")
    for key, domain in validation["keys"].items():
        check_key(src, key)
    for kind in validation["kinds"]:
        if kind not in SAMPLE_KINDS:
            fail(src, "validation kind %r is not a row kind" % kind)
    for domain in list(validation["keys"].values()) + list(validation["kinds"].values()) + [validation["default"]]:
        if not isinstance(domain, str) or not DOMAIN.match(domain):
            fail(src, "validation %r is portable or domain:<name>" % domain)
    for key, values in data["former_defaults"].items():
        check_key(src, key)
        if not isinstance(values, list) or not values or any(isinstance(v, (dict, list)) or v is None for v in values):
            fail(src, "former_defaults.%s lists one or more scalar values" % key)
        if len(set(map(json.dumps, values))) != len(values):
            fail(src, "former_defaults.%s lists a value twice" % key)
    return data


def row_facts_swift(data):
    def table(mapping):
        return "\n".join(wrap(["%s: %s" % (swift_string(k), swift_string(v)) for k, v in mapping.items()], "        "))
    kept = ["[%s]" % ", ".join(swift_string(part) for part in key.split(".")) for key in data["kept_on_reset_all"]]
    return """// {header}

extension SettingsSchema {{
    /// cmux-next keys cmux-browser reads too (cmux-browser #567 moved its copies to cmux.json). The
    /// `appearance.metrics.*` rows say so themselves.
    static let sharedWithBrowser: Set<String> = [
{shared}
    ]

    /// Keys Reset All Settings leaves alone: the look picked at onboarding
    /// (the app theme and the terminal font), which each row still resets.
    public static let keptOnResetAll: Set<[String]> = [
{kept}
    ]

    /// How another validator checks a row's value (the export's `validation`): by key first, then
    /// by the row's exported kind, else `defaultValidation`.
    static let validationByKey: [String: String] = [
{by_key}
    ]
    static let validationByKind: [String: String] = [
{by_kind}
    ]
    static let defaultValidation = {default}

    /// Each key's earlier defaults that held for a day or more: the one-time launch migration
    /// (`forgetStoredDefaults`) drops a stored value equal to one, so the key follows its default again.
    static let formerDefaults: [String: [JSONValue]] = [
{former}
    ]
}}
""".format(header=HEADER.format(c="//", src=FACTS_SOURCE),
           shared="\n".join(wrap([swift_string(k) for k in data["shared_with_browser"]], "        ")),
           kept="\n".join(wrap(kept, "        ")), by_key=table(data["validation"]["keys"]),
           by_kind=table(data["validation"]["kinds"]), default=swift_string(data["validation"]["default"]),
           former="\n".join(wrap(["%s: [%s]" % (swift_string(k), ", ".join(json_value_swift(v) for v in values))
                                  for k, values in data["former_defaults"].items()], "        ")))


def check_sample(src, where, value):
    if isinstance(value, dict):
        if "$sample" in value and (len(value) != 1 or value["$sample"] not in SAMPLE_TOKENS):
            fail(src, "%s: {\"$sample\": NAME} takes one of %s" % (where, sorted(SAMPLE_TOKENS)))
        for item in value.values():
            check_sample(src, where, item)
    elif isinstance(value, list):
        for item in value:
            check_sample(src, where, item)
    elif isinstance(value, str) and any(ord(ch) < 0x20 for ch in value):
        fail(src, "%s: control character in %r" % (where, value))


def load_samples(facts):
    src = SAMPLES_SOURCE
    data = load_json(src)
    if set(data) != {"$comment", "kinds", "domains"}:
        fail(src, "fields are $comment, kinds, domains")
    if set(data["kinds"]) != SAMPLE_KINDS:
        fail(src, "kinds must be exactly %s" % sorted(SAMPLE_KINDS))
    used = set(facts["validation"]["keys"].values())
    if not set(data["domains"]) <= used:
        fail(src, "domains no row uses: %s" % sorted(set(data["domains"]) - used))
    for group in ("kinds", "domains"):
        for name, entry in data[group].items():
            if set(entry) != {"accept", "refuse"} or not entry["refuse"]:
                fail(src, "%s %s needs accept and a non-empty refuse" % (group, name))
            check_sample(src, name, entry)
    return data


def json_value_swift(value):
    """A Swift `JSONValue` literal of a JSON value."""
    if value is None:
        return ".null"
    if isinstance(value, bool):
        return ".bool(%s)" % ("true" if value else "false")
    if isinstance(value, (int, float)):
        return ".number(%s)" % number_literal(value)
    if isinstance(value, str):
        return ".string(%s)" % swift_string(value)
    if isinstance(value, list):
        return ".array([%s])" % ", ".join(json_value_swift(item) for item in value)
    if not value:
        return ".object([:])"
    return ".object([%s])" % ", ".join("%s: %s" % (swift_string(k), json_value_swift(v)) for k, v in value.items())


def samples_swift(data):
    def sets(mapping):
        out = []
        for name, entry in mapping.items():
            out.append("        %s: SampleSet(" % swift_string(name))
            for label in ("accept", "refuse"):
                items = wrap([json_value_swift(v) for v in entry[label]], "                ")
                end = "," if label == "accept" else ""
                out += (["            %s: [" % label] + items + ["            ]%s" % end]) if items else ["            %s: []%s" % (label, end)]
            out.append("        ),")
        return "\n".join(out)
    return """// {header}

extension SettingsSchemaSamples {{
    /// The sample sets by row kind (the export's kind; `choice_list` for a `string_list` row with choices).
    static let kinds: [String: SampleSet] = [
{kinds}
    ]

    /// The sample sets by validation domain; they win over the kind's.
    static let domains: [String: SampleSet] = [
{domains}
    ]
}}
""".format(header=HEADER.format(c="//", src=SAMPLES_SOURCE), kinds=sets(data["kinds"]), domains=sets(data["domains"]))


def row_fact_outputs():
    facts = load_row_facts()
    outputs = agent_policy_swift(load_agent_policy())
    outputs.update({FACTS_SWIFT: row_facts_swift(facts), SAMPLES_SWIFT: samples_swift(load_samples(facts))})
    return outputs


SECTIONS = load_generator_sections()


EXPORT = "schemas/settings/settings-schema.json"


def export_key_drift(loaded):
    """What the committed export (settings-schema.json, written by the Swift export on a Mac) says
    that the sources do not: a source row missing from its rows, a row no source has, or a retired
    key back in it. The export is a generated file, but a PR can carry one made from an older base
    (#40382 merged an export from before agents.chats.coldArchive and with the retired
    ui.animations.bounce), and the Mac check that compares it with a fresh export does not run on
    every event. Every row comes from a source, so the key sets are equal; this reads only JSON, so
    it runs everywhere --check does."""
    path = os.path.join(ROOT, EXPORT)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        exported = {row["key"] for row in json.load(handle)["rows"]}
    sourced = {row["key"] for _, data in loaded for entry in data["lists"] for row in entry["rows"]}
    retired = {entry["key"] for entry in load_retired()}
    problems = []
    if sourced - exported:
        problems.append("source rows missing from the export: %s" % sorted(sourced - exported))
    if exported - sourced - retired:
        problems.append("export rows no source has: %s" % sorted(exported - sourced - retired))
    if exported & retired:
        problems.append("retired keys back in the export: %s" % sorted(exported & retired))
    return problems


def main():
    check = "--check" in sys.argv[1:]
    outputs = {RETIRED_SWIFT: retired_swift(load_retired())}
    seen_keys = {entry["key"] for entry in load_retired()}
    sections = load_sections()
    outputs[SECTIONS_SWIFT] = sections_swift(sections)
    section_ids = {entry["id"] for entry in sections}
    loaded = [(section, load_section(section, seen_keys, section_ids)) for section in SECTIONS]
    check_constant_names(loaded)
    for section, data in loaded:
        outputs.update(section_swift(section, data))
        outputs.update(choices_swift(section, data))
    page = load_page_layout(section_ids)
    outputs[PAGE_SWIFT] = page_layout_swift(page, sections)
    outputs[PAGE_CATEGORIES_SWIFT] = page_categories_swift(page)
    outputs.update(row_fact_outputs())
    drifted = []
    for path, text in outputs.items():
        full = os.path.join(ROOT, path)
        current = open(full, encoding="utf-8").read() if os.path.exists(full) else None
        if current == text:
            continue
        if check:
            drifted.append(path)
        else:
            with open(full, "w", encoding="utf-8") as handle:
                handle.write(text)
            print("wrote " + path)
    # Generated files this script no longer writes.
    marker = "// GENERATED by scripts/cmux-next/gen-settings-sources.py"
    for name in sorted(os.listdir(os.path.join(ROOT, SCHEMA_DIR))):
        path = SCHEMA_DIR + "/" + name
        if not name.endswith(".generated.swift") or path in outputs:
            continue
        with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
            if not handle.read(len(marker)) == marker:
                continue
        if check:
            drifted.append(path + " (no longer generated)")
        else:
            os.remove(os.path.join(ROOT, path))
            print("removed " + path)
    stale_export = export_key_drift(loaded)
    if stale_export:
        print("%s is not the sources' export (an export from another base?):\n  %s\nregenerate it: "
              "scripts/cmux-next/regenerate-settings-exports.sh (a Mac or the PR's cmux-next-generated-patch artifact)"
              % (EXPORT, "\n  ".join(stale_export)), file=sys.stderr)
        return 1
    if drifted:
        print("generated settings copies differ from schemas/settings:\n  %s\nrun: python3 scripts/cmux-next/gen-settings-sources.py"
              % "\n  ".join(drifted), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
