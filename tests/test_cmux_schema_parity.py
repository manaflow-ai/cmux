#!/usr/bin/env python3
"""The cmux.json schema must describe every key the app reads from cmux.json.

`web/data/cmux.schema.json` is embedded in the app and drives
`cmux config validate`, the editor schema, the docs page, and the settings
skill. A key the app honors but the schema omits validates as "unknown", so a
user who follows the Settings "Edit in cmux.json" button gets a warning for a
setting that works. Four declarations have to agree:

* `supportedSettingsJSONPaths` (`Sources/CmuxSettingsFileStore+SupportedPaths.swift`),
  the cmux.json paths the section parsers accept.
* The settings catalog (`Packages/macOS/CmuxSettings/.../Keys/*CatalogSection.swift`).
  A `JSONKey` or `SecretFileKey` id is itself a cmux.json path. A `DefaultsKey`
  id is only a cmux.json path when a section parser maps it, which is what the
  supported set records.
* `ShortcutAction` cases, each a valid `shortcuts.bindings` name.
* The schema.

A catalog `DefaultsKey` that no parser maps is not a cmux.json setting, so the
schema must not advertise it (validation would then accept a key that does
nothing). Those are listed in NOT_IN_CMUX_JSON so a new catalog key forces an
explicit choice: wire it and document it, or list it here.

Runs without an app build: it reads Swift sources as text.
"""

import functools
import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCHEMA = REPO_ROOT / "web" / "data" / "cmux.schema.json"
SUPPORTED = REPO_ROOT / "Sources" / "CmuxSettingsFileStore+SupportedPaths.swift"
CATALOG_KEYS = REPO_ROOT / "Packages" / "macOS" / "CmuxSettings" / "Sources" / "CmuxSettings" / "Keys"
SHORTCUT_ACTION = (
    REPO_ROOT / "Packages" / "macOS" / "CmuxSettings" / "Sources" / "CmuxSettings"
    / "Values" / "ShortcutAction.swift"
)
SOURCE_ROOTS = (REPO_ROOT / "Sources", REPO_ROOT / "Packages")

KEY_DECLARATION = re.compile(
    r"\b(DefaultsKey|JSONKey|SecretFileKey)\b(?:<[^\n]*?>)?\(\s*id:\s*\"([^\"]+)\""
    r"(?:,\s*defaultValue:\s*([^\n]+?),?\n)?"
)
STRING = re.compile(r'"([^"]+)"')
SYMBOL = re.compile(r"^([A-Z][A-Za-z0-9_]*)\.([A-Za-z0-9_]+)\s*,?$")

# Catalog DefaultsKey ids that no cmux.json section parser reads. They are
# stored only in UserDefaults (UI state, beta toggles, device and account
# state, or `integrations.*` aliases whose cmux.json path is the matching
# `automation.*Integration` key). Adding one to the schema would make
# `cmux config validate` accept a key that has no effect, so wire a parser
# first and then move the id into the schema.
NOT_IN_CMUX_JSON = frozenset({
    # Account and onboarding state.
    "account.piiDisplayMode",
    "account.selectedTeamID",
    "account.welcomeShown",
    # App preferences stored only in UserDefaults today.
    "app.fileDropDefaultBehavior",
    "app.systemWideHotkeyEnabled",
    "app.titlebarControlsStyle",
    "app.workspaceButtonFade",
    "app.workspaceTitlebarVisibility",
    # Browser runtime state.
    "browser.disabled",
    "browser.importHintDismissed",
    "browser.importHintVariant",
    # Beta toggles.
    "cloud.beta.machines.enabled",
    "customSidebars.beta.enabled",
    "extensions.beta.enabled",
    "remoteTmux.beta.enabled",
    "rightSidebar.beta.dock.enabled",
    "rightSidebar.beta.feed.enabled",
    "terminal.beta.predictedEcho.enabled",
    # Device discovery and pairing state.
    "devices.discovery.enabled",
    "devices.incomingAccess.enabled",
    "devices.sidebar.hiddenMacIDs",
    "mobile.iOSPairingHost.displayName",
    "mobile.iOSPairingHost.enabled",
    "mobile.iOSPairingHost.port",
    "mobile.phonePush.forwardingEnabled",
    "mobile.phonePush.hideContent",
    "mobile.phonePush.mode",
    # Settings-catalog aliases of automation.* keys (same UserDefaults slot).
    "integrations.amp.hooksEnabled",
    "integrations.claudeCode.customClaudePath",
    "integrations.claudeCode.hooksEnabled",
    "integrations.codex.hooksEnabled",
    "integrations.cursor.hooksEnabled",
    "integrations.gemini.hooksEnabled",
    "integrations.kiro.hooksEnabled",
    "integrations.kiro.notificationLevel",
    "integrations.ripgrep.customBinaryPath",
    "integrations.suppressSubagentNotifications",
    # Sidebar storage aliases and remembered UI state. The cmux.json paths are
    # workspaceColors.* and sidebar.branchLayout.
    "sidebar.activeTabIndicatorStyle",
    "sidebar.branchVerticalLayout",
    "sidebar.notificationBadgeColor",
    "sidebar.rightMaxWidth.remembered",
    "sidebar.selectionColor",
    "sidebarAppearance.blendMode",
    "sidebarAppearance.blurOpacity",
    "sidebarAppearance.cornerRadius",
    "sidebarAppearance.material",
    "sidebarAppearance.preset",
    "sidebarAppearance.state",
    # Terminal guardrails, diagnostics, and remembered UI state.
    "terminal.runawayMemoryGuardrail.enabled",
    "terminal.runawayMemoryGuardrail.thresholdGB",
    "terminal.sessionContentMaxWidth.remembered",
    "terminal.titleUpdates.coalescing.delayMilliseconds",
    "terminal.titleUpdates.coalescing.enabled",
    "terminal.titleUpdates.diagnostics",
    "workspaceGroups.anchorCloseSuppressed",
})

