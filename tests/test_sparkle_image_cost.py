#!/usr/bin/env python3
"""Regression tests for scripts/cmux-next/sparkle-image-cost.py (p08-startup task 067).

The otool parsing, the control subtraction, the 3 ms decision and the report run here on fixture text; the
dlopen probe itself runs only on a fleet Mac. No app, no build. Run: python3 -I tests/test_sparkle_image_cost.py
"""
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "cmux-next", "sparkle-image-cost.py")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cost = load("sparkle_image_cost", SCRIPT)
perf_stats = cost.load_perf_stats()

SPARKLE_ID = "@rpath/Sparkle.framework/Versions/B/Sparkle"
SPARKLE_OTOOL = f"""/tmp/Sparkle.framework/Versions/B/Sparkle:
\t{SPARKLE_ID} (compatibility version 1.6.0, current version 2.10.0)
\t/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0, current version 2575.0.0)
\t/System/Library/Frameworks/Security.framework/Versions/A/Security (compatibility version 1.0.0, current version 61439.0.0)
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
\t/usr/lib/libobjc.A.dylib (compatibility version 1.0.0, current version 228.0.0)
"""
APP_OTOOL = """/x/cmux DEV t.app/Contents/MacOS/cmux DEV:
\t@rpath/Sentry.framework/Versions/A/Sentry (compatibility version 1.0.0, current version 1.0.0)
\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0, current version 2.10.0)
\t/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0, current version 2575.0.0)
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
"""


class OtoolTests(unittest.TestCase):
    def test_parse_leaves_out_the_header_and_versions(self):
        names = cost.parse_otool_l(SPARKLE_OTOOL)
        self.assertEqual(names[0], SPARKLE_ID)
        self.assertEqual(len(names), 5)
        self.assertNotIn("/tmp/Sparkle.framework/Versions/B/Sparkle:", names)

    def test_dependencies_drop_the_own_id_and_split_system(self):
        system, other = cost.framework_dependencies(cost.parse_otool_l(SPARKLE_OTOOL), SPARKLE_ID)
        self.assertEqual(other, [])
        self.assertEqual(system[-1], "/usr/lib/libobjc.A.dylib")
        self.assertNotIn(SPARKLE_ID, system)

    def test_app_linkage_finds_sparkle(self):
        others = [n for n in cost.parse_otool_l(APP_OTOOL) if not cost.is_system(n)]
        self.assertEqual(len(others), 2)
        self.assertTrue(any(map(cost.is_sparkle, others)))
        self.assertFalse(cost.is_sparkle("@rpath/Sentry.framework/Versions/A/Sentry"))


class DecisionTests(unittest.TestCase):
    def test_control_is_subtracted_and_never_negative(self):
        self.assertEqual(cost.costs_ms([(10_000, 1_010_000), (50_000, 20_000)]), [1.0, 0.0])

    def test_threshold_is_inclusive_on_p50(self):
        self.assertEqual(cost.verdict({"p50": 2.999}), cost.KEEP)
        self.assertEqual(cost.verdict({"p50": 3.0}), cost.DLOPEN)
        self.assertIsNone(cost.verdict({"p50": None}))

    def test_one_slow_run_does_not_flip_the_verdict(self):
        samples = [(10_000, 1_510_000)] * 19 + [(10_000, 40_010_000)]
        doc = cost.result(samples, perf_stats=perf_stats, framework="/f", version="2.10.0")
        self.assertEqual(doc["verdict"], cost.KEEP)
        self.assertAlmostEqual(doc["cost_ms"]["p50"], 1.5)
        self.assertAlmostEqual(doc["cost_ms"]["max"], 40.0)

    def test_probe_line_must_be_two_counts(self):
        self.assertEqual(cost.parse_probe_line("12 345"), (12, 345))
        for bad in ("12", "a b", "1 2 3", ""):
            with self.assertRaises(cost.CostError):
                cost.parse_probe_line(bad)


class CliTests(unittest.TestCase):
    def run_main(self, argv, env=None):
        out, err = io.StringIO(), io.StringIO()
        saved = dict(os.environ)
        try:
            os.environ.pop("CMUX_CI_STEP_KEY", None)
            os.environ.pop("NX_JOB_ID", None)
            os.environ.update(env or {})
            with redirect_stdout(out), redirect_stderr(err):
                code = cost.main(argv)
        finally:
            os.environ.clear()
            os.environ.update(saved)
        return code, out.getvalue(), err.getvalue()

    def test_report_prints_the_number_and_verdict(self):
        samples = [(5_000, 805_000)] * 5
        app = {"executable": "cmux DEV t", "non_system_dylibs": ["@rpath/Sparkle.framework/Versions/B/Sparkle"],
               "sparkle_linked": True}
        doc = cost.result(samples, perf_stats=perf_stats, framework="/f", version="2.10.0", app=app,
                          host={"name": "mini", "macos": "26.1", "arch": "arm64"})
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "r.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(doc, handle)
            code, out, _ = self.run_main(["--report", path])
        self.assertEqual(code, 0)
        self.assertIn("p50 0.800", out)
        self.assertIn("Sparkle linked: True", out)
        self.assertIn(f"verdict {cost.KEEP}", out)

    def test_probe_refuses_off_the_fleet(self):
        code, _, err = self.run_main(["--framework", "/nowhere/Sparkle.framework"])
        self.assertEqual(code, 2)
        self.assertTrue("fleet" in err or "macOS only" in err, err)


if __name__ == "__main__":
    unittest.main()
