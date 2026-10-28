#!/usr/bin/env python3
"""The `{"any": [...]}` binding form is described wherever the forms are listed.

web/data/cmux.schema.json accepts several keys for one action since #25619, but
every place that enumerates the accepted `shortcuts.bindings` values still said
"a string, a two-item array for a chord, or null" (#25564). A user reading the
docs site, or an agent reading the cmux-settings and cmux-keyboard-shortcuts
skill references, binds one key where two would work and the feature is
invisible. The schema is the source of truth: these tests are skipped entirely
when it stops accepting the form, so dropping the form means dropping the prose
rather than leaving a stale requirement here.

    python3 tests/test_shortcut_alternates_documented.py
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "web" / "data" / "cmux.schema.json"
EN_MESSAGES = ROOT / "web" / "messages" / "en.json"
CONFIGURATION_PAGE = ROOT / "web" / "app" / "[locale]" / "(landing)" / "docs" / "configuration" / "page.tsx"
KEYBOARD_SHORTCUTS_PAGE = ROOT / "web" / "app" / "[locale]" / "(landing)" / "docs" / "keyboard-shortcuts" / "page.tsx"
CONFIGURATION_DOC = ROOT / "docs" / "configuration.md"
ALL_KEYS = ROOT / "skills" / "cmux-settings" / "references" / "all-keys.md"
SHORTCUT_ACTIONS = ROOT / "skills" / "cmux-settings" / "references" / "shortcut-actions.md"
SHORTCUTS_SKILL = ROOT / "skills" / "cmux-keyboard-shortcuts" / "SKILL.md"
# The cmux-settings quick reference lists the binding values inline, separately
# from references/all-keys.md.
SETTINGS_SKILL = ROOT / "skills" / "cmux-settings" / "SKILL.md"

# The rule the keyboard-shortcuts page renders for the alternates form.
ANY_RULE_KEY = "chordsRuleAny"


def schema() -> dict:
    return json.loads(SCHEMA.read_text())


# Every $defs an entry of `shortcuts.bindings` can resolve to. The bare-stroke
# variants back the 16 actions with an explicit `properties` entry (the diff
# viewer's scroll keys and the file explorer's open actions), which accept a
# bare first stroke; `shortcutBinding` backs additionalProperties, i.e. the
# rest. Each must accept the alternates form, or a schema-aware editor flags a
# config the app honours.
BINDING_DEFS = (
    "shortcutBinding",
    "singleBareFirstStrokeShortcutBinding",
    "bareFirstStrokeShortcutBinding",
)


def any_branch(document: dict, name: str = "shortcutBinding") -> dict | None:
    """The branch of `$defs.<name>` that takes `{"any": [...]}`."""
    for branch in document["$defs"][name]["oneOf"]:
        if branch.get("required") == ["any"]:
            return branch
    return None


def bindings_description(document: dict) -> str:
    return document["properties"]["shortcuts"]["properties"]["bindings"]["description"]


def names_the_any_form(text: str) -> bool:
    """Prose that names the form, not just the English word "any".

    Tolerates the quoting each surface needs: JSON escapes, a JSX string
    literal, and the ICU `'{'` escape a next-intl message uses for a literal
    brace.
    """
    return bool(re.search(r"['\"]?\{['\"`\s]*any", text))


class SchemaAcceptsAlternatesTests(unittest.TestCase):
    """The premise of every other test here."""

    def test_every_binding_def_has_exactly_one_any_branch(self):
        document = schema()
        for name in BINDING_DEFS:
            with self.subTest(definition=name):
                branches = document["$defs"][name]["oneOf"]
                matches = [branch for branch in branches if branch.get("required") == ["any"]]
                self.assertEqual(
                    len(matches), 1,
                    f"$defs.{name} backs entries of shortcuts.bindings, so it must accept the "
                    f"alternates form in exactly one branch; found {len(matches)}. Without it a "
                    "schema-aware editor flags a config the app honours.",
                )

    def test_every_binding_def_resolves_from_shortcuts_bindings(self):
        """The defs above really are the ones an entry can resolve to."""
        document = schema()
        bindings = document["properties"]["shortcuts"]["properties"]["bindings"]
        refs = {bindings["additionalProperties"]["$ref"]}
        refs.update(entry["$ref"] for entry in bindings.get("properties", {}).values())
        # Each is the `Nullable` wrapper around one of the defs under test.
        resolved = set()
        for ref in refs:
            name = ref.rsplit("/", 1)[-1]
            branches = document["$defs"][name]["oneOf"]
            resolved.update(
                branch["$ref"].rsplit("/", 1)[-1] for branch in branches if "$ref" in branch
            )
        self.assertEqual(
            resolved, set(BINDING_DEFS),
            "the binding definitions reachable from shortcuts.bindings changed; update "
            "BINDING_DEFS so the alternates requirement still covers all of them",
        )

    def test_any_items_accept_a_key_and_a_chord(self):
        branch = any_branch(schema())
        self.assertIsNotNone(branch)
        items = branch["properties"]["any"]["items"]["oneOf"]
        kinds = {"array" if item.get("type") == "array" else "stroke" for item in items}
        self.assertEqual(
            kinds, {"stroke", "array"},
            "each `any` item should be a key string or a two-item chord array",
        )

    def test_a_chord_capable_def_takes_chord_alternates(self):
        """A def that accepts a chord accepts a chord as an alternate too."""
        document = schema()
        for name in BINDING_DEFS:
            takes_chord = any(
                branch.get("type") == "array" for branch in document["$defs"][name]["oneOf"]
            )
            branch = any_branch(document, name)
            self.assertIsNotNone(branch, name)
            items = branch["properties"]["any"]["items"]
            has_chord_item = any(
                item.get("type") == "array" for item in items.get("oneOf", [items])
            )
            with self.subTest(definition=name):
                self.assertEqual(
                    has_chord_item, takes_chord,
                    f"$defs.{name} accepts a chord as a whole binding but not as an `any` item "
                    "(or the other way round); the forms an item takes must match the forms the "
                    "binding takes",
                )


class AlternatesValidateTests(unittest.TestCase):
    """The accepted forms, against the schema a JSON editor actually runs.

    Skipped where jsonschema is absent; the structural tests above still run.
    """

    @classmethod
    def setUpClass(cls):
        try:
            import jsonschema
        except ImportError:  # pragma: no cover - depends on the runner's packages
            raise unittest.SkipTest("jsonschema is not installed")
        cls.validator = jsonschema.Draft202012Validator(schema())
        cls.validator.check_schema(schema())

    def assertBinding(self, action: str, value, *, valid: bool):
        document = {"shortcuts": {"bindings": {action: value}}}
        self.assertEqual(
            self.validator.is_valid(document), valid,
            f"shortcuts.bindings.{action} = {json.dumps(value)} should be "
            f"{'accepted' if valid else 'rejected'}",
        )

    def test_alternates_are_accepted_for_every_kind_of_action(self):
        # additionalProperties: a key, and a chord among the keys.
        self.assertBinding("nextSurface", {"any": ["ctrl+tab", "cmd+]"]}, valid=True)
        self.assertBinding("nextSurface", {"any": ["cmd+]", ["ctrl+b", "n"]]}, valid=True)
        # A bare-first-stroke action that also takes chords. A chord item still
        # needs Cmd or Ctrl first; see
        # test_a_chord_needs_cmd_or_ctrl_in_its_first_stroke.
        self.assertBinding("diffViewerScrollDown", {"any": ["j", "ctrl+n"]}, valid=True)
        self.assertBinding("diffViewerScrollDown", {"any": ["j", ["ctrl+b", "g"]]}, valid=True)
        # A bare-first-stroke action that takes a single stroke only.
        self.assertBinding("fileExplorerOpenSelection", {"any": ["return", "o"]}, valid=True)
        # An empty list unbinds (docs/configuration.md).
        self.assertBinding("nextSurface", {"any": []}, valid=True)

    def test_the_existing_forms_keep_their_meaning(self):
        """#25564 asks for alternates without disturbing the chord syntax."""
        self.assertBinding("nextSurface", ["ctrl+b", "c"], valid=True)
        self.assertBinding("nextSurface", "cmd+]", valid=True)
        self.assertBinding("nextSurface", None, valid=True)
        self.assertBinding("nextSurface", "none", valid=True)
        # A bare-stroke action keeps its bare single stroke and its chords,
        # bare-first ones included (classic ships those as defaults).
        self.assertBinding("diffViewerScrollDown", "j", valid=True)
        self.assertBinding("diffViewerScrollDown", ["ctrl+b", "g"], valid=True)
        self.assertBinding("diffViewerScrollDown", ["g", "g"], valid=True)

    def test_malformed_alternates_are_rejected(self):
        self.assertBinding("nextSurface", {"any": ["cmd+]"], "first": {"key": "p"}}, valid=False)
        # An item of `any` is held to the same modifier rule as the binding itself.
        self.assertBinding("nextSurface", {"any": ["j"]}, valid=False)
        self.assertBinding("nextSurface", {"any": [["ctrl+b", "n", "x"]]}, valid=False)
        # fileExplorerOpenSelection takes a single stroke only, so no chord item either.
        self.assertBinding("fileExplorerOpenSelection", {"any": [["ctrl+b", "o"]]}, valid=False)

    def test_a_chord_in_an_any_list_needs_cmd_or_ctrl_first(self):
        """cmux NEXT drops any other chord, so an `any` item may not be one.

        `SettingsApplier.swift` guards the `.chord` case with
        `first.command || first.control` and appends an `.unsupportedChord`
        diagnostic otherwise, with no exception for the actions that accept a
        bare *single* stroke. `{"any": [...]}` is a NEXT-only form, so its chord
        items are held to exactly that rule -- otherwise the schema blesses an
        alternate the app drops one item at a time.

        The plain two-item chord form is deliberately left wider: classic reads
        the same file and is the looser of the two consumers, so narrowing it
        here would flag bindings classic honours. See
        ``test_the_plain_chord_form_stays_as_wide_as_classic``.
        """
        for action in ("nextSurface", "diffViewerScrollDown"):
            with self.subTest(action=action):
                self.assertBinding(action, {"any": ["cmd+]", ["ctrl+b", "n"]]}, valid=True)
                self.assertBinding(action, {"any": ["cmd+]", ["cmd+j", "x"]]}, valid=True)
                self.assertBinding(action, {"any": ["cmd+]", ["ctrl+shift+b", "c"]]}, valid=True)
                # Modifiers cmux NEXT does not start a chord on.
                self.assertBinding(action, {"any": ["cmd+]", ["shift+b", "n"]]}, valid=False)
                self.assertBinding(action, {"any": ["cmd+]", ["opt+b", "n"]]}, valid=False)
                self.assertBinding(action, {"any": ["cmd+]", ["space", "n"]]}, valid=False)
        # The bare-stroke exception is about a single stroke, and still holds.
        self.assertBinding("diffViewerScrollDown", {"any": ["j", "ctrl+n"]}, valid=True)
        self.assertBinding("diffViewerScrollDown", {"any": ["j", ["ctrl+b", "g"]]}, valid=True)
        self.assertBinding("diffViewerScrollDown", {"any": ["j", ["g", "g"]]}, valid=False)

    def test_the_plain_chord_form_stays_as_wide_as_classic(self):
        """Don't narrow a form classic honours.

        `web/data/cmux.schema.json` is read by classic as well as NEXT, and
        classic is looser: `Sources/KeyboardShortcutSettings+DiffViewerNavigation.swift`
        ships `] f` and `[ f` as *default* chords with `command: false,
        control: false`, which is what the bare-first chord branch was added
        for, and `KeyboardShortcutSettings.swift` counts Option as a modifier.
        So the plain two-item form keeps accepting these even though cmux NEXT
        alone would reject them. Narrowing it is a separate change that has to
        account for classic.
        """
        self.assertBinding("diffViewerScrollDown", ["g", "g"], valid=True)
        self.assertBinding("nextSurface", ["opt+b", "n"], valid=True)


