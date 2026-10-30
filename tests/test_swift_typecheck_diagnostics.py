#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/swift_typecheck_diagnostics.py"
PROJECT = ROOT / "cmux.xcodeproj/project.pbxproj"
COMPILE = ROOT / "scripts/cmux-next/check-release-compile.sh"
SCHEME_COMPILE = ROOT / "scripts/cmux-next/check-cmux-scheme-compile.sh"

spec = importlib.util.spec_from_file_location("swift_typecheck_diagnostics", SCRIPT)
diagnostics = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(diagnostics)


class SwiftTypecheckDiagnosticsTests(unittest.TestCase):
    def test_parser_returns_the_twenty_slowest_warnings(self):
        lines = [
            f"/tmp/Source.swift:{index}:1: warning: expression took {index}ms to type-check (limit: 200ms)"
            for index in range(1, 26)
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build.log"
            path.write_text("\n".join(lines))
            receipt = diagnostics.parse_log(path)

        self.assertEqual(receipt["count"], 25)
        slowest = list(receipt["slowest"])
        self.assertEqual(len(slowest), 20)
        self.assertEqual(slowest[0]["milliseconds"], 25.0)
        self.assertEqual(slowest[-1]["milliseconds"], 6.0)
        self.assertTrue(all(entry["kind"] == "expression" for entry in slowest))

    def test_compile_profile_is_opt_in_and_compile_checks_skip_dsyms(self):
        source = COMPILE.read_text()
        self.assertIn('CMUX_SWIFT_TYPECHECK_DIAGNOSTICS:-0', source)
        self.assertIn("-warn-long-function-bodies=200", source)
        self.assertIn("-warn-long-expression-type-checking=200", source)
        self.assertIn("-driver-time-compilation", source)
        self.assertNotIn("DEBUG_INFORMATION_FORMAT=dwarf", source)
        self.assertIn("CMUX_SWIFT_TYPECHECK_DIAGNOSTICS", source)
        scheme_source = SCHEME_COMPILE.read_text()
        self.assertIn("DEBUG_INFORMATION_FORMAT=dwarf", scheme_source)
        self.assertIn('DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";', PROJECT.read_text())

    def test_next_script_phases_have_dependency_declarations(self):
        source = PROJECT.read_text()
        self.assertNotIn("alwaysOutOfDate = 1;", source)
        phases = source.split("/* Begin PBXShellScriptBuildPhase section */", 1)[1].split(
            "/* End PBXShellScriptBuildPhase section */", 1
        )[0]
        blocks = re.findall(r"\t\t[A-Z0-9]+ /\* .*? \*/ = \{.*?\n\t\t\};", phases, re.DOTALL)
        self.assertEqual(len(blocks), 14)
        for block in blocks:
            self.assertRegex(block, r"inputPaths = \(\n\s+\"[^\"]+\",")
            self.assertRegex(block, r"outputPaths = \(\n\s+\"[^\"]+\",")
        self.assertIn('"$(SRCROOT)/cmux-tui/crates/cmux-git"', source)
        self.assertIn('"$(SRCROOT)/scripts/build-phase-caller-path.sh"', source)
        self.assertIn('"$(SRCROOT)/cmux-tui/crates/cmux-rd-ffi"', source)
        self.assertIn('"$(SRCROOT)/scripts/cmux-next/bundle-ublock.sh"', source)
        self.assertIn('"$(TARGET_TEMP_DIR)/embed-cef.stamp"', source)
        self.assertNotIn('"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/cef"', source)
        self.assertIn('"$(TARGET_TEMP_DIR)/verify-web-bundles.stamp"', source)
        for script in (
            "bundle-cmux-tui.sh",
            "bundle-optchat-chief.sh",
            "bundle-mobile-host.sh",
            "embed-cef.sh",
            "bundle-ghostty-resources.sh",
        ):
            text = (ROOT / "scripts/cmux-next" / script).read_text()
            self.assertIn("if (( status == 0 )); then", text)
            self.assertIn('rm -f "$stamp"', text)


if __name__ == "__main__":
    unittest.main()
