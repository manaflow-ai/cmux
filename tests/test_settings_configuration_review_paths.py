#!/usr/bin/env python3
"""Every cmux.json path a settings row advertises must appear in the declared
supported-path set.

`CmuxSettingsFileStore+SupportedPaths.swift` says of its set: "Settings UI rows
validate against this set so new persisted settings need an explicit cmux.json
review." Nothing enforced that, so a row could advertise a path absent from the
set and nobody noticed.

Be precise about what this proves. `supportedSettingsJSONPaths` has **no
production consumer** -- it is read by this guard and one test, and by nothing
that parses cmux.json. What actually accepts a key is the hand-written section
parsers in `KeyboardShortcutSettingsFileStore.swift` and
`CmuxSettingsFileStore+AppSection.swift`. So this is a consistency check between
two declarations (the UI row and the documented set), not proof that writing the
key does anything.

Issue #13993 demonstrated the other drift direction: the canvas paths passed
this guard while the parser ignored them. CanvasSettingsFileTests now exercises
their ingestion through runtime metrics. This guard still checks declarations
only; a pass means "the row and the documented set agree", nothing stronger.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SUPPORTED = REPO_ROOT / "Sources" / "CmuxSettingsFileStore+SupportedPaths.swift"
UI_ROOT = REPO_ROOT / "Packages" / "macOS" / "CmuxSettingsUI" / "Sources"
SOURCE_ROOTS = (REPO_ROOT / "Sources", REPO_ROOT / "Packages")

# `configurationReview: .json("a", "b")` may list several paths for one row.
REVIEW = re.compile(r"configurationReview:\s*\.json\(([^)]*)\)")
STRING = re.compile(r'"([^"]+)"')
# Entries in the supported set may be symbolic, e.g. PaneChromeSettings.fooKey.
SYMBOL = re.compile(r"^([A-Z][A-Za-z0-9_]*)\.([A-Za-z0-9_]+)\s*,?$")


def _resolve_symbol(type_name, member):
    """Find `static let <member> = "<value>"` in the file that DECLARES the type.

    Matching on "the file mentions the type name" picks the first file in
    filesystem order that merely references it, which is both wrong and
    machine-dependent. `settingsPath` is already declared by two different
    types, so the collision class exists. A decoy that resolves to a shorter
    path would silently widen the ancestor match below and hide real failures,
    so an ambiguous resolution is reported rather than guessed at.
    """
    declares = re.compile(
        r"\b(?:enum|struct|class|extension|actor|protocol)\s+" + re.escape(type_name) + r"\b"
    )
    pattern = re.compile(
        r"static\s+let\s+" + re.escape(member) + r"\s*(?::\s*String\s*)?=\s*\"([^\"]+)\""
    )
    values = set()
    for root in SOURCE_ROOTS:
        for path in root.rglob("*.swift"):
            text = path.read_text(encoding="utf-8", errors="replace")
            if not declares.search(text):
                continue
            found = pattern.search(text)
            if found:
                values.add(found.group(1))
    if len(values) == 1:
        return values.pop()
    return None


def supported_paths():
    resolved, unresolved = set(), []
    for raw in SUPPORTED.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        literal = STRING.search(line)
        if literal:
            resolved.add(literal.group(1))
            continue
        symbol = SYMBOL.match(line)
        if symbol:
            value = _resolve_symbol(*symbol.groups())
            if value:
                resolved.add(value)
            else:
                unresolved.append(line)
    return resolved, unresolved


def advertised_paths():
    for path in sorted(UI_ROOT.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in REVIEW.finditer(text):
            args = match.group(1)
            # Skip non-literal forms such as `.json(catalog.app.foo.id)`; those
            # name a catalog id that cannot be read without type information.
            for value in STRING.findall(args):
                line = text.count("\n", 0, match.start()) + 1
                yield value, path.relative_to(REPO_ROOT), line


# Rows advertising a path absent from the supported set when this guard was
# added. Each was checked against the parsers by hand: none of these five has a
# reader, so writing them into cmux.json genuinely does nothing.
# `cloud`, `computerUse` and `customSidebars` have no top-level case in the
# section dispatch at all, and the parsed `automation` section has no
# `codexIntegration` key. See the tracking issue.
#
# This list is NOT automatically ratcheted -- nothing compares it to a baseline,
# so a new failure could be parked here in the same change that introduces it.
# The staleness test below only reaps entries that have since become supported
# or are no longer advertised. Treat additions as needing review on their own
# merits.
KNOWN_UNSUPPORTED = frozenset({
    "automation.codexIntegration",
    "cloud.beta.machines.enabled",
    "computerUse.enabled",
    "computerUse.showInMenuBar",
    "customSidebars.renderer",
})


class ConfigurationReviewPathsTests(unittest.TestCase):
    def test_every_advertised_path_is_supported(self):
        supported, unresolved = supported_paths()
        self.assertTrue(supported, "parsed no supported paths; the guard would pass vacuously")
        missing = []
        for value, rel, line in advertised_paths():
            if value in KNOWN_UNSUPPORTED:
                continue
            # Object-valued settings are listed at their root, and the store
            # permits descendant paths beneath them (e.g. shortcuts.bindings).
            parts = value.split(".")
            ancestors = {".".join(parts[: i + 1]) for i in range(len(parts))}
            if not (ancestors & supported):
                missing.append(f"{rel}:{line} advertises {value!r}")
        self.assertEqual(
            missing,
            [],
            "settings rows advertise cmux.json paths the file store does not accept, "
            "so writing them into cmux.json does nothing. Add each to "
            "`supportedSettingsJSONPaths` and to the matching "
            "`*SettingsFileMapping` in CmuxSettingsJSONPathSupport.swift.\n  "
            + "\n  ".join(missing)
            + (
                "\n(unresolved symbolic entries in the supported set: "
                + ", ".join(unresolved)
                + ")"
                if unresolved
                else ""
            ),
        )


    def test_known_unsupported_list_has_no_stale_entries(self):
        """A path that became supported, or lost its row, must leave the list."""
        supported, _ = supported_paths()
        advertised = {value for value, _, _ in advertised_paths()}

        def is_supported(path):
            # Mirror the ancestor matching the main test uses. Checking exact
            # membership instead would strand an entry that became supported
            # via an ancestor, leaving it permanently un-reapable dead weight.
            parts = path.split(".")
            return bool(
                {".".join(parts[: i + 1]) for i in range(len(parts))} & supported
            )

        stale = sorted(
            path
            for path in KNOWN_UNSUPPORTED
            if path not in advertised or is_supported(path)
        )
        self.assertEqual(
            stale,
            [],
            "these paths are no longer unsupported-and-advertised, so delete them "
            "from KNOWN_UNSUPPORTED: " + ", ".join(stale),
        )


if __name__ == "__main__":
    unittest.main()
