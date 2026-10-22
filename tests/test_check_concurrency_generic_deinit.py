"""check-concurrency.sh's generic-class rule: in a uiSwiftSettings target (main actor by
default) a generic class declares `nonisolated deinit`. Its implicit deinit is isolated, and
the Release compile's optimizer crashed on #23050's FirstMouseHostingView (fixed in #23233)."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-concurrency.sh"
MANIFEST = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Fixture", targets: [
    .target(name: "FixtureUI", swiftSettings: uiSwiftSettings),
    .target(name: "FixtureCore", swiftSettings: coreSwiftSettings),
])
"""
# #23050's shape: a generic NSHostingView subclass with no deinit of its own.
HOSTING_VIEW = """import AppKit
import SwiftUI

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
"""
FIXED = """import AppKit
import SwiftUI

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    nonisolated deinit {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
"""
# An inner type's deinit is not the generic class's own.
NESTED = """final class Box<Value> {
    final class Inner {
        nonisolated deinit {}
    }
}
"""
# A brace in a string literal doesn't end the class before its deinit.
STRING_BRACE = """final class Box<Value> {
    let closer = "}"
    nonisolated deinit {}
}
"""
ALLOWED = """// concurrency-allow: never released off the main thread; the compile is checked by the Release job.
final class Box<Value> {
}
"""


def run(files):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "Package"
        (root / "Package.swift").parent.mkdir(parents=True)
        (root / "Package.swift").write_text(MANIFEST)
        for name, text in files.items():
            (root / "Sources" / name).parent.mkdir(parents=True, exist_ok=True)
            (root / "Sources" / name).write_text(text)
        env = dict(os.environ, CHECK_CONCURRENCY_ONLY="crash-class")
        return subprocess.run(["bash", str(SCRIPT), str(root)], env=env, text=True, capture_output=True, timeout=60)


class GenericDeinitRule(unittest.TestCase):
    def test_the_23050_shape_in_a_ui_target_is_red(self):
        result = run({"FixtureUI/Popup.swift": HOSTING_VIEW})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/Popup.swift:4: generic main-actor class with no `nonisolated deinit`", result.stdout)

    def test_a_nonisolated_deinit_is_green(self):
        result = run({"FixtureUI/Popup.swift": FIXED})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_non_ui_target_is_out_of_scope(self):
        result = run({"FixtureCore/Popup.swift": HOSTING_VIEW})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_an_inner_types_deinit_does_not_count(self):
        result = run({"FixtureUI/Box.swift": NESTED})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/Box.swift:1:", result.stdout)

    def test_a_brace_in_a_string_does_not_end_the_class(self):
        result = run({"FixtureUI/Box.swift": STRING_BRACE})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_reviewed_escape_is_green(self):
        result = run({"FixtureUI/Box.swift": ALLOWED})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
