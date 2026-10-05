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

struct CloseWarningKinds: OptionSet {
    let rawValue: Int
}
struct CmuxAlertContent {
    let flattenedText: String
    init(flattenedText: String, separatingScrollableDetails: String) { self.flattenedText = flattenedText }
    init(informativeText: String) { self.flattenedText = informativeText }
}
struct CloseTabWarningStore {
    init(defaults: UserDefaults) {}
    func disableWarnings(_ kinds: CloseWarningKinds) {}
}
enum CloseDontAskAgainCheckbox {
    static func add(to: NSAlert, offering: CloseWarningKinds) {}
    static func apply(from: NSAlert, offering: CloseWarningKinds, defaults: UserDefaults) {}
}
@MainActor final class ConfirmationFixture {
    var confirmCloseHandler: ((String, String, Bool) -> Bool)?
    var confirmCloseDontAskAgainHandler: ((CloseWarningKinds) -> Bool)?
    let closeTabWarningDefaults: UserDefaults
    init(defaults: UserDefaults) { closeTabWarningDefaults = defaults }
    func beginCloseConfirmationSession() -> Bool { true }
    func endCloseConfirmationSession() {}
    func runCloseConfirmationAlert(_ alert: NSAlert, content: CmuxAlertContent) -> NSApplication.ModalResponse { .cancel }
__CONFIRM_CLOSE_METHOD__
}

@MainActor final class Counter: NSObject {
    var count = 0
    var inheritedAuthorization = false
    var nestedModalMutations = 0
    var revoke: () -> Void = {}
    @objc func increment(_ sender: NSMenuItem) {
        count += 1
        inheritedAuthorization = SidebarActionAuthorization.current?.isValid == true
    }
    @objc func nestedModal(_ sender: NSMenuItem) {
        let coordinatorAuthorization = SidebarActionAuthorization.current
            ?? SidebarActionAuthorization(isCurrent: { true })
        revoke()
        coordinatorAuthorization.perform { nestedModalMutations += 1 }
    }
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
        let restoredContext = SidebarActionAuthorization.current == nil
        epoch = 5
        let nestedEpoch = epoch
        let nestedAuthorization = SidebarActionAuthorization(isCurrent: { epoch == nestedEpoch })
        counter.revoke = { epoch = 6 }
        let nestedMenu = NSMenu()
        let nestedItem = NSMenuItem(title: "Nested rename", action: #selector(Counter.nestedModal(_:)), keyEquivalent: "")
        nestedItem.target = counter
        nestedMenu.addItem(nestedItem)
        SidebarAuthorizedMenuDispatch(authorization: nestedAuthorization).present(nestedMenu) { _ in
            _ = NSApplication.shared.sendAction(nestedItem.action!, to: nestedItem.target, from: nestedItem)
        }
        var presentations = 0
        SidebarAuthorizedMenuDispatch(authorization: menuAuthorization).present(NSMenu()) { _ in presentations += 1 }
        var confirmationValid = true
        let confirmationAuthorization = SidebarActionAuthorization(isCurrent: { confirmationValid })
        let suite = "SidebarAuthorizationProof." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let confirmation = ConfirmationFixture(defaults: defaults)
        confirmation.confirmCloseHandler = { _, _, _ in confirmationValid = false; return true }
        var closeAccepted = false
        confirmationAuthorization.perform {
            closeAccepted = confirmation.confirmClose(title: "Captured target", message: "Confirmation", acceptCmdD: false)
        }
        var inheritedAsync = false
        await SidebarActionAuthorization.$current.withValue(authorization) {
            await Task.yield()
            inheritedAsync = SidebarActionAuthorization.current != nil
        }
        let restoredAsync = SidebarActionAuthorization.current == nil
        let result: [String: Any] = ["cancelledMutations": cancelledMutations,
            "staleMutations": staleMutations, "menuCommands": counter.count,
            "stalePresentations": presentations, "title": item.title,
            "inheritedAuthorization": counter.inheritedAuthorization,
            "restoredContext": restoredContext, "nestedModalMutations": counter.nestedModalMutations,
            "closeAcceptedAfterRevoke": closeAccepted,
            "inheritedAsync": inheritedAsync, "restoredAsync": restoredAsync]
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
            native = (ROOT / "Sources/TabManager.swift").read_text()
            start = native.index("    func confirmClose(\n")
            end = native.index("    private func runCloseConfirmationAlert(\n", start)
            # Compile the exact production confirmation method. The fixture supplies
            # surrounding app services; only the injected handler path is executed.
            harness.write_text(HARNESS.replace("__CONFIRM_CLOSE_METHOD__", native[start:end]))
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

    def test_original_native_callback_inherits_scoped_authorization(self):
        self.assertTrue(self.actual["inheritedAuthorization"])
        self.assertTrue(self.actual["restoredContext"])

    def test_nested_modal_capture_stays_revoked(self):
        self.assertEqual(self.actual["nestedModalMutations"], 0)

    def test_actual_native_confirmation_rejects_revocation_before_commit(self):
        self.assertFalse(self.actual["closeAcceptedAfterRevoke"])

    def test_async_dispatch_inherits_and_restores_authorization(self):
        self.assertTrue(self.actual["inheritedAsync"])
        self.assertTrue(self.actual["restoredAsync"])

if __name__ == "__main__":
    unittest.main()
