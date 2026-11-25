"""The few facts the settings export takes from generated Swift, read the way the app compiles them.

Every file read here is written by a generator from a data file (art/manifest.json,
schemas/settings/chrome-styles.json); the export follows the committed Swift, not the data file,
because that is what `swift test` compiles. A file whose shape these patterns no longer match
raises `SwiftShapeChanged`, which the entry point turns into "cannot decide" (exit 2).
"""
from __future__ import annotations

import json
import os
import re

PKG = "Packages/macOS/CmuxNext/Sources"


class SwiftShapeChanged(Exception):
    pass


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as handle:
        return handle.read()


def swift_literal(text):
    """A Swift string literal body (generators escape only quote and backslash)."""
    return text.replace('\\"', '"').replace("\\\\", "\\")


STRING = r'"((?:[^"\\]|\\.)*)"'


class Catalog:
    """A String Catalog as the English text a compiled bundle returns.

    `rel` is a `.xcstrings` file or a `<Table>.xcstrings.d/` directory of one-key catalogs
    (scripts/cmux-next/string_catalogs.py), whose entries merge into one table.
    """

    def __init__(self, root, rel):
        path = os.path.join(root, rel)
        if os.path.isdir(path):
            self.strings = {}
            for name in sorted(os.listdir(path)):
                if name.endswith(".xcstrings"):
                    self.strings.update(json.loads(read(path, name))["strings"])
        else:
            self.strings = json.loads(read(root, rel))["strings"]

    def keys(self):
        return set(self.strings)

    def text(self, key, default):
        entry = self.strings.get(key)
        if entry is None:
            return default
        unit = entry.get("localizations", {}).get("en", {}).get("stringUnit")
        if unit is None or "value" not in unit:
            return default
        return unit["value"]


def enum_cases(source, enum):
    """Raw values of `enum`'s cases, in declaration order (`case a = "b"` or `case a`)."""
    match = re.search(r"enum %s\b[^{]*\{(.*?)\n    (?:///|public var|var|static|init|func|\})" % re.escape(enum), source, re.S)
    if not match:
        raise SwiftShapeChanged("enum %s not found" % enum)
    values = []
    for line in match.group(1).splitlines():
        found = re.match(r"\s*case\s+`?(\w+)`?(?:\s*=\s*" + STRING + r")?\s*$", line)
        if found:
            values.append((found.group(1), swift_literal(found.group(2)) if found.group(2) is not None else found.group(1)))
    if not values:
        raise SwiftShapeChanged("enum %s has no cases" % enum)
    return values


def backdrop_art(root):
    """BackdropArt.allCases as (raw id, title default, artist, collection), in case order."""
    art = read(root, PKG + "/CmuxNextDesign/BackdropArt.swift")
    entries = read(root, PKG + "/CmuxNextDesign/BackdropArt+Entries.swift")
    cases = enum_cases(art, "BackdropArt")
    titles = {}
    for found in re.finditer(r"case \.(\w+): String\(localized: " + STRING + r", defaultValue: " + STRING, art):
        titles[found.group(1)] = (swift_literal(found.group(2)), swift_literal(found.group(3)))
    facts = {}
    for found in re.finditer(r"case \.(\w+): BackdropArtEntry\(artist: " + STRING + r".*?collection: \.(\w+)", entries):
        facts[found.group(1)] = (swift_literal(found.group(2)), found.group(3))
    out = []
    for name, raw in cases:
        if name not in titles or name not in facts:
            raise SwiftShapeChanged("BackdropArt.%s has no title or entry" % name)
        out.append({"id": raw, "title_key": titles[name][0], "title": titles[name][1],
                    "artist": facts[name][0], "collection": facts[name][1]})
    return out


def backdrop_collections(root):
    library = read(root, PKG + "/CmuxNextDesign/BackdropArt+Library.swift")
    return [name for name, _ in enum_cases(library, "BackdropArtCollection")]


def chrome_styles(root):
    """ChromeStyleSetting.choices: (value, key, text) in ChromeStyle.allCases order."""
    enum = read(root, PKG + "/CmuxNextDesignTokens/ChromeStyle.swift")
    choices = read(root, PKG + "/CmuxNextSettings/ChromeStyleSetting+Choices.swift")
    titles = {}
    for found in re.finditer(r"case \.`?(\w+)`?: SettingsText\.keyed\(" + STRING + r", " + STRING + r"\)", choices):
        titles[found.group(1)] = (swift_literal(found.group(2)), swift_literal(found.group(3)))
    out = []
    for name, raw in enum_cases(enum, "ChromeStyle"):
        if name not in titles:
            raise SwiftShapeChanged("ChromeStyle.%s has no Settings title" % name)
        out.append((raw,) + titles[name])
    return out


def schema_all_order(root):
    """SettingsSchema.all as [(Type, var)] in order, with `appearance` expanded, and the
    vars appended after the sharedWithBrowser map (BrowserAppSettingsSchema) flagged."""
    source = read(root, PKG + "/CmuxNextSettings/Schema/SettingsSchema.swift")
    body = re.search(r"public static let all: \[SettingDescriptor\] = \{\s*let next = (.*?)\n\s*return next\.map \{[^\n]*\}\s*\n((?:\s*\+ [\w.]+\s*\n)*)\s*\}\(\)", source, re.S)
    appearance = re.search(r"static var appearance: \[SettingDescriptor\] \{(.*?)\n    \}", source, re.S)
    if not body or not appearance:
        raise SwiftShapeChanged("SettingsSchema.all no longer has the `let next = ...; return next.map + ...` shape")

    def refs(text):
        out = []
        for token in re.split(r"\s*\+\s*", text.strip()):
            token = token.strip()
            if not token:
                continue
            if token == "appearance":
                out.extend(refs(appearance.group(1)))
                continue
            if not re.match(r"^[A-Z]\w*\.\w+$", token):
                raise SwiftShapeChanged("unexpected SettingsSchema.all term %r" % token)
            out.append(tuple(token.split(".")))
        return out
    return refs(body.group(1)), refs(body.group(2))


def workspace_row_descriptors(root):
    source = read(root, PKG + "/CmuxNextSettings/WorkspaceRowSetting.swift")
    found = re.search(r"static var descriptors: \[SettingDescriptor\] \{(.*?)\n    \}", source, re.S)
    if not found:
        raise SwiftShapeChanged("WorkspaceRowSetting.descriptors not found")
    out = []
    for token in re.split(r"\s*\+\s*", found.group(1).strip()):
        if not re.match(r"^[A-Z]\w*\.\w+$", token.strip()):
            raise SwiftShapeChanged("unexpected WorkspaceRowSetting.descriptors term %r" % token)
        out.append(tuple(token.strip().split(".")))
    return out
