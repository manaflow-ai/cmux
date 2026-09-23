#!/usr/bin/env python3
"""Every cmux.json path a settings row advertises must be one the store accepts.

`CmuxSettingsFileStore+SupportedPaths.swift` says of its set: "Settings UI rows
validate against this set so new persisted settings need an explicit cmux.json
review." Nothing enforced that. A row could declare
`configurationReview: .json("terminal.textEditingGestures")` while the store
rejected the path, so the row displayed a cmux.json key that silently did
nothing when a user wrote it.
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
    """Find `static let <member> = "<value>"` inside `<type_name>`'s file."""
    pattern = re.compile(
        r"static\s+let\s+" + re.escape(member) + r"\s*(?::\s*String\s*)?=\s*\"([^\"]+)\""
    )
    for root in SOURCE_ROOTS:
        for path in root.rglob("*.swift"):
            text = path.read_text(encoding="utf-8", errors="replace")
            if type_name not in text:
                continue
            found = pattern.search(text)
            if found:
                return found.group(1)
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


# Rows that already advertised an unsupported path when this guard was added.
# Each is a real defect: the row shows a cmux.json key that does nothing when a
# user writes it. They are recorded rather than fixed here so the guard can stop
# new instances immediately; see the tracking issue. Fixing one means deleting
# its entry below, which this test enforces, so the list can only shrink.
KNOWN_UNSUPPORTED = frozenset({
    "app.globalFontMagnification",
    "automation.codexIntegration",
    "cloud.beta.machines.enabled",
    "computerUse.enabled",
    "computerUse.showInMenuBar",
    "customSidebars.renderer",
    "shortcuts.showModifierHoldHints",
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
        """A fixed row must be removed from the allowlist, so it can only shrink."""
        supported, _ = supported_paths()
        advertised = {value for value, _, _ in advertised_paths()}
        stale = sorted(
            path
            for path in KNOWN_UNSUPPORTED
            if path not in advertised or path in supported
        )
        self.assertEqual(
            stale,
            [],
            "these paths are no longer unsupported-and-advertised, so delete them "
            "from KNOWN_UNSUPPORTED: " + ", ".join(stale),
        )


if __name__ == "__main__":
    unittest.main()
