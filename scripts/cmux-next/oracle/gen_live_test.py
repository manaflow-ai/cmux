#!/usr/bin/env python3
"""Offline tests of gen_live.py (p15-oracle-225): the live suite's tables, cases and live-map.json.

    python3 -I scripts/cmux-next/oracle/gen_live_test.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
for _path in (str(HERE), str(HERE.parent)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import driver_app  # noqa: E402
import gen_live  # noqa: E402
import normalize  # noqa: E402
import oracle  # noqa: E402

CASE_SCHEMA = json.loads((gen_live.REPO / "schemas" / "oracle" / "case-v1.schema.json").read_text(encoding="utf-8"))


class Generated:
    names = gen_live.inventory()
    files, live_map, problems = gen_live.generate(names)
    cases = {name: value for name, value in files.items() if name != gen_live.COVERAGE}


class TablesTest(unittest.TestCase):
    def test_every_live_script_is_in_one_table(self):
        self.assertEqual(Generated.problems, [])
        self.assertEqual(sorted(Generated.live_map["scripts"]), Generated.names)
        self.assertEqual(Generated.live_map["converted"] + Generated.live_map["excluded"], len(Generated.names))

    def test_a_new_script_in_no_table_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in Generated.names + ["brand-new-live.py", "not-a-live-script.py"]:
                (Path(tmp) / name).write_text("", encoding="utf-8")
            _, live_map, problems = gen_live.generate(gen_live.inventory(Path(tmp)))
        self.assertEqual(problems, ["brand-new-live.py: a live script in neither CONVERSIONS nor EXCLUSIONS"])
        self.assertNotIn("not-a-live-script.py", live_map["scripts"])

    def test_a_removed_script_is_reported(self):
        names = [n for n in Generated.names if n != "print-live.py"]
        _, _, problems = gen_live.generate(names)
        self.assertIn("print-live.py: in a table but not a live script of scripts/cmux-next", problems)

    def test_exclusions_have_a_known_kind_and_a_reason(self):
        for name, entry in Generated.live_map["scripts"].items():
            if entry["status"] == "excluded":
                self.assertIn(entry["kind"], gen_live.EXCLUSION_KINDS, name)
                self.assertGreater(len(entry["reason"]), 40, name)

    def test_batches_split_the_inventory_in_eight(self):
        batches = [entry["batch"] for entry in Generated.live_map["scripts"].values()]
        self.assertEqual(sorted(set(batches)), list(range(1, gen_live.BATCHES + 1)))
        self.assertEqual(batches, sorted(batches))
        sizes = [batches.count(b) for b in set(batches)]
        self.assertLessEqual(max(sizes) - min(sizes), 1)

    def test_coverage_counts_the_scripts(self):
        coverage = Generated.files[gen_live.COVERAGE]
        self.assertEqual(coverage["total"], len(Generated.names))
        self.assertEqual(coverage["covered"] + len(coverage["excluded"]), coverage["total"])
        self.assertEqual(coverage["missing"], [])
        listed = sorted(c.split("/", 1)[1] + ".json" for cases in coverage["cases"].values() for c in cases)
        self.assertEqual(listed, sorted(Generated.cases))


class CasesTest(unittest.TestCase):
    def test_cases_validate_against_case_v1(self):
        for name, value in Generated.cases.items():
            self.assertEqual(normalize.validate(value, CASE_SCHEMA), [], name)

    def test_cases_pass_the_semantic_check(self):
        mutations = oracle.mutation_operations()
        for name, value in Generated.cases.items():
            case = oracle.Case(f"live/{value['id']}", "live", Path(name), value)
            self.assertEqual(oracle.check_case(case, mutations), [], name)

    def test_driver_app_accepts_every_step(self):
        for name, value in Generated.cases.items():
            driver_app.check_conditions(value)
            for step in value["steps"]:
                for stroke in step["args"]["keys"] if step["op"] == "key" else ():
                    driver_app.debug_key(stroke, step["id"])

    def test_each_case_links_its_script(self):
        for script, entry in Generated.live_map["scripts"].items():
            for case_id in entry.get("cases", ()):
                value = Generated.cases[case_id.split("/", 1)[1] + ".json"]
                self.assertIn(f"scripts/cmux-next/{script}", value["invariants"][0])

    def test_web_cases_name_only_the_fixture_origin(self):
        for name, value in Generated.cases.items():
            text = json.dumps(value)
            self.assertEqual("$WEB/" in text, bool(value["fixture"].get("web")), name)

    def test_the_checked_in_outputs_are_current(self):
        found = gen_live.differences(gen_live.DEFAULT_OUT, gen_live.DEFAULT_MAP, Generated.files, Generated.live_map)
        self.assertEqual(found, [], "run python3 -I scripts/cmux-next/oracle/gen_live.py")


class KeystrokesTest(unittest.TestCase):
    def test_capitals_and_shifted_symbols(self):
        self.assertEqual(gen_live.keystrokes("Ab :?"), ["shift+a", "b", "space", "shift+;", "shift+/"])

    def test_a_character_no_key_types_is_refused(self):
        with self.assertRaises(gen_live.GenError):
            gen_live.keystrokes("é")

    def test_long_text_is_split_at_the_key_limit(self):
        steps = gen_live.type_text("t", "a" * 70, waits=gen_live.changed("/sidebar/rows"))
        self.assertEqual([len(s["args"]["keys"]) for s in steps], [32, 32, 6])
        self.assertEqual([s["id"] for s in steps], ["t-1", "t-2", "t-3"])
        self.assertEqual(["waitFor" in s for s in steps], [False, False, True])

    def test_a_key_step_over_the_limit_is_refused(self):
        with self.assertRaises(gen_live.GenError):
            gen_live.key("k", *(["a"] * 33))


if __name__ == "__main__":
    unittest.main(verbosity=1)
