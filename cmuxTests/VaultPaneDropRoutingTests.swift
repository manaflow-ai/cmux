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
    private typealias TargetKind = VaultPaneDropTestHarness.TargetKind
    private typealias Placement = VaultPaneDropTestHarness.Placement
    private let dropHarness = VaultPaneDropTestHarness(suiteName: "routing")

    private struct DropCase: Sendable {
        let targetKind: TargetKind
        let placement: Placement
    }

    private nonisolated static let dropCases = [
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
        let fixture = try VaultPaneAppFixture()
        defer { fixture.tearDown() }
        let appDelegate = fixture.appDelegate
        let workspace = fixture.workspace

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
        let dragID = appDelegate.sessionDragRegistry.register(entry)
        defer { appDelegate.sessionDragRegistry.discard(id: dragID) }

        let pasteboard = try dropHarness.vaultPasteboard(entry: entry, dragID: dragID)
        let baselinePanelIDs = Set(workspace.panels.keys)
        let baselinePaneCount = workspace.bonsplitController.allPaneIds.count
        let context = PaneDropContext(
            workspaceId: workspace.id,
            panelId: targetPanelID,
            paneId: targetPane
        )

        let handled = try dropHarness.performDrop(
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
        let fixture = try VaultPaneAppFixture()
        defer { fixture.tearDown() }
        let appDelegate = fixture.appDelegate
        let workspace = fixture.workspace

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
            let dragID = appDelegate.sessionDragRegistry.register(row.entry)
            let pasteboard = try dropHarness.vaultPasteboard(
                entry: row.entry,
                dragID: dragID
            )
            let baselinePanelIDs = Set(workspace.panels.keys)

            let handled = try dropHarness.performDrop(
                targetKind: .browser,
                placement: .center,
                context: context,
                pasteboard: pasteboard
            )

            #expect(handled)
            #expect(appDelegate.sessionDragRegistry.entry(id: dragID) == nil)
            let createdPanelIDs = Set(workspace.panels.keys).subtracting(baselinePanelIDs)
            #expect(createdPanelIDs.count == 1)
            let createdPanelID = try #require(createdPanelIDs.first)
            let terminal = try #require(workspace.terminalPanel(for: createdPanelID))
            #expect(terminal.surface.debugInitialInputForTesting() == launch.initialInput)
        }
    }

    @Test("A live Vault drag reaches the portal-hosted browser pane target")
    private func liveVaultDragReachesBrowserPortalTarget() throws {
        let fixture = try VaultPaneAppFixture()
        defer { fixture.tearDown() }
        let appDelegate = fixture.appDelegate

        let entry = Self.makeEntry(
            id: "codex:/tmp/portal-route/session.jsonl",
            sessionID: "portal-route-session",
            title: "Portal-routed Vault row"
        )
        let dragID = appDelegate.sessionDragRegistry.register(entry)
        defer { appDelegate.sessionDragRegistry.discard(id: dragID) }

        let pasteboard = try dropHarness.vaultPasteboard(entry: entry, dragID: dragID)
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
        let event = try dropHarness.mouseEvent(
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
        let fixture = try VaultPaneAppFixture()
        defer { fixture.tearDown() }
        let appDelegate = fixture.appDelegate
        let workspace = fixture.workspace

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
        let canceledDragID = appDelegate.sessionDragRegistry.register(duplicate)
        let canceledPasteboard = try dropHarness.vaultPasteboard(
            entry: duplicate,
            dragID: canceledDragID
        )
        #expect(appDelegate.sessionDragRegistry.consume(id: canceledDragID) == duplicate)
        let canceledDragInfo = VaultPaneDraggingInfo(
            window: window,
            location: slot.convert(localPoint, to: nil),
            pasteboard: canceledPasteboard
        )

        #expect(target.draggingEntered(canceledDragInfo).isEmpty)
        #expect(!target.prepareForDragOperation(canceledDragInfo))
        target.draggingExited(canceledDragInfo)

        let nextDragID = appDelegate.sessionDragRegistry.register(duplicate)
        defer { appDelegate.sessionDragRegistry.discard(id: nextDragID) }
        let nextPasteboard = try dropHarness.vaultPasteboard(
            entry: duplicate,
            dragID: nextDragID
        )
        let nextDragInfo = VaultPaneDraggingInfo(
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

}