class AlternatesDocumentedTests(unittest.TestCase):
    """Every enumeration of the accepted binding values names the form."""

    @classmethod
    def setUpClass(cls):
        cls.document = schema()
        if any_branch(cls.document) is None:
            raise unittest.SkipTest(
                "web/data/cmux.schema.json no longer accepts {\"any\": [...]}; "
                "drop the prose this test guards instead of skipping it"
            )

    def test_schema_bindings_description_names_the_form(self):
        description = bindings_description(self.document)
        self.assertTrue(
            names_the_any_form(description),
            "shortcuts.bindings in web/data/cmux.schema.json lists the accepted values and is "
            "the hover help every JSON editor shows; it must name the alternates form. Got: "
            f"{description!r}",
        )

    def test_configuration_docs_page_names_the_form(self):
        text = CONFIGURATION_PAGE.read_text()
        section = text.partition('id="shortcuts-bindings"')[2].partition('id="shortcuts-when"')[0]
        self.assertTrue(section, "the shortcuts.bindings section moved; update this test")
        self.assertTrue(
            names_the_any_form(section),
            "the shortcuts.bindings section of the docs site enumerates the accepted values "
            "and must name the alternates form",
        )

    def test_keyboard_shortcuts_page_renders_an_alternates_rule(self):
        page = KEYBOARD_SHORTCUTS_PAGE.read_text()
        self.assertIn(
            f't("{ANY_RULE_KEY}")', page,
            f"the keyboard-shortcuts page lists the binding-value rules; add {ANY_RULE_KEY} "
            "beside chordsRuleSingle and chordsRuleArray",
        )

    def test_english_catalog_has_the_alternates_rule(self):
        rules = json.loads(EN_MESSAGES.read_text())["docs"]["keyboardShortcuts"]
        self.assertIn(
            ANY_RULE_KEY, rules,
            f"web/messages/en.json needs docs.keyboardShortcuts.{ANY_RULE_KEY}; the other "
            "locales fall back to English",
        )
        self.assertTrue(
            names_the_any_form(rules[ANY_RULE_KEY]),
            f"docs.keyboardShortcuts.{ANY_RULE_KEY} must name the form it describes",
        )

    def test_alternates_rule_escapes_its_braces_for_icu(self):
        """next-intl reads a bare `{` as an argument, so the form needs `'{'`."""
        message = json.loads(EN_MESSAGES.read_text())["docs"]["keyboardShortcuts"][ANY_RULE_KEY]
        bare = message.replace("'{'", "").replace("'}'", "")
        self.assertNotIn(
            "{", bare,
            f"docs.keyboardShortcuts.{ANY_RULE_KEY} describes a JSON object, so every literal "
            "brace needs the ICU escape (`'{'` and `'}'`, as docs.api.socketCallout does); a "
            "bare brace makes next-intl read it as a message argument",
        )
        self.assertNotIn("}", bare)

    def test_configuration_doc_names_the_form(self):
        self.assertTrue(
            names_the_any_form(CONFIGURATION_DOC.read_text()),
            "docs/configuration.md documents the alternates form (#25619); keep it",
        )

    def test_all_keys_reference_names_the_form(self):
        rows = [
            line for line in ALL_KEYS.read_text().splitlines()
            if line.startswith("| `shortcuts.bindings`")
        ]
        self.assertEqual(len(rows), 1, "expected one shortcuts.bindings row in all-keys.md")
        self.assertTrue(
            names_the_any_form(rows[0]),
            "the shortcuts.bindings row of skills/cmux-settings/references/all-keys.md copies "
            "the schema description and must name the alternates form",
        )

    def test_shortcut_actions_reference_names_the_form(self):
        self.assertTrue(
            names_the_any_form(SHORTCUT_ACTIONS.read_text()),
            "skills/cmux-settings/references/shortcut-actions.md lists the accepted binding "
            "values an agent may write and must name the alternates form",
        )

    def test_keyboard_shortcuts_skill_names_the_form(self):
        self.assertTrue(
            names_the_any_form(SHORTCUTS_SKILL.read_text()),
            "skills/cmux-keyboard-shortcuts/SKILL.md lists the accepted binding values an "
            "agent may write and must name the alternates form",
        )

    def test_settings_skill_quick_reference_names_the_form(self):
        """The inline quick reference, not just references/all-keys.md."""
        lines = [
            line for line in SETTINGS_SKILL.read_text().splitlines()
            if "`shortcuts.bindings.<actionId>`" in line
        ]
        self.assertEqual(
            len(lines), 1,
            "expected one shortcuts.bindings quick-reference line in skills/cmux-settings/SKILL.md",
        )
        self.assertTrue(
            names_the_any_form(lines[0]),
            "the shortcuts.bindings line of skills/cmux-settings/SKILL.md enumerates the "
            "accepted values an agent may write and must name the alternates form; an agent "
            "following this skill would otherwise never learn the feature. Got: "
            f"{lines[0]!r}",
        )


if __name__ == "__main__":
    unittest.main()
