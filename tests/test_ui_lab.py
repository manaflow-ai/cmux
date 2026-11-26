#!/usr/bin/env python3
"""scripts/ui-lab/ui-lab.py reads a harness's source and shim directives."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ui-lab/ui-lab.py"
spec = importlib.util.spec_from_file_location("ui_lab", SCRIPT)
ui_lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui_lab)


class UILabTests(unittest.TestCase):
    def test_inputs_are_support_then_directives_in_order_then_the_harness(self):
        with tempfile.TemporaryDirectory() as directory:
            harness = Path(directory) / "h.swift"
            harness.write_text(
                "// ui-lab: source Sources/Sidebar/GPUSpinnerStyle.swift\n"
                "// ui-lab: shim SidebarAppearanceColorResolver\n"
                "// ui-lab: source is prose here, not a directive\n"
                "UILab.main {}\n"
            )
            files = ui_lab.inputs(harness)
        self.assertEqual(files[0], ui_lab.LAB / "UILab.swift")
        self.assertEqual(files[1], ui_lab.ROOT / "Sources/Sidebar/GPUSpinnerStyle.swift")
        self.assertEqual(files[2], ui_lab.LAB / "shims/SidebarAppearanceColorResolver.swift")
        self.assertEqual(files[3], harness)
        self.assertEqual(len(files), 4)

    def test_a_missing_source_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            harness = Path(directory) / "h.swift"
            harness.write_text("// ui-lab: source Sources/Nope.swift\n")
            with self.assertRaises(SystemExit):
                ui_lab.inputs(harness)

    def test_every_bundled_harness_names_existing_files(self):
        for harness in sorted((ui_lab.LAB / "harnesses").glob("*.swift")):
            with self.subTest(harness=harness.name):
                self.assertTrue(all(path.exists() for path in ui_lab.inputs(harness)))


class PackageImportTests(unittest.TestCase):
    def test_package_imports_are_blanked_keeping_line_numbers(self):
        source = "\n".join([
            "import AppKit",
            "import CmuxSidebar",
            "@testable import CmuxFoundation",
            "@preconcurrency internal import CmuxSettings",
            "import struct CmuxCore.Thing",
            "",
            "let x = 1  // import CmuxNope stays: not at line start",
        ])
        stripped = ui_lab.PACKAGE_IMPORT.sub("", source)
        self.assertEqual(stripped.count("\n"), source.count("\n"))
        self.assertEqual(stripped.split("\n")[0], "import AppKit")
        self.assertNotIn("import Cmux", "\n".join(stripped.split("\n")[:6]))
        self.assertIn("import CmuxNope", stripped)


if __name__ == "__main__":
    unittest.main()
