#!/usr/bin/env python3
"""acpmux-skew-matrix.py's report and rust-live.py's skew_verdict, which reads it before a swap of one daemon:
ok is 1 only when every pair passed, and a missing or broken report reads as no verdict. No binaries."""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses look their module up here
    spec.loader.exec_module(module)
    return module


matrix = load("acpmux_skew_matrix", "scripts/cmux-next/acpmux-skew-matrix.py")
rust_live = load("rust_live", "scripts/cmux-next/rust-live.py")


class SkewReport(unittest.TestCase):
    def test_ok_only_when_every_pair_passes(self):
        good = matrix.report([{"pair": "a", "verdict": "pass"}, {"pair": "b", "verdict": "pass"}], {})
        self.assertEqual((good["pass"], good["total"], good["ok"]), (2, 2, 1))
        bad = matrix.report([{"pair": "a", "verdict": "pass"}, {"pair": "b", "verdict": "fail"}], {})
        self.assertEqual((bad["pass"], bad["total"], bad["ok"]), (1, 2, 0))
        self.assertEqual(matrix.report([], {})["ok"], 0)

    def test_live_swap_reads_the_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "skew.json"
            path.write_text(json.dumps(matrix.report([{"pair": "a", "verdict": "fail"}, {"pair": "b", "verdict": "pass"}], {})))
            self.assertEqual(rust_live.skew_verdict(str(path)), {"ok": 0, "pass": 1, "total": 2})
            path.write_text("{")
            self.assertIsNone(rust_live.skew_verdict(str(path)))
            self.assertIsNone(rust_live.skew_verdict(str(Path(tmp) / "none.json")))
        self.assertIsNone(rust_live.skew_verdict(None))


if __name__ == "__main__":
    unittest.main()
