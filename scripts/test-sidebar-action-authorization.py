#!/usr/bin/env python3
"""Compile production authorization and actual AppKit menu dispatch, without launching CMUX."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import AppKit
import Foundation

@MainActor final class Counter: NSObject {
    var count = 0
    @objc func increment(_ sender: NSMenuItem) { count += 1 }
}

@main struct Proof {
    @MainActor static func main() async throws {
        var epoch = 1
        let capturedEpoch = epoch
        let authorization = SidebarActionAuthorization(isCurrent: { epoch == capturedEpoch })
        var mutations = 0
        let cancelled = Task { @MainActor in authorization.perform { mutations += 1 } }
        cancelled.cancel()
        _ = await cancelled.value
        let cancelledMutations = mutations
        epoch = 2
        authorization.perform { mutations += 100 }
        let staleMutations = mutations - cancelledMutations

        let counter = Counter()
        let menu = NSMenu()
        let submenu = NSMenu()
        let parent = NSMenuItem(title: "Commands", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        let item = NSMenuItem(title: "Original command", action: #selector(Counter.increment(_:)), keyEquivalent: "")
        item.target = counter
        submenu.addItem(item)
        epoch = 3
        let menuEpoch = epoch
        let menuAuthorization = SidebarActionAuthorization(isCurrent: { epoch == menuEpoch })
        SidebarAuthorizedMenuDispatch(authorization: menuAuthorization).present(menu) { _ in
            _ = NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
            epoch = 4
            _ = NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
        }
        var presentations = 0
        SidebarAuthorizedMenuDispatch(authorization: menuAuthorization).present(NSMenu()) { _ in presentations += 1 }
        let result: [String: Any] = ["cancelledMutations": cancelledMutations,
            "staleMutations": staleMutations, "menuCommands": counter.count,
            "stalePresentations": presentations, "title": item.title]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
'''

class SidebarAuthorizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix="cmux-sidebar-authorization-") as directory:
            scratch = Path(directory)
            harness = scratch / "Proof.swift"
            harness.write_text(HARNESS)
            binary = scratch / "authorization"
            sources = [ROOT / "Sources" / name for name in ["SidebarActionAuthorization.swift",
                "SidebarAuthorizedMenuActionTarget.swift", "SidebarAuthorizedMenuDispatch.swift"]]
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", *map(str, sources),
                str(harness), "-o", str(binary)], check=True, timeout=120)
            cls.actual = json.loads(subprocess.run([str(binary)], check=True,
                capture_output=True, text=True, timeout=30).stdout)

    def test_cancelled_queued_operation_does_not_mutate(self):
        self.assertEqual(self.actual["cancelledMutations"], 0)

    def test_previous_grant_cannot_mutate_after_epoch_change(self):
        self.assertEqual(self.actual["staleMutations"], 0)

    def test_actual_nested_menu_target_executes_only_while_authorized(self):
        self.assertEqual(self.actual["menuCommands"], 1)
        self.assertEqual(self.actual["title"], "Original command")

    def test_revoked_menu_is_not_presented(self):
        self.assertEqual(self.actual["stalePresentations"], 0)

if __name__ == "__main__":
    unittest.main()
