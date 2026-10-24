#!/usr/bin/env python3
"""arch-layers.py reads the same targets from `swift package dump-package` as arch_counts.py's static reader
(MAPPED_KINDS: regular, executable and binary targets), so its report shows every target and edge the ratchet
and the pre-push layer gate judge. Each case writes a dump and a layer map to a temp dir and runs the script.

  python3 scripts/cmux-next/tests/test_arch_layers.py
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "arch-layers.py"

LAYERS = {
    "order": ["core", "service", "domain", "ui", "app"],
    "targets": {
        "ArchLayersTestCore": {"layer": "core"},
        "ArchLayersTestFFI": {"layer": "core"},
        "ArchLayersTestHelper": {"layer": "service"},
        "ArchLayersTestApp": {"layer": "app"},
    },
}


def target(name: str, kind: str, deps: Sequence[str] = ()) -> dict:
    return {"name": name, "type": kind, "dependencies": [{"byName": [dep, None]} for dep in deps]}


class ArchLayersTests(unittest.TestCase):
    def report(self, targets: list[dict]) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            dump = Path(tmp) / "dump.json"
            layers = Path(tmp) / "layers.json"
            dump.write_text(json.dumps({"targets": targets}))
            layers.write_text(json.dumps(LAYERS))
            out = subprocess.run([sys.executable, str(SCRIPT), "--dump", str(dump), "--layers", str(layers),
                                  "--json"], capture_output=True, text=True, check=True).stdout
        return json.loads(out)

    def test_unmapped_executable_target_is_unplaced(self):
        report = self.report([
            target("ArchLayersTestCore", "regular"),
            target("ArchLayersTestNewTool", "executable", ["ArchLayersTestCore"]),
            target("ArchLayersTestCoreTests", "test", ["ArchLayersTestCore"]),
        ])
        self.assertEqual(report["unplaced"], ["ArchLayersTestNewTool"])

    def test_edge_from_executable_target_is_classified(self):
        report = self.report([
            target("ArchLayersTestApp", "regular"),
            target("ArchLayersTestHelper", "executable", ["ArchLayersTestApp"]),
        ])
        self.assertEqual((report["hard_violations"], report["unplaced"]), (1, []))

    def test_regular_executable_and_binary_targets_are_counted_and_test_targets_are_not(self):
        report = self.report([
            target("ArchLayersTestCore", "regular", ["ArchLayersTestFFI"]),
            target("ArchLayersTestFFI", "binary"),
            target("ArchLayersTestHelper", "executable", ["ArchLayersTestCore"]),
            target("ArchLayersTestHelperTests", "test", ["ArchLayersTestHelper", "ArchLayersTestApp"]),
        ])
        self.assertEqual(report["targets"], 3)
        self.assertEqual(report["layers"]["service"]["targets"], 1)
        self.assertEqual(report["hard_violations"], 0)


if __name__ == "__main__":
    unittest.main()
