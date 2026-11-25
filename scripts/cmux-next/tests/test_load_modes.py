#!/usr/bin/env python3
"""The shared load-mode registry is one source both harnesses read (scripts/cmux-next/load_modes.py,
webviews/bench/loadModes.ts): the ids the design names, every knob each harness applies, and `missing` wherever a
harness cannot express one."""
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("load_modes", ROOT / "scripts/cmux-next/load_modes.py")
load_modes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(load_modes)

WEB_KNOBS = {"rows", "focusedStream", "otherChats", "otherChatChunksPerSecond", "cpuSaturation"}
NATIVE_KNOBS = {"rows", "chats", "busyTerminals", "cpuSaturation", "session"}


class LoadModeRegistryTests(unittest.TestCase):
    def test_the_registry_the_web_harness_reads_is_the_one_python_reads(self):
        self.assertTrue(Path(load_modes.REGISTRY).is_file(), load_modes.REGISTRY)
        self.assertEqual(Path(load_modes.REGISTRY), ROOT / "webviews/bench/load-modes.json")

    def test_every_mode_the_design_names_is_in_it(self):
        self.assertEqual([mode["id"] for mode in load_modes.load("all")], ["L0", "L1", "L2", "L3", "L4", "L5"])

    def test_every_mode_carries_both_harnesses_knobs(self):
        for mode in load_modes.load("all"):
            self.assertEqual(set(mode["web"]), WEB_KNOBS, mode["id"])
            self.assertEqual(set(mode["native"]), NATIVE_KNOBS, mode["id"])
            self.assertTrue(mode["label"] and mode["what"], mode["id"])

    def test_the_modes_rise_from_idle_to_everything_at_once(self):
        modes = {mode["id"]: mode for mode in load_modes.load("all")}
        self.assertIsNone(modes["L0"]["web"]["focusedStream"])
        self.assertEqual(modes["L0"]["native"], {"rows": 0, "chats": 0, "busyTerminals": 0, "cpuSaturation": False,
                                                 "session": "light"})
        self.assertEqual(modes["L1"]["web"]["focusedStream"], {"chunksPerSecond": 60, "toolLinesPerSecond": 2000})
        self.assertEqual(modes["L2"]["web"]["otherChats"], 10)
        self.assertEqual(modes["L2"]["web"]["otherChatChunksPerSecond"], 30)
        self.assertEqual(modes["L3"]["web"]["rows"], 100_000)
        self.assertTrue(modes["L4"]["web"]["cpuSaturation"])
        self.assertTrue(modes["L4"]["native"]["cpuSaturation"])
        # L5 is every other mode's load at once.
        self.assertEqual(modes["L5"]["web"]["rows"], 100_000)
        self.assertEqual(modes["L5"]["web"]["focusedStream"], modes["L1"]["web"]["focusedStream"])
        self.assertEqual(modes["L5"]["web"]["otherChats"], modes["L2"]["web"]["otherChats"])
        self.assertTrue(modes["L5"]["web"]["cpuSaturation"])
        self.assertEqual(modes["L5"]["native"]["session"], "stress")
        self.assertEqual(modes["L5"]["native"]["busyTerminals"], 20)

    def test_a_knob_a_harness_cannot_express_is_named_not_quietly_dropped(self):
        modes = {mode["id"]: mode for mode in load_modes.load("all")}
        # No page harness has terminals or workspaces. The native harness seeds the 100k-row chat into the agent
        # pane it types in (native.rows), so it misses nothing of L3 or L5.
        self.assertTrue(modes["L5"]["webMissing"])
        self.assertEqual((modes["L3"]["native"]["rows"], modes["L5"]["native"]["rows"]), (100_000, 100_000))
        self.assertEqual([m["id"] for m in modes.values() if m.get("nativeMissing")], [])
        for mode in modes.values():
            for key in ("webMissing", "nativeMissing"):
                self.assertTrue(all(isinstance(line, str) and line for line in mode.get(key) or []), mode["id"])

    def test_the_old_phase_words_still_name_a_mode(self):
        self.assertEqual([mode["id"] for mode in load_modes.load("idle,stream,load")], ["L0", "L1", "L1"])
        self.assertEqual([mode["id"] for mode in load_modes.load("l2, L4 ")], ["L2", "L4"])

    def test_an_unknown_mode_is_refused_not_guessed(self):
        with self.assertRaises(KeyError):
            load_modes.load("L9")

    def test_the_target_is_the_designs_sixteen_ms(self):
        self.assertEqual(load_modes.gate_p95_ms(), 16)

    def test_the_registry_is_valid_json_with_a_comment_that_says_what_it_is_for(self):
        data = json.loads(Path(load_modes.REGISTRY).read_text())
        self.assertIn("chat-instant-under-load", " ".join(data["$comment"]))


if __name__ == "__main__":
    unittest.main()
