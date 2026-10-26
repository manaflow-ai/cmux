#!/usr/bin/env python3
"""Tests for assign-ipc-method-ids.py (p05-ipc-011): append-only ids, one family per name, Q6 empty."""

from __future__ import annotations

import copy
import importlib.util
import json
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("assign-ipc-method-ids.py")
SPEC = importlib.util.spec_from_file_location("assign_ipc_method_ids", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
ASSIGN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ASSIGN  # dataclasses resolve the module by name
SPEC.loader.exec_module(ASSIGN)

NO_SOURCES = ASSIGN.Sources(macos=set, cli=set, spawning=set)


def live() -> dict:
    return json.loads(ASSIGN.SCHEMA.read_text())


def probe(document: dict) -> dict:
    """A copy of `ping` without its IPC attributes, to add under a new wire name."""

    entry = copy.deepcopy(document["commands"]["ping"])
    for key in ASSIGN.COMMAND_KEY_ORDER:
        entry.pop(key, None)
    return entry


class LiveSchemaTests(unittest.TestCase):
    def test_live_schema_is_current_and_q6_is_empty(self) -> None:
        self.assertEqual(ASSIGN.main(["--check"]), 0)
        self.assertEqual(ASSIGN.missing_attributes(live()), [])

    def test_every_independent_command_is_read_only_and_not_stream_scoped(self) -> None:
        for name, command in live()["commands"].items():
            if command.get("ordering") == "independent":
                self.assertEqual(command["durability"], "read_only", name)
                self.assertNotIn("stream_scoped", command, name)

    def test_second_run_changes_nothing(self) -> None:
        document = live()
        assigner = ASSIGN.Assigner(copy.deepcopy(document), NO_SOURCES)
        self.assertEqual(ASSIGN.render(assigner.run()), ASSIGN.render(document))
        self.assertEqual(assigner.changes, [])


class AssignmentTests(unittest.TestCase):
    def test_new_command_takes_next_ordinal_of_its_family_and_keeps_other_ids(self) -> None:
        document = live()
        before = {name: entry["method_id"] for name, entry in document["commands"].items()}
        document["commands"]["machine-probe"] = probe(document)
        result = ASSIGN.Assigner(document, NO_SOURCES).run()
        daemon = [mid for mid in before.values() if mid >> 8 == 0x01]
        self.assertEqual(result["commands"]["machine-probe"]["method_id"], max(daemon) + 1)
        self.assertEqual(result["commands"]["machine-probe"]["clients"], ["sdk"])
        self.assertEqual(result["commands"]["machine-probe"]["durability"], "read_only")
        for name, method_id in before.items():
            self.assertEqual(result["commands"][name]["method_id"], method_id, name)

    def test_existing_id_and_priority_are_never_rewritten(self) -> None:
        document = live()
        document["commands"]["ping"]["method_id"] = 0x01F0
        document["commands"]["ping"]["priority"] = "bulk"
        document["commands"]["machine-probe"] = probe(document)
        result = ASSIGN.Assigner(document, NO_SOURCES).run()
        self.assertEqual(result["commands"]["ping"]["method_id"], 0x01F0)
        self.assertEqual(result["commands"]["ping"]["priority"], "bulk")
        self.assertEqual(result["commands"]["machine-probe"]["method_id"], 0x01F1)

    def test_assigns_in_file_order_inside_a_family(self) -> None:
        document = live()
        document["commands"]["machine-probe-b"] = probe(document)
        document["commands"]["machine-probe-a"] = probe(document)
        result = ASSIGN.Assigner(document, NO_SOURCES).run()["commands"]
        self.assertEqual(result["machine-probe-a"]["method_id"], result["machine-probe-b"]["method_id"] + 1)

    def test_stream_target_without_reason_becomes_stream_scoped(self) -> None:
        document = live()
        entry = copy.deepcopy(document["commands"]["read-screen"])
        for key in ASSIGN.COMMAND_KEY_ORDER:
            entry.pop(key, None)
        document["commands"]["url-open-probe"] = entry
        result = ASSIGN.Assigner(document, NO_SOURCES).run()["commands"]["url-open-probe"]
        self.assertIs(result["stream_scoped"], True)
        self.assertEqual(result["durability"], "memory")

    def test_name_without_a_family_is_refused(self) -> None:
        document = live()
        document["commands"]["unclassified-probe"] = probe(document)
        with self.assertRaisesRegex(ASSIGN.AssignError, "matches no family"):
            ASSIGN.Assigner(document, NO_SOURCES).run()

    def test_name_in_two_families_is_refused(self) -> None:
        document = live()
        document["commands"]["cloud-conversation-probe"] = probe(document)
        families = dict(ASSIGN.FAMILIES)
        families["conversations"] = (0x0F, "x", (*families["conversations"][2], "cloud-conversation-probe"))
        original = ASSIGN.FAMILIES
        ASSIGN.FAMILIES = families
        try:
            with self.assertRaisesRegex(ASSIGN.AssignError, "matches families"):
                ASSIGN.Assigner(document, NO_SOURCES).run()
        finally:
            ASSIGN.FAMILIES = original

    def test_family_renumber_is_refused(self) -> None:
        document = live()
        document["families"]["tabs"]["id"] = 0x30
        with self.assertRaisesRegex(ASSIGN.AssignError, "never renumbered"):
            ASSIGN.Assigner(document, NO_SOURCES).run()

    def test_stale_rule_is_refused(self) -> None:
        document = live()
        del document["commands"]["server-stats"]
        with self.assertRaisesRegex(ASSIGN.AssignError, "matches no schema name"):
            ASSIGN.Assigner(document, NO_SOURCES).run()

    def test_spawning_and_clients_come_from_the_sources(self) -> None:
        document = live()
        document["commands"]["machine-probe"] = probe(document)
        sources = ASSIGN.Sources(macos=lambda: {"machine-probe"}, cli=lambda: {"machine-probe"},
                                 spawning=lambda: {"machine-probe"})
        result = ASSIGN.Assigner(document, sources).run()["commands"]["machine-probe"]
        self.assertEqual(result["clients"], ["macos", "cli", "sdk"])
        self.assertIs(result["spawns_terminal"], True)


class SwiftSourceTests(unittest.TestCase):
    def test_terminal_spawning_requests_include_new_tab_and_split(self) -> None:
        spawning = ASSIGN.terminal_spawning_commands()
        self.assertTrue({"new-tab", "split", "create-terminal"} <= spawning)


if __name__ == "__main__":
    unittest.main()
