import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Vault pane-transfer lifecycle", .serialized)
struct VaultPaneTransferLifecycleTests {
    private enum TargetKind: Sendable {
        case terminal
        case browser
    }

    private enum Placement: Sendable {
        case center
        case right
    }

    private struct DockDropCase: Sendable {
        let targetKind: TargetKind
        let placement: Placement
    }

    private static let dockDropCases = [
        DockDropCase(targetKind: .terminal, placement: .center),
        DockDropCase(targetKind: .terminal, placement: .right),
        DockDropCase(targetKind: .browser, placement: .center),
        DockDropCase(targetKind: .browser, placement: .right),
    ]

    @Test("Browser portal preserves an accepted Vault target through mouse-up")
    func browserPortalPreservesAcceptedVaultTargetThroughMouseUp() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try AppFixture()
            defer { fixture.tearDown() }

            let targetPanelID = try #require(fixture.workspace.focusedPanelId)
            let targetPane = try #require(fixture.workspace.paneId(forPanelId: targetPanelID))
            let entry = Self.makeEntry(sessionID: "browser-portal-mouse-up")
            let dragID = SessionDragRegistry.shared.register(entry)
            defer { SessionDragRegistry.shared.discard(id: dragID) }
            let pasteboard = try Self.vaultPasteboard(dragID: dragID)

            let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer { window.orderOut(nil) }
            let root = try #require(window.contentView)
            let host = WindowBrowserHostView(frame: root.bounds)
            root.addSubview(host)
            let slot = WindowBrowserSlotView(frame: host.bounds)
            host.addSubview(slot)
            slot.setPaneDropContext(PaneDropContext(
                workspaceId: fixture.workspace.id,
                panelId: targetPanelID,
                paneId: targetPane
            ))
            host.layoutSubtreeIfNeeded()
            slot.layoutSubtreeIfNeeded()

