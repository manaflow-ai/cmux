#!/usr/bin/env python3
"""Tests of the motion arm (action_fixtures/__init__.py, p15-oracle-233).

    python3 -I scripts/cmux-next/oracle/action_fixtures/motion_arm_test.py

Stdlib only; runs on the Linux VM (no app). The registry file is read from the checkout, and its
expected_differences go through the real diff.py, so a settled divergence between the arms fails
and a settings or turn difference is explained.
"""

from __future__ import annotations

import copy
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ORACLE = Path(__file__).resolve().parents[1]
if str(ORACLE) not in sys.path:
    sys.path.insert(0, str(ORACLE))

import action_fixtures  # noqa: E402
from action_fixtures import INCONSISTENT, MOTION_REGISTRY, NO_ARM, MotionArm, MotionArmError  # noqa: E402

REPO = ORACLE.parents[2]
SNAPSHOT_SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"
SNAPSHOT_EXAMPLE = REPO / "schemas" / "oracle" / "fixtures" / "snapshot-example.json"
SWIFT_SETTING = REPO / "Packages" / "macOS" / "CmuxNext" / "Sources" / "CmuxNextSettings" / "MotionCategoriesSetting.swift"
DIFF = ORACLE / "diff.py"
HOST = {"name": "mini", "os": "Darwin", "osVersion": "26.0", "arch": "arm64"}


def schema_node(schema: dict, pointer: str) -> dict:
    """The schema of the snapshot value at `pointer`, through properties and the facet oneOf."""
    node = schema
    for token in pointer[1:].split("/"):
        for branch in [node, *node.get("oneOf", [])]:
            if token in branch.get("properties", {}):
                node = branch["properties"][token]
                break
        else:
            raise KeyError(f"{pointer}: no schema for {token!r}")
    return node


def snapshot(enabled: bool, reduce: bool = False, layout: str = "A|B") -> dict:
    example = json.loads(SNAPSHOT_EXAMPLE.read_text(encoding="utf-8"))
    settings = example["facets"]["settings"]
    settings["motion"] = {"enabled": enabled, "speed": 1, "reduceMotion": reduce}
    settings["nonDefaultKeys"] = [] if enabled else ["ui.animations.enabled"]
    settings["effectiveSha256"] = "sha256:" + ("1" if enabled else "0") * 64
    example["facets"]["layout"] = {"probe": layout}
    return example


class RegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.entry = json.loads(MOTION_REGISTRY.read_text(encoding="utf-8"))
        self.arm = MotionArm.load()

    def test_registry_names_the_master_switch_and_motion_off_default(self) -> None:
        self.assertEqual(self.arm.name, "motion-on")
        self.assertEqual(self.entry["name"], MOTION_REGISTRY.stem)
        self.assertEqual(self.arm.config_path, ("ui", "animations", "enabled"))
        self.assertEqual(dict(self.arm.values), {"old": False, "new": True})
        self.assertEqual((self.arm.default, self.entry["planned"]), ("old", "old"))
        self.assertEqual(self.entry["suites"], ["actions", "journeys"])

    def test_config_key_is_the_swift_setting_path(self) -> None:
        text = SWIFT_SETTING.read_text(encoding="utf-8")
        match = re.search(r"static let enabledPath = \[([^\]]*)\]", text)
        self.assertIsNotNone(match, "MotionCategoriesSetting.enabledPath moved")
        self.assertEqual(tuple(re.findall(r'"([^"]+)"', match.group(1))), self.arm.config_path)

    def test_readback_is_the_settings_facet_value_of_the_config_key(self) -> None:
        schema = json.loads(SNAPSHOT_SCHEMA.read_text(encoding="utf-8"))
        node = schema_node(schema, self.arm.readback)
        self.assertTrue(self.arm.readback.startswith("/facets/settings/"))
        self.assertEqual(node["type"], "boolean")
        self.assertEqual(node["x-oracle-source"]["from"], ".".join(self.arm.config_path))
        self.assertEqual(schema_node(schema, action_fixtures.REDUCE_MOTION_POINTER)["type"], "boolean")

    def test_expected_difference_pointers_exist_in_the_snapshot_schema(self) -> None:
        schema = json.loads(SNAPSHOT_SCHEMA.read_text(encoding="utf-8"))
        for rule in self.entry["expected_differences"]:
            if rule["pointer"]:
                schema_node(schema, rule["pointer"])
        # The readback differs by construction; switch_readback in the receipts checks it instead.
        self.assertIn(self.arm.readback, [r["pointer"] for r in self.entry["expected_differences"]])

    def test_expiry_is_within_fourteen_days(self) -> None:
        import datetime as dt
        days = (dt.date.fromisoformat(self.entry["expires"]) - dt.date.fromisoformat(self.entry["created"])).days
        self.assertTrue(0 <= days <= 14, days)

    def test_malformed_entries_are_refused(self) -> None:
        for change in ({"config_arms": {"old": False, "new": False}}, {"config_arms": {"old": False}},
                       {"config_arms": {"old": 0, "new": 1}}, {"config_key": "ui..enabled"},
                       {"readback": "facets/settings"}, {"default": "on"}):
            with self.subTest(change=change):
                with self.assertRaises(MotionArmError):
                    MotionArm.from_entry({**self.entry, **change})


class LaunchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.arm = MotionArm.load()

    def test_default_arm_turns_animations_off_and_keeps_the_bench_keys(self) -> None:
        bench = {"appearance": {"backgroundOpacity": 1}, "ui": {"animationSpeed": "normal"}}
        before = copy.deepcopy(bench)
        rest, arm = self.arm.split_switches({})
        config = self.arm.launch_config(bench, arm)
        self.assertEqual((rest, arm), ({}, "old"))
        self.assertEqual(config, {"appearance": {"backgroundOpacity": 1},
                                  "ui": {"animationSpeed": "normal", "animations": {"enabled": False}}})
        self.assertEqual(bench, before, "the caller's config is not changed")

    def test_motion_on_arm_turns_animations_on_and_leaves_refactor_switches(self) -> None:
        rest, arm = self.arm.split_switches({"motion-on": "new", "layer-hosting": "old"})
        self.assertEqual((rest, arm), ({"layer-hosting": "old"}, "new"))
        self.assertIs(self.arm.launch_config({}, arm)["ui"]["animations"]["enabled"], True)

    def test_a_config_that_picks_the_other_arm_is_refused(self) -> None:
        with self.assertRaisesRegex(MotionArmError, "needs True"):
            self.arm.launch_config({"ui": {"animations": {"enabled": False}}}, "new")
        with self.assertRaisesRegex(MotionArmError, "not an object"):
            self.arm.launch_config({"ui": {"animations": True}}, "old")
        same = self.arm.launch_config({"ui": {"animations": {"enabled": False, "tabs": False}}}, "old")
        self.assertEqual(same["ui"]["animations"], {"enabled": False, "tabs": False})

    def test_unknown_arm_is_refused(self) -> None:
        with self.assertRaises(MotionArmError):
            self.arm.split_switches({"motion-on": "on"})
        with self.assertRaises(MotionArmError):
            self.arm.launch_config({}, "launch-config")

    def test_start_calls_record_spans_and_new_arm_overrides_reduce_motion(self) -> None:
        self.assertEqual(self.arm.start_calls("old"), [("debug.motion", {"action": "start"})])
        self.assertEqual(self.arm.start_calls("new"), [("debug.motion", {"action": "start"}),
                                                       ("debug.motion", {"action": "reduce", "value": False})])
        self.assertEqual(MotionArm.stop_call(), ("debug.motion", {"action": "stop"}))
        self.assertEqual(self.arm.arm_pointers(), ["/facets/settings/motion/enabled"])


class ReadbackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.arm = MotionArm.load()

    def test_read_arm_from_the_settings_facet(self) -> None:
        self.assertEqual(self.arm.read_arm(snapshot(False)), "old")
        self.assertEqual(self.arm.read_arm(snapshot(True)), "new")
        self.assertEqual(self.arm.read_arm(snapshot(True, reduce=True)), NO_ARM)
        self.assertEqual(self.arm.read_arm(snapshot(False, reduce=True)), "old")
        missing = snapshot(False)
        missing["facets"]["settings"] = {"status": "not-comparable", "reason": "v0 base"}
        self.assertIsNone(self.arm.read_arm(missing))

    def test_case_readback_over_checkpoints(self) -> None:
        self.assertEqual(self.arm.case_readback([snapshot(True), snapshot(True)]), "new")
        self.assertEqual(self.arm.case_readback([snapshot(False), snapshot(True)]), INCONSISTENT)
        self.assertIsNone(self.arm.case_readback([]))

    def test_case_report_hits(self) -> None:
        off, on = [snapshot(False)], [snapshot(True)]
        span = {"name": "tabs.slide", "ms": 180.0, "at_ms": 3.0}
        self.assertEqual(self.arm.case_report("old", off, {"spans": []}),
                         {"switch_readback": {"motion-on": "old"}, "switch_hits": {"motion-on": {"old": 1}}})
        self.assertEqual(self.arm.case_report("new", on, {"spans": [span, span]}),
                         {"switch_readback": {"motion-on": "new"}, "switch_hits": {"motion-on": {"new": 2}}})
        # Something animated with the master switch off: a new-arm hit on the old arm (arm-not-applied).
        self.assertEqual(self.arm.case_report("old", off, {"spans": [span]})["switch_hits"], {"motion-on": {"new": 1}})
        # Nothing animated on the motion-on arm: the case did not exercise it.
        self.assertEqual(self.arm.case_report("new", on, {"spans": []})["switch_hits"], {})
        # The old arm that read back motion on is no evidence for either arm.
        self.assertEqual(self.arm.case_report("old", on, {"spans": []}),
                         {"switch_readback": {"motion-on": "new"}, "switch_hits": {}})
        with self.assertRaises(MotionArmError):
            self.arm.case_report("new", on, {"recording": False})


class SettledEqualityTests(unittest.TestCase):
    """The registry's expected_differences through diff.py: only settled snapshots must be equal."""

    def run_diff(self, old: list, new: list) -> tuple:
        with tempfile.TemporaryDirectory(prefix="motion-arm-") as tmp:
            dirs = []
            for name, points in (("old", old), ("new", new)):
                path = Path(tmp) / name
                path.mkdir()
                (path / "receipt.json").write_text(json.dumps(
                    {"runId": name, "sha": "same", "host": HOST, "cases": {"actions/splitRight": {"result": "Pass"}}}))
                (path / "checkpoints.jsonl").write_text("".join(
                    json.dumps({"case": "actions/splitRight", "step": "run", "index": 0, "checkpoint": cp, "snapshot": snap}) + "\n"
                    for cp, snap in points))
                dirs.append(str(path))
            out = Path(tmp) / "divergence.json"
            proc = subprocess.run([sys.executable, "-I", str(DIFF), *dirs, "--out", str(out), "--expected", str(MOTION_REGISTRY)],
                                  check=False, capture_output=True, text=True)
            return proc.returncode, json.loads(out.read_text(encoding="utf-8"))

    def test_equal_settled_snapshots_pass_with_settings_explained(self) -> None:
        code, doc = self.run_diff([("settled", snapshot(False))], [("settled", snapshot(True))])
        self.assertEqual(code, 0, doc)
        self.assertEqual(doc["summary"]["explained"], 1)

    def test_a_settled_difference_beyond_the_arm_diverges(self) -> None:
        code, doc = self.run_diff([("settled", snapshot(False))], [("settled", snapshot(True, layout="A|B|C"))])
        self.assertEqual(code, 1, doc)
        self.assertEqual(doc["divergences"][0]["pointer"], "/facets/layout/probe")

    def test_a_turn_difference_mid_animation_is_explained(self) -> None:
        code, doc = self.run_diff([("turn", snapshot(False)), ("settled", snapshot(False))],
                                  [("turn", snapshot(True, layout="A|B~")), ("settled", snapshot(True))])
        self.assertEqual(code, 0, doc)

    def test_reduce_motion_on_the_motion_on_arm_diverges(self) -> None:
        code, doc = self.run_diff([("settled", snapshot(False))], [("settled", snapshot(True, reduce=True))])
        self.assertEqual(code, 1, doc)
        self.assertEqual(doc["divergences"][0]["pointer"], "/facets/settings/motion/reduceMotion")


if __name__ == "__main__":
    unittest.main()