# Catalog defaults that intentionally differ from the schema default because
# the stored value has different semantics from the cmux.json value.
DEFAULT_EXCEPTIONS = {
    # Stored under the legacy close-on-last-surface key, the inverse of the
    # cmux.json "keep open" value.
    "app.keepWorkspaceOpenWhenClosingLastSurface",
}


def schema_paths():
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    nodes = {}

    def walk(node, prefix):
        for key, value in (node.get("properties") or {}).items():
            path = f"{prefix}.{key}" if prefix else key
            nodes[path] = value
            if isinstance(value, dict):
                walk(value, path)

    walk(schema, "")
    return schema, nodes


_swift_sources = None


def _all_swift_sources():
    global _swift_sources
    if _swift_sources is None:
        _swift_sources = [
            path.read_text(encoding="utf-8", errors="replace")
            for root in SOURCE_ROOTS
            for path in root.rglob("*.swift")
            if ".build" not in path.parts
        ]
    return _swift_sources


def resolve_symbol(type_name, member):
    declares = re.compile(
        r"\b(?:enum|struct|class|extension|actor|protocol)\s+" + re.escape(type_name) + r"\b"
    )
    pattern = re.compile(
        r"static\s+let\s+" + re.escape(member) + r"\s*(?::\s*String\s*)?=\s*\"([^\"]+)\""
    )
    values = set()
    for text in _all_swift_sources():
        # The substring checks skip the regexes for almost every file.
        if type_name in text and member in text and declares.search(text):
            found = pattern.search(text)
            if found:
                values.add(found.group(1))
    return values.pop() if len(values) == 1 else None


@functools.lru_cache(maxsize=None)
def supported_paths():
    resolved, unresolved = set(), []
    body = SUPPORTED.read_text(encoding="utf-8")
    body = body[body.index("supportedSettingsJSONPaths"):]
    for raw in body.splitlines()[1:]:
        line = raw.strip()
        if line.startswith("]"):
            break
        if not line or line.startswith("//"):
            continue
        literal = STRING.search(line)
        if literal:
            resolved.add(literal.group(1))
            continue
        symbol = SYMBOL.match(line)
        value = resolve_symbol(*symbol.groups()) if symbol else None
        if value:
            resolved.add(value)
        else:
            unresolved.append(line)
    return frozenset(resolved), tuple(unresolved)