            let blocker = OccludingBrowserContentView(frame: slot.bounds)
            slot.addSubview(blocker, positioned: .above, relativeTo: nil)
            let pointInSlot = NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)
            let target = try #require(slot.paneDropTargetForDrop(at: pointInSlot))
            let pointInHost = host.convert(pointInSlot, from: slot)
            let pointInWindow = host.convert(pointInHost, to: nil)
            let dragInfo = MockDraggingInfo(
                window: window,
                location: pointInWindow,
                pasteboard: pasteboard
            )

            #expect(target.draggingEntered(dragInfo) == .move)
            let mouseUp = try Self.mouseEvent(
                type: .leftMouseUp,
                location: pointInWindow,
                window: window
            )
            let hit = host.performHitTest(
                at: pointInHost,
                currentEvent: mouseUp,
                dragPasteboard: pasteboard
            )

            #expect(hit === target)
            target.draggingEnded(dragInfo)
        }
    }

    @Test(
        "Dock terminal and browser targets accept Vault sessions with shared placement",
        arguments: dockDropCases
    )
    func dockTargetsAcceptVaultSessions(_ dropCase: DockDropCase) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try AppFixture()
            defer { fixture.tearDown() }

            let dock = fixture.workspace.dockSplit
            let targetPane = try #require(dock.bonsplitController.allPaneIds.first)
            let targetPanelID = try #require(dock.newSurface(
                kind: .terminal,
                inPane: targetPane,
                focus: false
            ))
            let context = PaneDropContext(
                workspaceId: fixture.workspace.id,
                panelId: targetPanelID,
                paneId: targetPane
            )
            let entry = Self.makeEntry(
                sessionID: "dock-\(dropCase.targetKind)-\(dropCase.placement)"
            )
            let launch = try #require(entry.resumeLaunch)
            let dragID = SessionDragRegistry.shared.register(entry)
            defer { SessionDragRegistry.shared.discard(id: dragID) }
            let pasteboard = try Self.vaultPasteboard(dragID: dragID)
            let baselinePanelIDs = Set(dock.panels.keys)
            let baselinePaneCount = dock.bonsplitController.allPaneIds.count

            let handled = try Self.performDrop(
                targetKind: dropCase.targetKind,
                placement: dropCase.placement,
                context: context,
                pasteboard: pasteboard
            )

            #expect(handled)
            let createdPanelIDs = Set(dock.panels.keys).subtracting(baselinePanelIDs)
            #expect(createdPanelIDs.count == 1)
            let createdPanelID = try #require(createdPanelIDs.first)
            let terminal = try #require(dock.panels[createdPanelID] as? TerminalPanel)
            #expect(terminal.surface.debugInitialInputForTesting() == launch.initialInput)
            #expect(dock.restoredAgentLifecycle.snapshotsByPanelId[createdPanelID]?.sessionId == entry.sessionId)

            let createdPane = try #require(dock.paneId(forPanelId: createdPanelID))
            switch dropCase.placement {
            case .center:
                #expect(createdPane == targetPane)
                #expect(dock.bonsplitController.allPaneIds.count == baselinePaneCount)
            case .right:
                #expect(createdPane != targetPane)
                #expect(dock.bonsplitController.allPaneIds.count == baselinePaneCount + 1)
                #expect(dock.bonsplitController.adjacentPane(to: targetPane, direction: .right) == createdPane)
            }
        }
    }

    @Test("Every repeated Vault row survives prior drag cleanup")
    func repeatedVaultRowsSurvivePriorDragCleanup() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try AppFixture()
            defer { fixture.tearDown() }

            let initialPanelID = try #require(fixture.workspace.focusedPanelId)
            let targetPane = try #require(fixture.workspace.paneId(forPanelId: initialPanelID))
            let browser = try #require(fixture.workspace.newBrowserSurface(
                inPane: targetPane,
                url: URL(string: "about:blank"),
                focus: true,
                creationPolicy: .restoration,
                allowsExternalBrowserFallback: false
            ))
            let context = PaneDropContext(
                workspaceId: fixture.workspace.id,
                panelId: browser.id,
                paneId: targetPane
            )

            let duplicate = Self.makeEntry(sessionID: "repeated-folder-duplicate")
            let rows = SessionIndexRowSnapshot.rows(for: [
                duplicate,
                duplicate,
                Self.makeEntry(sessionID: "repeated-folder-distinct"),
            ])
            #expect(Set(rows.map(\.id)).count == rows.count)

            let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer { window.orderOut(nil) }
            let root = try #require(window.contentView)
            let host = WindowBrowserHostView(frame: root.bounds)
            root.addSubview(host)
            let slot = WindowBrowserSlotView(frame: host.bounds)
            host.addSubview(slot)
            slot.setPaneDropContext(context)
            host.layoutSubtreeIfNeeded()
            slot.layoutSubtreeIfNeeded()
            let point = NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)
            let target = try #require(slot.paneDropTargetForDrop(at: point))

            for (index, row) in rows.enumerated() {
                let dragID = SessionDragRegistry.shared.register(row.entry)
                defer { SessionDragRegistry.shared.discard(id: dragID) }
                let pasteboard = try Self.vaultPasteboard(dragID: dragID)
                let dragInfo = MockDraggingInfo(
                    window: window,
                    location: slot.convert(point, to: nil),
                    pasteboard: pasteboard,
                    sequenceNumber: index + 1
                )
                let baselinePanelIDs = Set(fixture.workspace.panels.keys)

                #expect(target.draggingEntered(dragInfo) == .move)
                if index == 0 {
                    // Model release-time cleanup after the target already accepted
                    // the drag. Execution must use that resolved plan, not re-read
                    // mutable process-wide drag state.
                    SessionDragRegistry.shared.discard(id: dragID)
                }
                #expect(target.prepareForDragOperation(dragInfo))
                #expect(target.performDragOperation(dragInfo))

                let createdPanelIDs = Set(fixture.workspace.panels.keys)
                    .subtracting(baselinePanelIDs)
                #expect(createdPanelIDs.count == 1)
                let createdPanelID = try #require(createdPanelIDs.first)
                let terminal = try #require(fixture.workspace.terminalPanel(for: createdPanelID))
                #expect(
                    terminal.surface.debugInitialInputForTesting()
                        == row.entry.resumeLaunch?.initialInput
                )
            }
        }
    }

    private static func performDrop(
        targetKind: TargetKind,
        placement: Placement,
        context: PaneDropContext,
        pasteboard: NSPasteboard
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
            let dragInfo = MockDraggingInfo(
                window: window,
                location: target.convert(point, to: nil),
                pasteboard: pasteboard
            )
            #expect(target.draggingEntered(dragInfo) == .move)
            #expect(target.prepareForDragOperation(dragInfo))
            return target.performDragOperation(dragInfo)

        case .browser:
            let slot = WindowBrowserSlotView(frame: root.bounds)
            root.addSubview(slot)
            slot.setPaneDropContext(context)
            slot.layoutSubtreeIfNeeded()
            let point = dropPoint(for: placement, in: slot.bounds)
            let target = try #require(slot.paneDropTargetForDrop(at: point))
            let dragInfo = MockDraggingInfo(
                window: window,
                location: slot.convert(point, to: nil),
                pasteboard: pasteboard
            )
            #expect(target.draggingEntered(dragInfo) == .move)
            #expect(target.prepareForDragOperation(dragInfo))
            return target.performDragOperation(dragInfo)
        }
    }

    private static func dropPoint(for placement: Placement, in bounds: NSRect) -> NSPoint {
        switch placement {
        case .center:
            return NSPoint(x: bounds.midX, y: bounds.midY)
        case .right:
            return NSPoint(x: bounds.maxX - 4, y: bounds.midY)
        }
    }

    private static func makeEntry(sessionID: String) -> SessionEntry {
        SessionEntry(
            id: "codex:/tmp/vault-pane-transfer/\(sessionID).jsonl",
            agent: .codex,
            sessionId: sessionID,
            title: "Vault pane transfer",
            cwd: "/tmp/vault-pane-transfer",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_000),
            fileURL: nil,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
    }

    private static func vaultPasteboard(dragID: UUID) throws -> NSPasteboard {
        let payload = try JSONSerialization.data(withJSONObject: [
            "tab": ["id": dragID.uuidString, "kind": "terminal"],
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier),
        ])
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("cmux.test.vault-pane-lifecycle.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setData(payload, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
        return pasteboard
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private final class AppFixture {
        let previousAppDelegate: AppDelegate?
        let appDelegate: AppDelegate
        let manager: TabManager
        let windowID: UUID
        let workspace: Workspace

        init() throws {
            previousAppDelegate = AppDelegate.shared
            appDelegate = AppDelegate()
            manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            workspace = try #require(manager.selectedWorkspace)
        }

        func tearDown() {
            workspace.teardownAllPanels()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }
    }

    private final class OccludingBrowserContentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
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

        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
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
}
