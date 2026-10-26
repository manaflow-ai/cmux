#!/usr/bin/env python3
"""field.py: hang-report field metrics split by field-trial arm (task 152).

Run: python3 -m unittest scripts/perf-lab/tests/test_field_arms.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIELD_PY = os.path.join(os.path.dirname(HERE), "field.py")
_SPEC = importlib.util.spec_from_file_location("perf_lab_field", FIELD_PY)
field = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = field
_SPEC.loader.exec_module(field)


def report(install, arms, hangs=(), build="1250", chip="Apple M4 Pro", memory=24, hang_time=None):
    body = {
        "schema": 2,
        "installId": install,
        "app": {"version": "0.1", "build": build, "channel": "nightly"},
        "hardware": {"arch": "arm64", "chip": chip, "cores": 12, "memoryGB": memory},
        "hangs": [{"source": "watchdog", "kind": "hang", "durationMs": ms, "frames": []} for ms in hangs],
        "fieldTrials": [f"{study}={arm}" for study, arm in arms.items()],
    }
    if hang_time is not None:
        body["metrics"] = {"hangTime": hang_time}
    return body


class ArmsOfTests(unittest.TestCase):
    def test_reads_well_formed_entries_only(self):
        self.assertEqual(field.arms_of({"fieldTrials": ["a=on", "b=control", "bad", "c=x=y", "=on", "d=", 7]}),
                         {"a": "on", "b": "control"})
        self.assertEqual(field.arms_of({}), {})
        self.assertEqual(field.arms_of({"fieldTrials": "a=on"}), {})

    def test_hardware_class_and_long_hangs(self):
        body = report("i", {}, hangs=(100, 250, 900))
        self.assertEqual(field.hardware_class(body), "apple-m4-pro/24gb")
        self.assertEqual(field.long_hangs_ms(body), [250.0, 900.0])
        self.assertEqual(field.hardware_class({}), "other/?gb")
        self.assertEqual(field.metrickit_long_hang_count(
            report("i", {}, hang_time=[{"lowMs": 0, "highMs": 250, "count": 5}, {"lowMs": 250, "highMs": 500, "count": 2},
                                       {"lowMs": 1000, "highMs": 2000, "count": 1}])), 3)
        self.assertIsNone(field.metrickit_long_hang_count(body))


class SplitTests(unittest.TestCase):
    def test_a_fifty_fifty_study_shows_both_arms_per_build_and_hardware(self):
        reports = [
            report("i1", {"s": "on", "t": "control"}, hangs=(300,)),
            report("i1", {"s": "on", "t": "control"}, hangs=()),
            report("i2", {"s": "control"}, hangs=(400, 800)),
            report("i3", {"s": "control"}, hangs=(260,), build="1251", chip="Apple M2", memory=16),
            report("i4", {}, hangs=(5000,)),
        ]
        split = field.split_by_arm(reports)
        self.assertEqual(sorted(split), ["s", "t"])
        s = split["s"]
        self.assertEqual(sorted(s["arms"]), ["control", "on"])
        self.assertEqual(s["arms"]["on"]["reports"], 2)
        self.assertEqual(s["arms"]["on"]["installs"], 1)
        self.assertEqual(s["arms"]["on"]["long_hangs_per_report"], 0.5)
        self.assertEqual(s["arms"]["control"]["reports"], 2)
        self.assertEqual(s["arms"]["control"]["installs"], 2)
        self.assertEqual(s["arms"]["control"]["long_hang_ms"]["max"], 800.0)
        self.assertEqual([(c["build"], c["hardware"], c["arm"], c["reports"]) for c in s["cells"]], [
            ("1250", "apple-m4-pro/24gb", "control", 1),
            ("1250", "apple-m4-pro/24gb", "on", 2),
            ("1251", "apple-m2/16gb", "control", 1),
        ])
        self.assertIsNotNone(s["p_value"])
        self.assertTrue(0.0 <= s["p_value"] <= 1.0)
        self.assertIsNone(split["t"]["p_value"], "one arm has no comparison")

    def test_a_clear_difference_has_a_small_p_value(self):
        reports = [report(f"a{i}", {"s": "on"}, hangs=()) for i in range(40)]
        reports += [report(f"b{i}", {"s": "control"}, hangs=(300, 300)) for i in range(40)]
        self.assertLess(field.split_by_arm(reports)["s"]["p_value"], 0.001)
        same = [report(f"c{i}", {"s": arm}, hangs=()) for i, arm in enumerate(["on", "control"] * 20)]
        self.assertEqual(field.split_by_arm(same)["s"]["p_value"], 1.0)

    def test_study_filter(self):
        reports = [report("i1", {"s": "on", "t": "control"})]
        self.assertEqual(list(field.split_by_arm(reports, study="t")), ["t"])
        self.assertEqual(field.split_by_arm([7, None, report("i", {})]), {})


class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = field.main(list(args))
        return code, out.getvalue()

    def test_reads_json_lines_and_arrays(self):
        reports = [report("i1", {"s": "on"}, hangs=(300,)), report("i2", {"s": "control"})]
        with tempfile.TemporaryDirectory() as folder:
            lines = os.path.join(folder, "r.jsonl")
            with open(lines, "w", encoding="utf-8") as handle:
                handle.write("\n".join(json.dumps(r) for r in reports) + "\n\n")
            array = os.path.join(folder, "r.json")
            with open(array, "w", encoding="utf-8") as handle:
                json.dump(reports, handle)
            code, text = self.run_cli("arms", "--input", lines, "--json")
            self.assertEqual(code, 0)
            self.assertEqual(sorted(json.loads(text)["s"]["arms"]), ["control", "on"])
            code, table = self.run_cli("arms", "--input", array)
            self.assertEqual(code, 0)
            self.assertIn("study s", table)
            self.assertIn("control", table)
            bad = os.path.join(folder, "bad.jsonl")
            with open(bad, "w", encoding="utf-8") as handle:
                handle.write("{not json\n")
            self.assertEqual(self.run_cli("arms", "--input", bad)[0], 2)
            empty = os.path.join(folder, "empty.jsonl")
            open(empty, "w", encoding="utf-8").close()
            self.assertEqual(self.run_cli("arms", "--input", empty), (0, "no report carries a field-trial arm\n"))


if __name__ == "__main__":
    unittest.main()
