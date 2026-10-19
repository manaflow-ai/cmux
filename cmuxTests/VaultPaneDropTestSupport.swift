import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Shared executable harness for synthetic Vault drops across pane targets.
@MainActor
struct VaultPaneDropTestHarness {
    enum TargetKind: Sendable {
        case terminal
        case browser
    }

    enum Placement: Sendable {
        case center
        case right
    }

    private let pasteboardNamePrefix: String

    init(suiteName: String) {
        pasteboardNamePrefix = "cmux.test.vault-pane-drop.\(suiteName)"
    }

    func beginVaultDrag(
        entry: SessionEntry,
        sessionRegistry: SessionDragRegistry,
        tabDragTransferRegistry: TabDragTransferRegistry
    ) throws -> VaultPaneTestDrag {
        let dragID = sessionRegistry.register(entry)
        guard let registration = SessionDragPayload(
            entry: entry,
            dragID: dragID
        ).register(with: tabDragTransferRegistry) else {
            sessionRegistry.discard(id: dragID)
            throw VaultPaneTestDrag.Error.registrationFailed
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "\(pasteboardNamePrefix).\(UUID().uuidString)"
        ))
        pasteboard.clearContents()
        guard registration.write(to: pasteboard) else {
            tabDragTransferRegistry.end(registration)
            sessionRegistry.discard(id: dragID)
            throw VaultPaneTestDrag.Error.pasteboardWriteFailed
        }
        return VaultPaneTestDrag(
            dragID: dragID,
            pasteboard: pasteboard,
            registration: registration,
            sessionRegistry: sessionRegistry,
            tabDragTransferRegistry: tabDragTransferRegistry
        )
    }

    func dropRequest(
        for drag: VaultPaneTestDrag,
        placement: Placement,
        targetPane: PaneID
    ) throws -> BonsplitController.ExternalTabDropRequest {
        let transfer = try #require(drag.resolvedTransfer)
        let destination: BonsplitController.ExternalTabDropRequest.Destination
        switch placement {
        case .center:
            destination = .insert(targetPane: targetPane, targetIndex: nil)
        case .right:
            destination = .split(
                targetPane: targetPane,
                orientation: .horizontal,
                insertFirst: false
            )
        }
        return BonsplitController.ExternalTabDropRequest(
            tabId: transfer.tab.id,
            sourcePaneId: transfer.sourcePaneId,
            destination: destination
        )
    }

    func dropPoint(for placement: Placement, in bounds: NSRect) -> NSPoint {
        switch placement {
        case .center:
            NSPoint(x: bounds.midX, y: bounds.midY)
        case .right:
            NSPoint(x: bounds.maxX - 4, y: bounds.midY)
        }
    }

    func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

}

/// Retains both capability leases for one synthetic native Vault drag.
@MainActor
final class VaultPaneTestDrag {
    enum Error: Swift.Error {
        case registrationFailed
        case pasteboardWriteFailed
    }

    let dragID: UUID
    let pasteboard: NSPasteboard
    private let registration: TabDragTransferRegistration
    private let sessionRegistry: SessionDragRegistry
    private let tabDragTransferRegistry: TabDragTransferRegistry
    private var isFinished = false

    var resolvedTransfer: TabDragTransfer? {
        tabDragTransferRegistry.resolve(from: pasteboard)
    }

    init(
        dragID: UUID,
        pasteboard: NSPasteboard,
        registration: TabDragTransferRegistration,
        sessionRegistry: SessionDragRegistry,
        tabDragTransferRegistry: TabDragTransferRegistry
    ) {
        self.dragID = dragID
        self.pasteboard = pasteboard
        self.registration = registration
        self.sessionRegistry = sessionRegistry
        self.tabDragTransferRegistry = tabDragTransferRegistry
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        tabDragTransferRegistry.end(registration)
        sessionRegistry.discard(id: dragID)
    }
}

/// Isolated app composition root shared by Vault pane-drop behavior tests.
@MainActor
final class VaultPaneAppFixture {
    private enum FixtureError: Error {
        case missingSelectedWorkspace
    }

    let previousAppDelegate: AppDelegate?
    let appDelegate: AppDelegate
    let manager: TabManager
    let windowID: UUID
    let workspace: Workspace

    init() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            tabDragTransferRegistry: appDelegate.tabDragTransferRegistry
        )
        guard let workspace = manager.selectedWorkspace else {
            throw FixtureError.missingSelectedWorkspace
        }

        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager
        )

        self.previousAppDelegate = previousAppDelegate
        self.appDelegate = appDelegate
        self.manager = manager
        self.windowID = windowID
        self.workspace = workspace
    }

    func tearDown() {
        workspace.teardownAllPanels()
        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        AppDelegate.shared = previousAppDelegate
    }
}
