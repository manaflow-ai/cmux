#!/usr/bin/env python3
"""gen-settings-sources.py keeps every generated section type under the god-type limit.

check-no-godfiles.sh allows 1000 lines per Swift type, extensions included. The generator split a
long section into files but kept every list on one section type, so SidebarSettingsSchema was
already 1353 lines on the base and the three sidebar row-layout rows (CMUX-383) grew it to 1366,
which the checks job refused. A section type now keeps its lists only up to MAX_TYPE_LINES; the
rest go on <type>2, <type>3..., and the section type forwards each moved list in one line, so
callers (SettingsSchema, WorkspaceRowSetting) keep naming the section type.
"""
import importlib.util
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
TYPE_LIMIT = 1000  # check-no-godfiles.sh swift_type_limit
OPENING = re.compile(r"^(?:nonisolated )?(?:public )?(?:enum|extension) (\w+) \{$")


def load():
    spec = importlib.util.spec_from_file_location("gen_settings_sources", os.path.join(ROOT, "scripts/cmux-next/gen-settings-sources.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def type_lines(texts):
    """{type: lines} over the top-level enum and extension blocks of the generated files."""
    totals = {}
    for text in texts:
        name, start = None, 0
        for number, line in enumerate(text.split("\n")):
            match = OPENING.match(line)
            if match and name is None:
                name, start = match.group(1), number
            elif line == "}" and name is not None:
                totals[name] = totals.get(name, 0) + number - start + 1
                name = None
    return totals


def forwarded(text_by_path, type_name):
    """The list vars `type_name` declares, directly or as a forwarder."""
    names = set()
    for text in text_by_path.values():
        inside = False
        for line in text.split("\n"):
            match = OPENING.match(line)
            if match:
                inside = match.group(1) == type_name
            elif line == "}":
                inside = False
            elif inside:
                var = re.match(r"^    static var (\w+): \[SettingDescriptor\]", line)
                if var:
                    names.add(var.group(1))
    return names


class SectionTypeBudgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load()
        seen = {entry["key"] for entry in cls.module.load_retired()}
        ids = {entry["id"] for entry in cls.module.load_sections()}
        cls.loaded = [(section, cls.module.load_section(section, seen, ids)) for section in cls.module.SECTIONS]

    def render(self, section, data):
        return self.module.section_swift(section, data)

    def test_every_section_type_is_under_the_god_type_limit(self):
        for section, data in self.loaded:
            out = self.render(section, data)
            for name, lines in type_lines(out.values()).items():
                self.assertLessEqual(lines, TYPE_LIMIT, "%s: %s spans %d lines" % (section["source"], name, lines))

    def test_an_overflowing_section_forwards_every_list_from_its_own_type(self):
        saved = self.module.MAX_TYPE_LINES
        self.addCleanup(setattr, self.module, "MAX_TYPE_LINES", saved)
        self.module.MAX_TYPE_LINES = 300
        tried = 0
        for section, data in self.loaded:
            if not section.get("type"):
                continue
            out = self.render(section, data)
            totals = type_lines(out.values())
            overflow = sorted(name for name in totals if re.fullmatch(re.escape(section["type"]) + r"\d+", name))
            if not overflow:
                continue
            tried += 1
            # Every list a caller names is still on the section type.
            lists = {var for var, _ in section["lists"].values()}
            if section.get("joined"):
                lists.add(section["joined"])
            self.assertLessEqual(lists, forwarded(out, section["type"]), section["source"])
            # A list body is on one type only: forwarders are one line each.
            for name in overflow:
                self.assertLessEqual(totals[name], 300 + self.module.MAX_LINES, "%s: %s" % (section["source"], name))
        self.assertGreater(tried, 0, "no section overflowed a 300-line type budget")


if __name__ == "__main__":
    unittest.main()