def catalog_keys():
    keys = {}
    for path in sorted(CATALOG_KEYS.glob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in KEY_DECLARATION.finditer(text):
            kind, key_id, default = match.groups()
            keys[key_id] = (kind, (default or "").strip(), path.name)
    return keys


def shortcut_action_ids():
    text = SHORTCUT_ACTION.read_text(encoding="utf-8")
    body = re.search(r"public enum ShortcutAction\b[^{]*\{(.*?)\n\}", text, re.S).group(1)
    ids = []
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[len("case "):].split(","):
            raw = STRING.search(part)
            ids.append(raw.group(1) if raw else part.split("=")[0].strip())
    return ids


def literal_default(swift):
    """Return a Python value for a Bool/number literal, or None when not literal."""
    if swift in ("true", "false"):
        return swift == "true"
    if re.fullmatch(r"-?\d+(?:\.\d+)?", swift):
        return float(swift)
    return None


class SchemaParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema, cls.paths = schema_paths()
        cls.catalog = catalog_keys()

    def test_every_supported_path_is_in_the_schema(self):
        supported, unresolved = supported_paths()
        self.assertEqual(list(unresolved), [], "could not resolve supported-path symbols")
        self.assertGreater(len(supported), 100, "parsed too few supported paths")
        missing = sorted(supported - set(self.paths))
        self.assertEqual(
            missing,
            [],
            "cmux.json accepts these paths but web/data/cmux.schema.json does not "
            "describe them, so `cmux config validate` reports them as unknown. Add "
            "each to the schema (then run scripts/generate-cmux-config-schema.py and "
            "update skills/cmux-settings/references/all-keys.md).",
        )

    def test_every_json_backed_catalog_key_is_in_the_schema(self):
        # JSONKey and SecretFileKey ids are read straight from cmux.json.
        missing = sorted(
            f"{key_id} ({name})"
            for key_id, (kind, _, name) in self.catalog.items()
            if kind != "DefaultsKey" and key_id not in self.paths
        )
        self.assertEqual(missing, [], "JSON-backed catalog keys missing from the schema")

    def test_every_catalog_key_is_documented_or_explicitly_excluded(self):
        supported, _ = supported_paths()
        undecided = sorted(
            f"{key_id} ({name})"
            for key_id, (kind, _, name) in self.catalog.items()
            if kind == "DefaultsKey"
            and key_id not in self.paths
            and key_id not in supported
            and key_id not in NOT_IN_CMUX_JSON
        )
        self.assertEqual(
            undecided,
            [],
            "new catalog keys are neither in the schema nor listed in NOT_IN_CMUX_JSON. "
            "Wire a cmux.json parser and add a schema entry, or list the id with a reason.",
        )

    def test_not_in_cmux_json_has_no_stale_entries(self):
        supported, _ = supported_paths()
        stale = sorted(
            key_id
            for key_id in NOT_IN_CMUX_JSON
            if key_id not in self.catalog or key_id in self.paths or key_id in supported
        )
        self.assertEqual(
            stale,
            [],
            "these ids are gone from the catalog or are now cmux.json settings; "
            "remove them from NOT_IN_CMUX_JSON",
        )

    def test_shortcut_bindings_enum_matches_shortcut_actions(self):
        actions = shortcut_action_ids()
        self.assertGreater(len(actions), 100, "parsed too few ShortcutAction cases")
        enum = self.paths["shortcuts.bindings"]["propertyNames"]["enum"]
        self.assertEqual(
            sorted(set(actions) - set(enum)),
            [],
            "ShortcutAction cases missing from shortcuts.bindings in the schema",
        )
        self.assertEqual(
            sorted(set(enum) - set(actions)),
            [],
            "schema shortcuts.bindings names that are not ShortcutAction cases",
        )

    def test_literal_catalog_defaults_match_schema_defaults(self):
        mismatched = []
        for key_id, (_, swift_default, name) in sorted(self.catalog.items()):
            node = self.paths.get(key_id)
            if key_id in DEFAULT_EXCEPTIONS or not isinstance(node, dict) or "default" not in node:
                continue
            expected = literal_default(swift_default)
            if expected is None:
                continue
            actual = node["default"]
            if isinstance(expected, bool) or isinstance(actual, bool):
                equal = expected is actual
            else:
                equal = isinstance(actual, (int, float)) and float(actual) == expected
            if not equal:
                mismatched.append(
                    f"{key_id}: catalog {swift_default} ({name}), schema {json.dumps(actual)}"
                )
        self.assertEqual(mismatched, [], "schema defaults disagree with the settings catalog")


if __name__ == "__main__":
    unittest.main()
