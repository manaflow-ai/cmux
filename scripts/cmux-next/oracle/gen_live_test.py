#!/usr/bin/env python3
"""Offline tests of gen_live.py (p15-oracle-225): the live suite's tables, cases and live-map.json.

    python3 -I scripts/cmux-next/oracle/gen_live_test.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from unittest import mock
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

    def test_exclusions_have_a_known_kind_a_reason_and_a_task(self):
        tasks = gen_live.work_tasks()
        for name, entry in Generated.live_map["scripts"].items():
            if entry["status"] == "excluded":
                self.assertIn(entry["kind"], gen_live.EXCLUSION_KINDS, name)
                self.assertGreater(len(entry["reason"]), 40, name)
                self.assertIn(entry["task"], tasks, name)
                self.assertNotEqual(entry["task"], gen_live.TASK, name)
                self.assertIn(entry["task"], entry["reason"], name)

    def test_an_exclusion_without_a_closing_task_is_refused(self):
        """p15-oracle.md rule 6: every excluded script names the task that closes it."""
        tasks = frozenset({"p15-oracle-350", gen_live.TASK})
        reason = "it needs something no case step can do yet"
        self.assertEqual(gen_live.exclusion_problems({"a-live.py": ("pointer", "p15-oracle-350", reason)}, tasks), [])
        for entry, problem in (
                (("pointer", reason), "(kind, task, reason)"),
                (("pointer", "", reason), "the id of the task that closes it"),
                (("pointer", "a follow-up", reason), "the id of the task that closes it"),
                (("pointer", gen_live.TASK, reason), "closes nothing"),
                (("pointer", "p15-oracle-999", reason), "not a task of WORK.tsv"),
                (("nope", "p15-oracle-350", reason), "unknown exclusion kind"),
                (("pointer", "p15-oracle-350", "short"), "needs a reason")):
            found = gen_live.exclusion_problems({"a-live.py": entry}, tasks)
            self.assertEqual(len(found), 1, (entry, found))
            self.assertIn(problem, found[0])
        with mock.patch.dict(gen_live.EXCLUSIONS, {"print-live.py": ("pointer", "", reason)}):
            with mock.patch.dict(gen_live.CONVERSIONS, clear=False):
                gen_live.CONVERSIONS.pop("print-live.py")
                _, _, problems = gen_live.generate(Generated.names)
        self.assertTrue(any(p.startswith("print-live.py: an exclusion needs the id") for p in problems), problems)

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

    def test_driver_app_launches_and_accepts_every_case(self):
        """launch_spec is what AppSession.run_case calls first: an environment key it cannot apply is a Crash
        before the first step."""
        for name, value in Generated.cases.items():
            with self.subTest(case=name):
                self.assertEqual(value["environment"], {})
                driver_app.launch_spec(value)
                for step in value["steps"]:
                    for stroke in step["args"]["keys"] if step["op"] == "key" else ():
                        driver_app.debug_key(stroke, step["id"])

    def test_an_error_step_asks_for_no_turn(self):
        """A refused run is refused before the registry performs it (ControlRouter+ActionRun prepared()), so a
        turn checkpoint on it is a Failure by construction (driver_app.record_turns)."""
        for name, value in Generated.cases.items():
            for step in value["steps"]:
                if step.get("expect", {}).get("outcome") == "error":
                    self.assertNotIn("turn", step.get("checkpoint", ()), f"{name} {step['id']}")
        refused = gen_live.act("r", "workspace.closeAll", error=gen_live.CONFIRMATION_REQUIRED)
        self.assertEqual(refused["checkpoint"], ["before", "settled"])
        self.assertIn("turn", gen_live.act("ok", "workspace.closeAll")["checkpoint"])

    def test_keys_a_panel_answers_ask_for_no_turn(self):
        """Keys to the palette, a cmux dialog or the print sheet run no registry perform turn."""
        for name, value in Generated.cases.items():
            for step in value["steps"]:
                if step["op"] != "key":
                    continue
                reason = step["expect"]["noReceiptReason"]
                if step["target"].get("overlay") or reason in (gen_live.DIALOG_KEY_NO_TURN, gen_live.SHEET_KEY_NO_TURN):
                    self.assertNotIn("turn", step["checkpoint"], f"{name} {step['id']}")
        with self.assertRaises(gen_live.GenError):
            gen_live.key("k", "a", typed=True, no_turn=gen_live.PALETTE_KEY_NO_TURN)

    def test_palette_keys_go_to_the_palette_panel(self):
        """Every key between Cmd-Shift-P and the palette's close goes to its panel (target.overlay palette), and
        typed queries are waited on as the palette's own query, never on rows the empty query already lists."""
        for name, value in Generated.cases.items():
            palette_open = False
            for step in value["steps"]:
                keys = step["args"]["keys"] if step["op"] == "key" else []
                wait = step.get("waitFor") or {}
                if palette_open and keys:
                    self.assertEqual(step["target"], gen_live.PALETTE, f"{name} {step['id']}")
                if "cmd+shift+p" in keys:
                    palette_open = True
                    self.assertEqual(step["target"], gen_live.TARGET, f"{name} {step['id']}")
                if wait.get("pointer") == gen_live.PALETTE_OPEN and wait.get("equals") is False:
                    palette_open = False
                    if keys:
                        self.assertEqual(keys, ["escape", "escape"], f"{name} {step['id']}: a typed query needs two")
                if wait.get("pointer") == gen_live.PALETTE_TOP:
                    self.assertNotEqual(wait.get("predicate"), "nonEmpty", f"{name} {step['id']}")
                if step["op"] == "key" and step["expect"]["noReceiptReason"] == gen_live.TYPED_NO_RECEIPT \
                        and step["target"] == gen_live.PALETTE and "waitFor" in step:
                    self.assertEqual(wait["pointer"], gen_live.PALETTE_QUERY, f"{name} {step['id']}")
            self.assertFalse(palette_open, f"{name}: the palette is left open or closed without a wait")
        self.assertEqual(gen_live.query_sha256("abc"),
                         "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    def test_browser_tabs_wait_for_their_load_state(self):
        """`loading` is false while a new tab is unloaded or idle, so a new tab waits on loadState."""
        for name, value in Generated.cases.items():
            for step in value["steps"]:
                argv = step.get("args", {}).get("argv") or []
                if step["op"] == "cli" and argv[:1] == ["tab"] and argv[1].startswith("new-"):
                    self.assertEqual(step["waitFor"]["pointer"], f"{gen_live.FIRST_TAB}/loadState", name)
                    self.assertIn(step["waitFor"]["equals"], ("finished", "failed"), name)

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
