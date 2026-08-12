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

    func performDrop(
        targetKind: TargetKind,
        placement: Placement,
        context: PaneDropContext,
        pasteboard: NSPasteboard,
        sequenceNumber: Int = 1
    ) throws -> Bool {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let root = try #require(window.contentView)

        switch targetKind {
        case .terminal:
            let target = PaneDropTargetView(frame: root.bounds)
            target.dropContext = context
            root.addSubview(target)
            let point = dropPoint(for: placement, in: target.bounds)
            let dragInfo = VaultPaneDraggingInfo(
                window: window,
                location: target.convert(point, to: nil),
                pasteboard: pasteboard,
                sequenceNumber: sequenceNumber
            )
            #expect(target.draggingEntered(dragInfo) == .move)
            defer { target.draggingEnded(dragInfo) }
            #expect(target.prepareForDragOperation(dragInfo))
            return target.performDragOperation(dragInfo)

        case .browser:
            let slot = WindowBrowserSlotView(frame: root.bounds)
            root.addSubview(slot)
            slot.setPaneDropContext(context)
            slot.layoutSubtreeIfNeeded()
            let point = dropPoint(for: placement, in: slot.bounds)
            let target = try #require(slot.paneDropTargetForDrop(at: point))
            let dragInfo = VaultPaneDraggingInfo(
                window: window,
                location: slot.convert(point, to: nil),
                pasteboard: pasteboard,
                sequenceNumber: sequenceNumber
            )
            #expect(target.draggingEntered(dragInfo) == .move)
            defer { target.draggingEnded(dragInfo) }
            #expect(target.prepareForDragOperation(dragInfo))
            return target.performDragOperation(dragInfo)
        }
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

    func vaultPasteboard(entry: SessionEntry, dragID: UUID) throws -> NSPasteboard {
        let item = try #require(SessionDragPayload(
            entry: entry,
            dragID: dragID
        ).pasteboardItem())
        let data = try #require(item.data(
            forType: DragOverlayRoutingPolicy.bonsplitTabTransferType
        ))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "\(pasteboardNamePrefix).\(UUID().uuidString)"
        ))
        pasteboard.clearContents()
        pasteboard.setData(
            data,
            forType: DragOverlayRoutingPolicy.bonsplitTabTransferType
        )
        return pasteboard
    }
}

/// Configurable AppKit drag session used by the shared Vault drop harness.
@MainActor
final class VaultPaneDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingLocation: NSPoint
    let draggedImageLocation: NSPoint
    let draggedImage: NSImage? = nil
    nonisolated(unsafe) let draggingPasteboard: NSPasteboard
    nonisolated(unsafe) let draggingSource: Any? = nil
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(
        window: NSWindow,
        location: NSPoint,
        pasteboard: NSPasteboard,
        sequenceNumber: Int = 1
    ) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggedImageLocation = location
        draggingPasteboard = pasteboard
        draggingSequenceNumber = sequenceNumber
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(
        atDestination dropDestination: URL
    ) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
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
        let manager = TabManager(autoWelcomeIfNeeded: false)
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
