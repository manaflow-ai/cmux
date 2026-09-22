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
        enabled_guard = 'if [[ "${CMUX_SWIFT_INCREMENTAL_DIAGNOSTICS:-0}" == "1" ]]; then'
        enabled_block = reload_source.split(enabled_guard, 1)[1].split("\nelse\n", 1)[0]
        self.assertIn("SWIFT_INCREMENTAL_DIAGNOSTICS_EFFECTIVE=1", enabled_block)
        self.assertIn("-driver-show-incremental", enabled_block)
        self.assertIn("-driver-show-job-lifecycle", enabled_block)
        self.assertIn("-driver-time-compilation", enabled_block)
        self.assertIn("XCODEBUILD_ARGS+=(-showBuildTimingSummary)", enabled_block)

        parser_guard = 'if [[ "${SWIFT_INCREMENTAL_DIAGNOSTICS_EFFECTIVE:-0}" -eq 1 ]]; then'
        parser_offset = reload_source.index(parser_guard)
        parser_block = reload_source[parser_offset:].split("\nfi\n", 1)[0]
        self.assertIn(
            'python3 "$SCRIPT_DIR/ci/swift_incremental_diagnostics.py"',
            parser_block,
        )
        self.assertLess(reload_source.index("XCODEBUILD_OUTPUT_VALID=1"), parser_offset)


if __name__ == "__main__":
    unittest.main()
