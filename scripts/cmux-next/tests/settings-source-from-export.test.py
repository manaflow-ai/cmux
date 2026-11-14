"""Tests of scripts/cmux-next/settings-source-from-export.py and the source format it drafts.

Run: python3 -I scripts/cmux-next/tests/settings-source-from-export.test.py
"""
import glob
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
EXPORT = ROOT / "schemas/settings/settings-schema.json"
# Fields of a source row the export does not carry (Swift names, developer notes, legacy aliases).
SOURCE_ONLY = {"name", "note", "swift_enum", "swift_owner", "aliases", "choices_from"}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GEN = load("gen_settings_sources", "scripts/cmux-next/gen-settings-sources.py")
DRAFT = load("settings_source_from_export", "scripts/cmux-next/settings-source-from-export.py")


class GeneratorSectionFilesTests(unittest.TestCase):
    def test_every_section_source_has_one_generator_file(self):
        sources = {path.name for path in (ROOT / "schemas/settings/source").glob("*.json")
                   if "lists" in json.loads(path.read_text(encoding="utf-8"))}
        self.assertEqual(sorted(sources), sorted(Path(section["source"]).name for section in GEN.SECTIONS))

    def test_a_generator_file_names_its_own_source(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / GEN.GENERATOR_DIR
            folder.mkdir(parents=True)
            entry = {"source": "schemas/settings/source/other.json", "swift": GEN.SCHEMA_DIR + "/X.generated.swift",
                     "type": "XSettingsSchema", "lists": {"x": ["descriptors", None]}}
            (folder / "x.json").write_text(json.dumps(entry), encoding="utf-8")
            saved, GEN.ROOT = GEN.ROOT, root
            try:
                with self.assertRaises(SystemExit):
                    GEN.load_generator_sections()
                entry["source"] = "schemas/settings/source/x.json"
                (folder / "x.json").write_text(json.dumps(entry), encoding="utf-8")
                self.assertEqual(GEN.load_generator_sections()[0]["lists"], {"x": ("descriptors", None)})
            finally:
                GEN.ROOT = saved


class SettingsSourceFromExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = json.loads(EXPORT.read_text(encoding="utf-8"))["rows"]
        cls.by_key = {row["key"]: row for row in cls.rows}

    def test_every_export_row_drafts_into_rows_the_generator_accepts(self):
        drafted = DRAFT.draft(self.rows)
        section = {"source": "draft.json", "swift": "Draft.generated.swift", "type": "DraftSettingsSchema",
                   "lists": {entry["name"]: ("descriptors%d" % index, "DraftOwner") for index, entry in enumerate(drafted["lists"])},
                   "joined": "all"}
        GEN.check_section(section, drafted, set(), {row["section"] for row in self.rows}, "draft.json")
        files = GEN.section_swift(section, drafted)
        self.assertGreater(len(files), 1, "the whole export is too big for one file, so this also covers the split")
        for path, text in files.items():
            self.assertLessEqual(text.count("\n"), 400, path)
        swift = "".join(files.values())
        # The joined var concatenates every list, in order, even when the section splits into files.
        self.assertIn("        [%s].flatMap { $0 }" % ", ".join(
            "descriptors%d" % index for index in range(len(drafted["lists"]))), swift)
        self.assertIn("    static var all: [SettingDescriptor] {", swift)
        self.assertEqual(swift.count("            SettingDescriptor("), len(self.rows))
        for kind in ("choiceOrNumber", "choiceOrURL", "numberList", "orderedChoices", "choiceSet", "timeRange", "soundRules"):
            self.assertIn("." + kind, swift)

    def test_every_source_row_says_what_the_export_says(self):
        """A moved row keeps its export row: texts, kind, choices, range, default, flags, group and order."""
        for path in sorted(glob.glob(str(ROOT / "schemas/settings/source/*.json"))):
            data = json.loads(Path(path).read_text(encoding="utf-8"))
            for entry in data.get("lists", []):
                order = []
                for row in entry["rows"]:
                    exported = self.by_key.get(row["key"])
                    self.assertIsNotNone(exported, "%s: %s is not in the export" % (path, row["key"]))
                    source = {key: value for key, value in row.items() if key not in SOURCE_ONLY}
                    if "choices" in source:
                        source["choices"] = [{"value": c["value"], "title": c["title"]} for c in source["choices"]]
                    drafted = DRAFT.draft_row(exported)
                    if drafted.get("palette_shown") and source.get("page_hidden"):
                        # The export does not carry the reason of a row the palette still offers.
                        drafted["page_hidden"] = source["page_hidden"]
                    if "choices_from" in row:
                        # The source lists the leading choices; the Swift member lists the rest.
                        drafted["choices"] = drafted["choices"][:len(source["choices"])]
                    self.assertEqual(source, drafted, "%s: %s" % (path, row["key"]))
                    self.assertEqual((entry["section"], entry["group"]), (exported["section"], exported["group"]), row["key"])
                    order.append(self.rows.index(exported))
                self.assertEqual(order, list(range(order[0], order[0] + len(order))),
                                 "%s: list %s is not one run of export rows in order" % (path, entry["name"]))

    def test_list_kinds_and_hidden_rows_draft_to_source_fields(self):
        exported = {"key": "a.b", "section": "general", "group": {"key": "g", "text": "G"}, "title": {"key": "t", "text": "T"},
                    "help": None, "summary": None, "kind": "string_list", "ordered": True,
                    "choices": [{"value": "x", "title": {"key": None, "text": "X"}}], "default": [], "default_label": None,
                    "placeholder": None, "keywords": [], "consumers": ["cmux-browser", "cmux-next"], "page_hidden": True,
                    "surfaces": {"palette": {"offered": False, "reason": "why"}}}
        row = DRAFT.draft_row(exported)
        self.assertEqual(row["kind"], "ordered_choices")
        self.assertEqual(row["page_hidden"], "why")
        self.assertEqual(row["consumers"], ["cmux-browser", "cmux-next"])
        self.assertNotIn("palette_hidden", row)
        exported.update(page_hidden=False, ordered=False, consumers=["cmux-next"])
        row = DRAFT.draft_row(exported)
        self.assertEqual((row["kind"], row["palette_hidden"]), ("choice_set", "why"))
        self.assertNotIn("consumers", row)

    def test_select_by_swift_type_reads_title_keys(self):
        # A stand-in CmuxNextSettings tree: the real hand-written rows keep moving into sources.
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / DRAFT.SETTINGS_SOURCES
            folder.mkdir(parents=True)
            (folder / "Example.swift").write_text('extension ExampleSetting { static let t = "settings.sidebar.side" }\n')
            picked = DRAFT.select(self.rows, swift_types=["ExampleSetting"], root=root)
        self.assertEqual(["sidebar.side"], [row["key"] for row in picked])
        with self.assertRaises(SystemExit):
            DRAFT.select(self.rows, keys=["no.such.key"])


if __name__ == "__main__":
    unittest.main()
