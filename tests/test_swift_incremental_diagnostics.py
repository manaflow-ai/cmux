#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/swift_incremental_diagnostics.py"
RELOAD = ROOT / "scripts/reload.sh"

spec = importlib.util.spec_from_file_location("swift_incremental_diagnostics", SCRIPT)
diagnostics = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(diagnostics)


SAMPLE = """Queuing Sources/Foo.swift (initial)
Queuing because of dependencies discovered later: {compile: Bar.o <= Sources/Bar.swift}
Scheduling invalidated {compile: Baz.o <= Sources/Baz.swift}
Incremental compilation has been disabled, because different arguments were passed to the compiler.
Failed to read some dependencies source; compiling everything Sources/Broken.swift
Queuing Sources/Bar.swift because of dependencies discovered later
"""


class SwiftIncrementalDiagnosticsTests(unittest.TestCase):
    def test_parser_keeps_incremental_categories_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "reload.log"
            path.write_text(SAMPLE)
            receipt = diagnostics.parse_log(path)

        self.assertEqual(receipt["initial_files"], ["Sources/Foo.swift"])
        self.assertEqual(receipt["dependency_cascade_files"], ["Sources/Bar.swift"])
        self.assertEqual(receipt["scheduled_invalidated_files"], ["Sources/Baz.swift"])
        self.assertEqual(len(receipt["incremental_disabled_reasons"]), 1)
        self.assertEqual(len(receipt["dependency_read_failures"]), 1)
        self.assertEqual(receipt["counts"]["diagnostic_evidence_lines"], 6)

    def test_swift_file_extraction_handles_driver_job_notation(self):
        self.assertEqual(
            diagnostics.swift_file_from_line(
                "Queuing because of dependencies discovered later: "
                "{compile: /tmp/Bar.o <= Sources/Mobile/Bar.swift}"
            ),
            "Sources/Mobile/Bar.swift",
        )
        self.assertIsNone(diagnostics.swift_file_from_line("Scheduling invalidated"))

    def test_reload_diagnostics_are_opt_in_and_use_documented_driver_flags(self):
        reload_source = RELOAD.read_text()
        self.assertIn("CMUX_SWIFT_INCREMENTAL_DIAGNOSTICS", reload_source)
        self.assertIn("-driver-show-incremental", reload_source)
        self.assertIn("-driver-show-job-lifecycle", reload_source)
        self.assertIn("-driver-time-compilation", reload_source)
        self.assertIn("-showBuildTimingSummary", reload_source)
        self.assertIn("swift_incremental_diagnostics.py", reload_source)


if __name__ == "__main__":
    unittest.main()
