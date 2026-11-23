#!/usr/bin/env python3
"""gen-settings-sources.py --check refuses a settings export whose rows are not the sources' rows.

#40382 merged a settings-schema.json exported from an older base: agents.chats.coldArchive and
coldArchiveAfterDays (still in source/chats.json) were gone and the retired ui.animations.bounce was
back, and no check caught it, because the Mac export comparison did not run. This check reads only
JSON, so the Linux checks job runs it on every event.
"""
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def load():
    spec = importlib.util.spec_from_file_location("gen_settings_sources", os.path.join(ROOT, "scripts/cmux-next/gen-settings-sources.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ExportKeysTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load()
        seen = {entry["key"] for entry in cls.module.load_retired()}
        ids = {entry["id"] for entry in cls.module.load_sections()}
        cls.loaded = [(section, cls.module.load_section(section, seen, ids)) for section in cls.module.SECTIONS]

    def setUp(self):
        self.temp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.temp)
        os.makedirs(os.path.join(self.temp, "schemas/settings"))
        for name in ("settings-schema.json", "retired-keys.json"):
            shutil.copy(os.path.join(ROOT, "schemas/settings", name), os.path.join(self.temp, "schemas/settings", name))
        self.real_root = self.module.ROOT
        self.module.ROOT = self.temp
        self.addCleanup(setattr, self.module, "ROOT", self.real_root)

    def edit_export(self, change):
        path = os.path.join(self.temp, self.module.EXPORT)
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        change(data)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(data, handle)

    def test_the_committed_export_has_the_sources_rows(self):
        self.assertEqual(self.module.export_key_drift(self.loaded), [])

    def test_a_dropped_source_row_is_refused(self):
        self.edit_export(lambda data: data.update(rows=[r for r in data["rows"] if not r["key"].startswith("agents.chats.coldArchive")]))
        problems = self.module.export_key_drift(self.loaded)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("agents.chats.coldArchive", problems[0])
        self.assertIn("agents.chats.coldArchiveAfterDays", problems[0])

    def test_a_retired_key_back_in_the_export_is_refused(self):
        retired = self.module.load_retired()[0]["key"]
        self.edit_export(lambda data: data["rows"].append(dict(data["rows"][0], key=retired)))
        problems = self.module.export_key_drift(self.loaded)
        self.assertTrue(any("retired" in p and retired in p for p in problems), problems)

    def test_a_row_no_source_has_is_refused(self):
        self.edit_export(lambda data: data["rows"].append(dict(data["rows"][0], key="nowhere.made.up")))
        problems = self.module.export_key_drift(self.loaded)
        self.assertTrue(any("no source" in p and "nowhere.made.up" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
