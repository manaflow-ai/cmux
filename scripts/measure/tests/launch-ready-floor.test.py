#!/usr/bin/env python3
"""launch-ready.sh floor=1: the floor side (the empty AppKit app) is a plain side that front= does not judge, and the
summary prints LR-OVER-FLOOR, each cmux side's finished_launching median minus the floor's from the same run.

    python3 scripts/measure/tests/launch-ready-floor.test.py
"""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest

HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


summary = load("launch_ready_summary", "launch-ready-summary.py")
HOME = {"workspace": "wk-1", "tab": "tab_h", "page": "home-dock", "home": True, "windows": 1}


def row(side, label, finished, **extra):
    r = {"side": side, "label": label, "window_on_screen": finished + 50, "finished_launching": finished,
         "marks": {"home.first_page": finished + 40} if side != "floor" else {}, "first_reveal": None}
    r.update(extra)
    return r


def run(rows, front="home"):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = summary.summarize(rows, "kept", front, "front=" + front if front else "", False)
    return result, out.getvalue().splitlines()


def ab_rows():
    rows = [row("base", "prime", 140.0, front=HOME), row("head", "prime", 130.0, front=HOME),
            row("floor", "prime", 120.0, plain=True)]
    for i, (b, h, f) in enumerate([(140.0, 131.0, 124.0), (138.0, 129.0, 126.0), (142.0, 133.0, 125.0)], 1):
        rows += [row("base", f"run{i}", b, front=HOME), row("head", f"run{i}", h, front=HOME),
                 row("floor", f"run{i}", f, plain=True)]
    return rows


class OverFloorTests(unittest.TestCase):
    def test_each_cmux_side_minus_the_floor(self):
        result, lines = run(ab_rows())
        over = {l.split()[1]: l for l in lines if l.startswith("LR-OVER-FLOOR ")}
        self.assertEqual(set(over), {"base", "head"})
        self.assertIn("finished_launching=15.0 side=140.0 floor=125.0 n=3 floor_n=3", over["base"])
        self.assertIn("finished_launching=6.0 side=131.0 floor=125.0", over["head"])

    def test_floor_is_not_judged_for_front(self):
        result, lines = run(ab_rows())
        self.assertEqual(result["floor"]["failed"], [])
        self.assertTrue(result["floor"]["plain"])
        self.assertFalse(any(l.startswith("LR-FAIL floor") for l in lines))
        self.assertFalse(any(l.startswith("LR-SURFACE-DIFF") for l in lines))
        self.assertTrue(any(l.startswith("LR-SAME-FRONT ok") for l in lines))

    def test_no_floor_side_prints_nothing(self):
        rows = [r for r in ab_rows() if r["side"] != "floor"]
        _, lines = run(rows)
        self.assertFalse(any(l.startswith("LR-OVER-FLOOR") for l in lines))

    def test_floor_without_a_reading_says_so(self):
        rows = [dict(r, finished_launching=None) if r["side"] == "floor" else r for r in ab_rows()]
        _, lines = run(rows)
        self.assertIn("LR-OVER-FLOOR none: the floor side has no finished_launching", lines)


class FloorShellTests(unittest.TestCase):
    def test_floor_side_probes_plain(self):
        script = HERE.parent / "launch-ready.sh"
        out = subprocess.run(["bash", "-c", f'source "{script}"; LR_STATE=kept; probe_mode run1 floor; probe_mode run1 head'],
                             capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(out, ["plain"])

    def test_floor_build_is_one_shared_app(self):
        lib = (HERE.parent / "hello-floor-app.sh").read_text()
        self.assertIn("hello_floor_app()", lib)
        self.assertIn("apple-macos13.0", lib)  # minos pinned (the -10825 failure on a newer sw_vers)
        for user in ("launch-ready.sh", "hello-appkit-floor.sh"):
            self.assertIn("hello-floor-app.sh", (HERE.parent / user).read_text(), user)


if __name__ == "__main__":
    unittest.main()
