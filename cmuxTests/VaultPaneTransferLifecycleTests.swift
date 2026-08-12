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
    private typealias TargetKind = VaultPaneDropTestHarness.TargetKind
    private typealias Placement = VaultPaneDropTestHarness.Placement
    private let dropHarness = VaultPaneDropTestHarness(suiteName: "lifecycle")

    private struct DockDropCase: Sendable {
        let targetKind: TargetKind
        let placement: Placement
    }

    private nonisolated static let dockDropCases = [
        DockDropCase(targetKind: .terminal, placement: .center),
        DockDropCase(targetKind: .terminal, placement: .right),
        DockDropCase(targetKind: .browser, placement: .center),
        DockDropCase(targetKind: .browser, placement: .right),
    ]

    @Test("A native Vault source publishes the live capability before browser hit testing")
    func nativeSourcePublishesLiveCapabilityForBrowserPortal() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }

            let registry = fixture.appDelegate.sessionDragRegistry
            let staleEntry = Self.makeEntry(sessionID: "stale-portal-capability")
            let staleDragID = registry.register(staleEntry)
            let stalePasteboard = try dropHarness.vaultPasteboard(
                entry: staleEntry,
                dragID: staleDragID
            )
            let transferType = DragOverlayRoutingPolicy.bonsplitTabTransferType
            let staleData = try #require(stalePasteboard.data(forType: transferType))
            registry.discard(id: staleDragID)

            let dragPasteboard = NSPasteboard(name: .drag)
            dragPasteboard.clearContents()
            #expect(dragPasteboard.setData(staleData, forType: transferType))
            defer { dragPasteboard.clearContents() }

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
            let targetPanelID = try #require(fixture.workspace.focusedPanelId)
            let targetPane = try #require(
                fixture.workspace.paneId(forPanelId: targetPanelID)
            )
            slot.setPaneDropContext(PaneDropContext(
                workspaceId: fixture.workspace.id,
                panelId: targetPanelID,
                paneId: targetPane
            ))
            host.layoutSubtreeIfNeeded()
            slot.layoutSubtreeIfNeeded()

            var activeSource: SessionDragSessionSource?
            let coordinator = SessionDragCoordinator(
                startDraggingSession: { _, _, _, source in
                    activeSource = source
                }
            )
            let sourceView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            let activeEntry = Self.makeEntry(sessionID: "live-portal-capability")
            let sourceEvent = try dropHarness.mouseEvent(
                type: .leftMouseDown,
                location: NSPoint(x: 20, y: 12),
                window: window
            )
            #expect(coordinator.beginSessionDrag(
                activeEntry,
                registry: registry,
                from: sourceView,
                event: sourceEvent,
                frame: sourceView.bounds,
                image: NSImage(size: sourceView.bounds.size)
            ))
            let source = try #require(activeSource)
            defer { source.finishDrag() }

            let pointInSlot = NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)
            let pointInHost = host.convert(pointInSlot, from: slot)
            let pointerEvent = try dropHarness.mouseEvent(
                type: .leftMouseDragged,
                location: host.convert(pointInHost, to: nil),
                window: window
            )
            let hit = host.performHitTest(
                at: pointInHost,
                currentEvent: pointerEvent,
                dragPasteboard: dragPasteboard
            )

            #expect(hit is BrowserPaneDropTargetView)
            let transfer = try #require(PaneDragTransfer.decode(from: dragPasteboard))
            #expect(transfer.tabId == source.dragID)
            guard case .vaultSession(let resolvedEntry)? = PaneTransferSourceResolver(
                vaultSessionRegistry: { registry },
                filePreview: { _ in nil },
                surfaceIsLive: { _ in false }
            ).source(for: transfer) else {
                Issue.record("Expected the live drag pasteboard to resolve the active Vault session")
                return
            }
            #expect(resolvedEntry == activeEntry)
        }
    }

    @Test("Browser portal preserves an accepted Vault target through mouse-up")
    func browserPortalPreservesAcceptedVaultTargetThroughMouseUp() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }

            let targetPanelID = try #require(fixture.workspace.focusedPanelId)
            let targetPane = try #require(fixture.workspace.paneId(forPanelId: targetPanelID))
            let entry = Self.makeEntry(sessionID: "browser-portal-mouse-up")
            let dragID = fixture.appDelegate.sessionDragRegistry.register(entry)
            defer { fixture.appDelegate.sessionDragRegistry.discard(id: dragID) }
            let pasteboard = try dropHarness.vaultPasteboard(
                entry: entry,
                dragID: dragID
            )

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
            let dragInfo = VaultPaneDraggingInfo(
                window: window,
                location: pointInWindow,
                pasteboard: pasteboard
            )

            #expect(target.draggingEntered(dragInfo) == .move)
            let mouseUp = try dropHarness.mouseEvent(
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
    private func dockTargetsAcceptVaultSessions(_ dropCase: DockDropCase) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }

            let dock = fixture.workspace.dockSplit
            let targetPane = try #require(dock.bonsplitController.allPaneIds.first)
            let targetPanelID: UUID
            switch dropCase.targetKind {
            case .terminal:
                targetPanelID = try #require(dock.newSurface(
                    kind: .terminal,
                    inPane: targetPane,
                    focus: false
                ))
            case .browser:
                targetPanelID = try #require(dock.newSurface(
                    kind: .browser,
                    inPane: targetPane,
                    url: URL(string: "about:blank"),
                    focus: false,
                    allowsExternalBrowserFallback: false
                ))
                #expect(dock.panels[targetPanelID] is BrowserPanel)
            }
            let context = PaneDropContext(
                workspaceId: fixture.workspace.id,
                panelId: targetPanelID,
                paneId: targetPane
            )
            let entry = Self.makeEntry(
                sessionID: "dock-\(dropCase.targetKind)-\(dropCase.placement)"
            )
            let launch = try #require(entry.resumeLaunch)
            let dragID = fixture.appDelegate.sessionDragRegistry.register(entry)
            defer { fixture.appDelegate.sessionDragRegistry.discard(id: dragID) }
            let pasteboard = try dropHarness.vaultPasteboard(
                entry: entry,
                dragID: dragID
            )
            let baselinePanelIDs = Set(dock.panels.keys)
            let baselinePaneCount = dock.bonsplitController.allPaneIds.count

            let handled = try dropHarness.performDrop(
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
            let fixture = try VaultPaneAppFixture()
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
                let registry = fixture.appDelegate.sessionDragRegistry
                let dragID = registry.register(row.entry)
                defer { registry.discard(id: dragID) }
                let pasteboard = try dropHarness.vaultPasteboard(
                    entry: row.entry,
                    dragID: dragID
                )
                let dragInfo = VaultPaneDraggingInfo(
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
                    registry.discard(id: dragID)
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

    private final class OccludingBrowserContentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

}
