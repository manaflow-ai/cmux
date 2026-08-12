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
@Suite(.serialized)
struct VaultPaneDropRoutingTests {
    private enum TargetKind: Sendable {
        case terminal
        case browser
    }

    private enum Placement: Sendable {
        case center
        case right
    }

    private struct DropCase: Sendable {
        let targetKind: TargetKind
        let placement: Placement
    }

    private static let dropCases = [
        DropCase(targetKind: .terminal, placement: .center),
        DropCase(targetKind: .terminal, placement: .right),
        DropCase(targetKind: .browser, placement: .center),
        DropCase(targetKind: .browser, placement: .right),
    ]

    @Test(
        "Vault sessions use the same pane-drop behavior for terminal and browser targets",
        arguments: dropCases
    )
    private func vaultSessionDropCreatesRestoreTerminal(_ dropCase: DropCase) throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let workspace = try #require(manager.selectedWorkspace)
        defer {
            workspace.teardownAllPanels()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }

        let initialPanelID = try #require(workspace.focusedPanelId)
        let targetPane = try #require(workspace.paneId(forPanelId: initialPanelID))
        let targetPanelID: UUID
        switch dropCase.targetKind {
        case .terminal:
            targetPanelID = initialPanelID
        case .browser:
            let browser = try #require(workspace.newBrowserSurface(
                inPane: targetPane,
                url: URL(string: "about:blank"),
                focus: true,
                creationPolicy: .restoration,
                allowsExternalBrowserFallback: false
            ))
            targetPanelID = browser.id
        }

        let sessionID = "vault-pane-drop-\(UUID().uuidString)"
        let entry = SessionEntry(
            id: "codex:\(sessionID)",
            agent: .codex,
            sessionId: sessionID,
            title: "Vault pane drop",
            cwd: "/tmp",
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
        let launch = try #require(entry.resumeLaunch)
        let dragID = SessionDragRegistry.shared.register(entry)
        defer { _ = SessionDragRegistry.shared.consume(id: dragID) }

        let pasteboard = try vaultPasteboard(dragID: dragID)
        let baselinePanelIDs = Set(workspace.panels.keys)
        let baselinePaneCount = workspace.bonsplitController.allPaneIds.count
        let context = PaneDropContext(
            workspaceId: workspace.id,
            panelId: targetPanelID,
            paneId: targetPane
        )

        let handled = try performDrop(
            targetKind: dropCase.targetKind,
            placement: dropCase.placement,
            context: context,
            pasteboard: pasteboard
        )

        #expect(handled)
        let createdPanelIDs = Set(workspace.panels.keys).subtracting(baselinePanelIDs)
        #expect(createdPanelIDs.count == 1)
        let createdPanelID = try #require(createdPanelIDs.first)
        let terminal = try #require(workspace.terminalPanel(for: createdPanelID))
        #expect(terminal.surface.debugInitialInputForTesting() == launch.initialInput)
        #expect(workspace.restoredAgentSnapshotsByPanelId[createdPanelID]?.sessionId == sessionID)

        let createdPane = try #require(workspace.paneId(forPanelId: createdPanelID))
        switch dropCase.placement {
        case .center:
            #expect(createdPane == targetPane)
            #expect(workspace.bonsplitController.allPaneIds.count == baselinePaneCount)
        case .right:
            #expect(createdPane != targetPane)
            #expect(workspace.bonsplitController.allPaneIds.count == baselinePaneCount + 1)
            #expect(workspace.bonsplitController.adjacentPane(to: targetPane, direction: .right) == createdPane)
        }
    }

    @Test("Every Vault row in one folder remains independently draggable when identities repeat")
    private func repeatedFolderRowsRemainDraggable() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let workspace = try #require(manager.selectedWorkspace)
        defer {
            workspace.teardownAllPanels()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }

        let initialPanelID = try #require(workspace.focusedPanelId)
        let targetPane = try #require(workspace.paneId(forPanelId: initialPanelID))
        let browser = try #require(workspace.newBrowserSurface(
            inPane: targetPane,
            url: URL(string: "about:blank"),
            focus: true,
            creationPolicy: .restoration,
            allowsExternalBrowserFallback: false
        ))
        let context = PaneDropContext(
            workspaceId: workspace.id,
            panelId: browser.id,
            paneId: targetPane
        )

        let duplicate = Self.makeEntry(
            id: "codex:/tmp/repeated-folder/duplicate.jsonl",
            sessionID: "repeated-folder-duplicate",
            title: "Duplicate Vault row"
        )
        let entries = [
            duplicate,
            duplicate,
            Self.makeEntry(
                id: "codex:/tmp/repeated-folder/distinct.jsonl",
                sessionID: "repeated-folder-distinct",
                title: "Distinct Vault row"
            ),
        ]
        let rows = SessionIndexRowSnapshot.rows(for: entries)

        #expect(rows.map(\.entry) == entries)
        #expect(Set(rows.map(\.id)).count == entries.count)

        for row in rows {
            let launch = try #require(row.entry.resumeLaunch)
            let dragID = SessionDragRegistry.shared.register(row.entry)
            let pasteboard = try vaultPasteboard(dragID: dragID)
            let baselinePanelIDs = Set(workspace.panels.keys)

            let handled = try performDrop(
                targetKind: .browser,
                placement: .center,
                context: context,
                pasteboard: pasteboard
            )

            #expect(handled)
            #expect(SessionDragRegistry.shared.consume(id: dragID) == nil)
            let createdPanelIDs = Set(workspace.panels.keys).subtracting(baselinePanelIDs)
            #expect(createdPanelIDs.count == 1)
            let createdPanelID = try #require(createdPanelIDs.first)
            let terminal = try #require(workspace.terminalPanel(for: createdPanelID))
            #expect(terminal.surface.debugInitialInputForTesting() == launch.initialInput)
        }
    }

    @Test("A live Vault drag reaches the portal-hosted browser pane target")
    private func liveVaultDragReachesBrowserPortalTarget() throws {
        let entry = Self.makeEntry(
            id: "codex:/tmp/portal-route/session.jsonl",
            sessionID: "portal-route-session",
            title: "Portal-routed Vault row"
        )
        let dragID = SessionDragRegistry.shared.register(entry)
        defer { _ = SessionDragRegistry.shared.consume(id: dragID) }

        let pasteboard = try vaultPasteboard(dragID: dragID)
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let root = NSView(frame: frame)
        window.contentView = root
        let host = WindowBrowserHostView(frame: root.bounds)
        root.addSubview(host)
        let slot = WindowBrowserSlotView(frame: host.bounds)
        host.addSubview(slot)
        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID()
        ))
        host.layoutSubtreeIfNeeded()
        slot.layoutSubtreeIfNeeded()

        let point = NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)
        let pointInHost = host.convert(point, from: slot)
        let pointInWindow = host.convert(pointInHost, to: nil)
        let event = makeMouseEvent(
            type: .leftMouseDragged,
            location: pointInWindow,
            window: window
        )

        let hit = host.performHitTest(
            at: pointInHost,
            currentEvent: event,
            dragPasteboard: pasteboard
        )

        #expect(hit is BrowserPaneDropTargetView)
    }

    @Test("A canceled Vault drag cannot poison the next duplicate row")
    private func canceledVaultDragDoesNotPoisonNextDuplicate() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let workspace = try #require(manager.selectedWorkspace)
        defer {
            workspace.teardownAllPanels()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }

        let initialPanelID = try #require(workspace.focusedPanelId)
        let targetPane = try #require(workspace.paneId(forPanelId: initialPanelID))
        let browser = try #require(workspace.newBrowserSurface(
            inPane: targetPane,
            url: URL(string: "about:blank"),
            focus: true,
            creationPolicy: .restoration,
            allowsExternalBrowserFallback: false
        ))
        let context = BrowserPaneDropContext(
            workspaceId: workspace.id,
            panelId: browser.id,
            paneId: targetPane
        )

        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let root = NSView(frame: frame)
        window.contentView = root
        let slot = WindowBrowserSlotView(frame: root.bounds)
        root.addSubview(slot)
        slot.setPaneDropContext(context)
        slot.layoutSubtreeIfNeeded()
        let localPoint = NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)
        let target = try #require(slot.paneDropTargetForDrop(at: localPoint))

        let duplicate = Self.makeEntry(
            id: "codex:/tmp/repeated-folder/duplicate.jsonl",
            sessionID: "repeated-folder-duplicate",
            title: "Duplicate Vault row"
        )
        let canceledDragID = SessionDragRegistry.shared.register(duplicate)
        let canceledPasteboard = try vaultPasteboard(dragID: canceledDragID)
        #expect(SessionDragRegistry.shared.consume(id: canceledDragID) == duplicate)
        let canceledDragInfo = MockDraggingInfo(
            window: window,
            location: slot.convert(localPoint, to: nil),
            pasteboard: canceledPasteboard
        )

        #expect(target.draggingEntered(canceledDragInfo).isEmpty)
        #expect(!target.prepareForDragOperation(canceledDragInfo))
        target.draggingExited(canceledDragInfo)

        let nextDragID = SessionDragRegistry.shared.register(duplicate)
        defer { _ = SessionDragRegistry.shared.consume(id: nextDragID) }
        let nextPasteboard = try vaultPasteboard(dragID: nextDragID)
        let nextDragInfo = MockDraggingInfo(
            window: window,
            location: slot.convert(localPoint, to: nil),
            pasteboard: nextPasteboard
        )
        let baselinePanelIDs = Set(workspace.panels.keys)

        #expect(target.draggingEntered(nextDragInfo) == .move)
        #expect(target.prepareForDragOperation(nextDragInfo))
        #expect(target.performDragOperation(nextDragInfo))

        let createdPanelIDs = Set(workspace.panels.keys).subtracting(baselinePanelIDs)
        #expect(createdPanelIDs.count == 1)
        let createdPanelID = try #require(createdPanelIDs.first)
        let terminal = try #require(workspace.terminalPanel(for: createdPanelID))
        #expect(terminal.surface.debugInitialInputForTesting() == duplicate.resumeLaunch?.initialInput)
    }

    private func performDrop(
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

        let root = NSView(frame: frame)
        window.contentView = root

        switch targetKind {
        case .terminal:
            let target = PaneDropTargetView(frame: root.bounds)
            target.dropContext = context
            root.addSubview(target)
            let dragInfo = MockDraggingInfo(
                window: window,
                location: target.convert(dropPoint(for: placement, in: target.bounds), to: nil),
                pasteboard: pasteboard
            )
            #expect(target.draggingEntered(dragInfo) == .move)
            #expect(target.prepareForDragOperation(dragInfo))
            return target.performDragOperation(dragInfo)

        case .browser:
            let slot = WindowBrowserSlotView(frame: root.bounds)
            root.addSubview(slot)
            slot.setPaneDropContext(BrowserPaneDropContext(
                workspaceId: context.workspaceId,
                panelId: context.panelId,
                paneId: context.paneId
            ))
            slot.layoutSubtreeIfNeeded()
            let localPoint = dropPoint(for: placement, in: slot.bounds)
            let target = try #require(slot.paneDropTargetForDrop(at: localPoint))
            let dragInfo = MockDraggingInfo(
                window: window,
                location: slot.convert(localPoint, to: nil),
                pasteboard: pasteboard
            )
            #expect(target.draggingEntered(dragInfo) == .move)
            #expect(target.prepareForDragOperation(dragInfo))
            return target.performDragOperation(dragInfo)
        }
    }

    private func dropPoint(for placement: Placement, in bounds: NSRect) -> NSPoint {
        switch placement {
        case .center:
            NSPoint(x: bounds.midX, y: bounds.midY)
        case .right:
            NSPoint(x: bounds.maxX - 4, y: bounds.midY)
        }
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("Failed to create mouse event")
        }
        return event
    }

    private func vaultPasteboard(dragID: UUID) throws -> NSPasteboard {
        let payload = try JSONSerialization.data(withJSONObject: [
            "tab": ["id": dragID.uuidString, "kind": "terminal"],
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier),
        ])
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("cmux.test.vault-pane-drop.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setData(payload, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
        return pasteboard
    }

    private static func makeEntry(
        id: String,
        sessionID: String,
        title: String
    ) -> SessionEntry {
        SessionEntry(
            id: id,
            agent: .codex,
            sessionId: sessionID,
            title: title,
            cwd: "/tmp/repeated-folder",
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

    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation = .move
        let draggingLocation: NSPoint
        let draggedImageLocation: NSPoint
        let draggedImage: NSImage? = nil
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        nonisolated(unsafe) let draggingSource: Any? = nil
        let draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            draggingDestinationWindow = window
            draggingLocation = location
            draggedImageLocation = location
            draggingPasteboard = pasteboard
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
