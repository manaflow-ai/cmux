#!/usr/bin/env python3
"""Execute the real AppDelegate registry creation/adoption paths with UI effects replaced.

This focused composition regression does not simulate AppKit's native drag loop;
that boundary still requires the tagged native acceptance test.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DragOutBootstrapRegistryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="cmux-drag-out-bootstrap-")
        source = (ROOT / "Sources/AppDelegate.swift").read_text()
        start = source.index("    private var tabDragTransferRegistryStorage:")
        end = source.index("    /// Caches live pane-transfer", start)
        registry_composition = source[start:end]
        start = source.index("        captureSessionLaunchStateIfNeeded()", source.index("    func configure("))
        end = source.index("        // Adopt the bootstrap manager", start)
        bootstrap_composition = source[start:end]
        program = r'''import AppKit
import Foundation
struct TabDragTransfer { struct Tab { struct ID { let uuid: UUID }; let id: ID }; let tab: Tab }
@MainActor final class TabDragTransferRegistry {
    var onUnhandledNativeDragEnd: ((TabDragTransfer, NSPoint, NSDragOperation, TimeInterval) -> Void)?
}
@MainActor final class TabManager {
    let tabDragTransferRegistry = TabDragTransferRegistry()
}
@MainActor final class DragOutWindowCoordinator {
    var completions = 0
    func shouldDetach(beganAt: TimeInterval, point: NSPoint, operation: NSDragOperation) -> Bool {
        completions += 1
        return operation.isEmpty
    }
}
@MainActor final class AppDelegate {
    var tabManager: TabManager?
    let dragOutWindowCoordinator = DragOutWindowCoordinator()
    var moved: [UUID] = []
    func captureSessionLaunchStateIfNeeded() {}
    func locateBonsplitSurface(tabId: UUID) -> (panelId: UUID, found: Bool)? { (tabId, true) }
    func moveSurfaceToNewWindow(panelId: UUID, at: NSPoint) -> UUID? { moved.append(panelId); return UUID() }
    func showDragOutWindowFailure() { fatalError("unexpected failed move") }
''' + registry_composition + '''
    func adoptBootstrap(_ tabManager: TabManager) {
''' + bootstrap_composition + '''
    }
}
MainActor.assumeIsolated {
    var app: AppDelegate? = AppDelegate()
    weak var weakApp = app
    let manager = TabManager()
    if CommandLine.arguments[1] == "bootstrap" { app!.adoptBootstrap(manager) }
    let registry = app!.tabDragTransferRegistry
    let panel = UUID()
    let transfer = TabDragTransfer(tab: .init(id: .init(uuid: panel)))
    registry.onUnhandledNativeDragEnd?(transfer, .zero, [], 0)
    let moved = app!.moved == [panel]
    let completions = app!.dragOutWindowCoordinator.completions
    let shared = CommandLine.arguments[1] != "bootstrap" || registry === manager.tabDragTransferRegistry
    app = nil
    let payload: [String: Any] = ["moved": moved, "completions": completions, "shared": shared, "released": weakApp == nil]
    print(String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
}
'''
        main = Path(cls.temp.name) / "main.swift"
        main.write_text(program)
        cls.binary = Path(cls.temp.name) / "probe"
        result = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", str(main), "-o", str(cls.binary)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check_flow(self, mode):
        result = subprocess.run([str(self.binary), mode], capture_output=True, text=True, check=True)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["shared"], payload)
        self.assertTrue(payload["released"], payload)
        self.assertEqual(payload["completions"], 1, payload)
        self.assertTrue(payload["moved"], payload)

    def test_created_registry_routes_unconsumed_completion(self):
        self.check_flow("created")

    def test_bootstrap_registry_routes_unconsumed_completion(self):
        self.check_flow("bootstrap")


if __name__ == "__main__":
    unittest.main()
