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

# 6bf522e6cdd's ObservedMap.Slot and #20408's ThemedPicker.Coordinator: a class nested in a generic
# type is generic by context, and its implicit deinit crashed the Release compile the same way.
NESTED_IN_GENERIC = """final class Map<Key: Hashable, Value> {
    final class Slot {
        var value: Value?
    }
    nonisolated deinit {}
}
"""
# The same class declared in an extension, with the generic type in another file.
LEDGER = """struct Ledger<Entry> {
    var entries: [Entry]
}
"""
LEDGER_CURSOR = """extension Ledger {
    final class Cursor {
        var entry: Entry?
    }
}
"""
LEDGER_CURSOR_FIXED = """extension Ledger {
    final class Cursor {
        var entry: Entry?
        nonisolated deinit {}
    }
}
"""
# Package.swift's CmuxNextMallocZone shape: a target with no swiftSettings (nonisolated by default)
# declared before a uiSwiftSettings target, which also names it in a `.target(name:)` dependency.
ZONE_BEFORE_UI = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Fixture", targets: [
    .target(name: "FixtureZone"),
    .target(
        name: "FixtureHome",
        dependencies: [.target(name: "FixtureZone"), .product(name: "Kit", package: "Kit")],
        resources: [.process("Resources")],
        swiftSettings: uiSwiftSettings
    ),
])
"""
BOX = """final class Box<T> {
    var value: T?
}
"""
# A plain deinit takes the target's default isolation: it is no fix (the plain-deinit rule says so too).
PLAIN = """final class Box<Value> {
    var value: Value?
    deinit {}
}
"""


def run(files, manifest=MANIFEST):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "Package"
        (root / "Package.swift").parent.mkdir(parents=True)
        (root / "Package.swift").write_text(manifest)
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

    def test_a_class_nested_in_a_generic_type_is_red(self):
        result = run({"FixtureUI/Map.swift": NESTED_IN_GENERIC})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/Map.swift:2: generic main-actor class with no `nonisolated deinit`", result.stdout)

    def test_a_class_in_an_extension_of_a_generic_type_in_another_file_is_red(self):
        result = run({"FixtureUI/Ledger.swift": LEDGER, "FixtureUI/Ledger+Cursor.swift": LEDGER_CURSOR})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/Ledger+Cursor.swift:2: generic main-actor class with no `nonisolated deinit`",
                      result.stdout)
        # The finding names the declaration that makes it generic, so a PR that changes only that file owns it.
        self.assertIn("generic context: Sources/FixtureUI/Ledger.swift:1", result.stdout)
        result = run({"FixtureUI/Ledger.swift": LEDGER, "FixtureUI/Ledger+Cursor.swift": LEDGER_CURSOR_FIXED})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_plain_deinit_is_no_fix(self):
        result = run({"FixtureUI/Box.swift": PLAIN})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/Box.swift:1: generic main-actor class with no `nonisolated deinit`", result.stdout)

    def test_a_generic_main_actor_class_in_a_non_ui_target_is_red(self):
        result = run({"FixtureCore/Box.swift": "@MainActor " + PLAIN.replace("    deinit {}\n", "")})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureCore/Box.swift:1: generic main-actor class", result.stdout)

    def test_a_target_without_swift_settings_is_nonisolated_and_does_not_take_the_next_targets(self):
        # The manifest regex ran from a settings-less target into the next target's swiftSettings:
        # FixtureZone took FixtureHome's uiSwiftSettings, and FixtureHome dropped out of the map.
        result = run({"FixtureZone/Box.swift": BOX, "FixtureHome/Box.swift": BOX}, ZONE_BEFORE_UI)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureHome/Box.swift:1: generic main-actor class with no `nonisolated deinit`", result.stdout)
        self.assertNotIn("FixtureZone/Box.swift", result.stdout)


if __name__ == "__main__":
    unittest.main()
