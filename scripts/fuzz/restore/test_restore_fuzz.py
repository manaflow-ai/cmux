#!/usr/bin/env python3
"""Tests of the restore fuzz's oracle helpers and verdict reader (no app, no fleet).

    python3 scripts/fuzz/restore/test_restore_fuzz.py
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, path, argv=None):
    saved = sys.argv
    sys.argv = argv or [path]
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        sys.argv = saved


sys.path.insert(0, os.path.join(HERE, "..", "..", "cmux-next"))
OUT = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"restore-fuzz-test-{os.getpid()}")
rf = load("restore_fuzz", os.path.join(HERE, "restore_fuzz.py"), ["restore_fuzz.py", "--socket", "/nonexistent", "--out", OUT])
vd = load("verdict", os.path.join(HERE, "verdict.py"))


def ws(name, tabs, panes=1):
    return {"name": name, "tabs": {f"tab_{t}": f"term_{t}" for t in tabs}, "panes": [f"pane_{i}" for i in range(panes)]}


class Oracle(unittest.TestCase):
    def setUp(self):
        self.confirmed = {"w1": ws("fz-1", ["a"]), "w2": ws("fz-2", ["b", "c"], 2)}

    def test_inflight_create_may_land_or_not(self):
        p = {"name": "fz-3"}
        landed = dict(self.confirmed, w3=ws("fz-3", ["d"]))
        self.assertTrue(rf.allowed_after("ws_create", p, self.confirmed, landed))
        self.assertFalse(rf.allowed_after("ws_create", p, self.confirmed, self.confirmed))
        twice = dict(landed, w4=ws("fz-4", ["e"]))
        self.assertFalse(rf.allowed_after("ws_create", p, self.confirmed, twice))

    def test_inflight_split_adds_exactly_one_tab(self):
        p = {"ws": "w1", "pane": "pane_0", "dir": "right"}
        one = dict(self.confirmed, w1=ws("fz-1", ["a", "x"], 2))
        two = dict(self.confirmed, w1=ws("fz-1", ["a", "x", "y"], 3))
        lost = dict(self.confirmed, w1=ws("fz-1", ["x"], 1))
        self.assertTrue(rf.allowed_after("split", p, self.confirmed, one))
        self.assertFalse(rf.allowed_after("split", p, self.confirmed, two))
        self.assertFalse(rf.allowed_after("split", p, self.confirmed, lost))

    def test_inflight_close_and_rename(self):
        closed = {"w1": self.confirmed["w1"]}
        self.assertTrue(rf.allowed_after("ws_close", {"ws": "w2"}, self.confirmed, closed))
        renamed = {"w1": ws("fz-9", ["a"]), "w2": self.confirmed["w2"]}
        self.assertTrue(rf.allowed_after("rename", {"ws": "w1", "name": "fz-9"}, self.confirmed, renamed))
        tab_closed = dict(self.confirmed, w2=ws("fz-2", ["c"], 2))
        self.assertTrue(rf.allowed_after("tab_close", {"ws": "w2", "tab": "tab_b"}, self.confirmed, tab_closed))

    def test_effect_ok_catches_a_silent_loss(self):
        self.assertIsNone(rf.effect_ok("ws_create", {"name": "fz-3"}, self.confirmed,
                                       dict(self.confirmed, w3=ws("fz-3", ["d"])), {}))
        self.assertIn("not listed", rf.effect_ok("ws_create", {"name": "fz-3"}, self.confirmed, self.confirmed, {}))
        self.assertIn("still listed", rf.effect_ok("tab_close", {"ws": "w2", "tab": "tab_b"}, self.confirmed, self.confirmed, {}))
        self.assertIsNone(rf.effect_ok("write", {"ws": "w1"}, self.confirmed, self.confirmed, {}))

    def test_pick_action_respects_limits(self):
        run = rf.Run(7)
        full = {f"w{i}": ws(f"fz-{i}", ["a", "b", "c", "d"], 4) for i in range(rf.MAX_WS)}
        for _ in range(200):
            kind, _ = rf.pick_action(run, full)
            self.assertNotIn(kind, ("ws_create", "split", "tab_new"))
        single = {"w1": ws("fz-1", ["a"])}
        for _ in range(200):
            kind, _ = rf.pick_action(run, single)
            self.assertNotIn(kind, ("tab_close", "ws_close"))

    def test_same_seed_same_plan(self):
        state = {"w1": ws("fz-1", ["a"])}
        a = [rf.pick_action(rf.Run(42), state) for _ in range(5)]
        b = [rf.pick_action(rf.Run(42), state) for _ in range(5)]
        self.assertEqual(a, b)


class Verdict(unittest.TestCase):
    def test_lines(self):
        self.assertTrue(vd.verdict("done\n").startswith("NOVERDICT"))
        self.assertEqual(vd.verdict("RESTORE-FUZZ SUMMARY seed=1 judged=4 violations=0\n"), "PASS")
        self.assertTrue(vd.verdict("RESTORE-FUZZ SUMMARY seed=1 judged=0 violations=0\n").startswith("NOVERDICT"))
        log = "RESTORE-FUZZ VIOLATION seed=5 what=lost\nRESTORE-FUZZ SUMMARY seed=1 judged=3 violations=1\n"
        self.assertTrue(vd.verdict(log).startswith("FAIL 1 violation(s): seed=5"))
        self.assertEqual(vd.verdict("FUZZ-G SUMMARY seeds=4 ops=900 kills=20 violations=0\n"), "PASS")


if __name__ == "__main__":
    unittest.main()
