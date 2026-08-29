import AppKit
@testable import Bonsplit
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
    private nonisolated static let paneTargetKinds: [TargetKind] = [
        .terminal,
        .browser,
    ]

    @Test("An accepted surface pane transfer finishes its native Bonsplit source")
    func acceptedSurfaceTransferFinishesNativeSource() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let panelID = try #require(fixture.workspace.focusedPanelId)
            let paneID = try #require(fixture.workspace.paneId(forPanelId: panelID))
            let tabID = try #require(fixture.workspace.surfaceIdFromPanelId(panelID))
            let controller = fixture.workspace.bonsplitController
            let sourceTab = try #require(
                controller.internalController
                    .paneState(for: paneID)?
                    .tabs
                    .first(where: { $0.id == tabID.uuid })
            )
            let generation = controller.internalController.beginTabDrag(
                sourceTab,
                from: paneID
            )
            let registry = fixture.appDelegate.tabDragTransferRegistry
            let registration = try #require(registry.register(TabDragTransfer(
                tab: Tab(from: sourceTab),
                sourcePaneId: paneID
            )))
            let source = TabDragSessionSource(
                generation: generation,
                transferRegistration: registration,
                transferRegistry: registry,
                controller: controller.internalController
            )
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(
                "cmux.test.surface-pane-drop.\(UUID().uuidString)"
            ))
            pasteboard.clearContents()
            #expect(registration.write(to: pasteboard))
            defer {
                source.finishDrag()
                pasteboard.clearContents()
            }
            let context = PaneDropContext(
                workspaceId: fixture.workspace.id,
                panelId: panelID,
                paneId: paneID
            )
            let router = PaneTransferDropRouter()
            router.begin(context: context)
            defer { router.clear() }
            guard case .accepted(let plan) = router.resolve(
                pasteboard: pasteboard,
                context: context,
                proposedZone: .center
            ) else {
                Issue.record("Shared pane router rejected a live surface capability")
                return
            }

            #expect(plan.source == .surface)
            #expect(registry.resolve(from: pasteboard) != nil)
            #expect(router.perform(plan, pasteboard: pasteboard))
            #expect(controller.internalController.tabDragSession == nil)
            #expect(registry.resolve(from: pasteboard) == nil)
            withExtendedLifetime(source) {}
        }
    }

    @Test("Every repeated Vault row publishes a live capability to the shared pane registry")
    func repeatedVaultSourcesPublishSharedPaneCapabilities() throws {
        let sessionRegistry = SessionDragRegistry()
        let paneTransferRegistry = TabDragTransferRegistry()
        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.clearContents()
        defer { dragPasteboard.clearContents() }

        var activeSource: SessionDragSessionSource?
        let coordinator = SessionDragCoordinator(
            startDraggingSession: { _, _, _, source in
                activeSource = source
            }
        )
        let frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        let sourceView = NSView(frame: frame)
        let sourceEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 12),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let duplicate = Self.makeEntry(sessionID: "shared-capability-duplicate")
        let entries = [
            duplicate,
            duplicate,
            Self.makeEntry(sessionID: "shared-capability-distinct"),
        ]

        for entry in entries {
            #expect(coordinator.beginSessionDrag(
                entry,
                registry: sessionRegistry,
                tabDragTransferRegistry: paneTransferRegistry,
                from: sourceView,
                event: sourceEvent,
                frame: frame,
                image: NSImage(size: frame.size)
            ))
            let source = try #require(activeSource)
            let transfer = try #require(
                paneTransferRegistry.resolve(from: dragPasteboard)
            )
            #expect(transfer.tab.id.uuid == source.dragID)
            #expect(transfer.tab.title == entry.displayTitle)
            #expect(sessionRegistry.entry(id: source.dragID) == entry)

            source.finishDrag()
            #expect(sessionRegistry.entry(id: source.dragID) == nil)
            #expect(paneTransferRegistry.resolve(from: dragPasteboard) == nil)
            activeSource = nil
        }
    }

    @Test("Browser portal passes a shared Vault capability through every pointer phase")
    func browserPortalPassesSharedCapabilityThroughPointerPhases() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }

            let targetPanelID = try #require(fixture.workspace.focusedPanelId)
            let targetPane = try #require(fixture.workspace.paneId(forPanelId: targetPanelID))
            let entry = Self.makeEntry(sessionID: "browser-portal-mouse-up")
            let drag = try dropHarness.beginVaultDrag(
                entry: entry,
                sessionRegistry: fixture.appDelegate.sessionDragRegistry,
                tabDragTransferRegistry: fixture.appDelegate.tabDragTransferRegistry
            )
            defer { drag.finish() }

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
            let pointInHost = host.convert(pointInSlot, from: slot)
            let pointInWindow = host.convert(pointInHost, to: nil)
            let mouseDragged = try dropHarness.mouseEvent(
                type: .leftMouseDragged,
                location: pointInWindow,
                window: window
            )
            let mouseUp = try dropHarness.mouseEvent(
                type: .leftMouseUp,
                location: pointInWindow,
                window: window
            )
            let dragHit = host.performHitTest(
                at: pointInHost,
                currentEvent: mouseDragged,
                dragPasteboard: drag.pasteboard
            )
            let mouseUpHit = host.performHitTest(
                at: pointInHost,
                currentEvent: mouseUp,
                dragPasteboard: drag.pasteboard
            )

            #expect(dragHit is BrowserPaneDropTargetView)
            #expect(mouseUpHit is BrowserPaneDropTargetView)
            #expect(drag.resolvedTransfer?.tab.id.uuid == drag.dragID)
        }
    }

    @Test(
        "Shared pane router accepts Vault capabilities for every pane kind",
        arguments: paneTargetKinds
    )
    private func paneRouterAcceptsVaultCapability(_ targetKind: TargetKind) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }

            let initialPanelID = try #require(fixture.workspace.focusedPanelId)
            let initialPane = try #require(
                fixture.workspace.paneId(forPanelId: initialPanelID)
            )
            let targetPanelID: UUID
            switch targetKind {
            case .terminal:
                targetPanelID = initialPanelID
            case .browser:
                targetPanelID = try #require(fixture.workspace.newBrowserSurface(
                    inPane: initialPane,
                    url: URL(string: "about:blank"),
                    focus: true,
                    creationPolicy: .restoration,
                    allowsExternalBrowserFallback: false
                )).id
            }
            let targetPane = try #require(
                fixture.workspace.paneId(forPanelId: targetPanelID)
            )
            let context = PaneDropContext(
                workspaceId: fixture.workspace.id,
                panelId: targetPanelID,
                paneId: targetPane
            )
            let entry = Self.makeEntry(sessionID: "router-\(targetKind)")
            let drag = try dropHarness.beginVaultDrag(
                entry: entry,
                sessionRegistry: fixture.appDelegate.sessionDragRegistry,
                tabDragTransferRegistry: fixture.appDelegate.tabDragTransferRegistry
            )
            defer { drag.finish() }

            let router = PaneTransferDropRouter()
            router.begin(context: context)
            defer { router.clear() }
            guard case .accepted(let plan) = router.resolve(
                pasteboard: drag.pasteboard,
                context: context,
                proposedZone: .center
            ) else {
                Issue.record("Shared pane router rejected a live Vault capability")
                return
            }

            #expect(plan.context == context)
            #expect(plan.transfer.tabId == drag.dragID)
            #expect(plan.source == .vaultSession(entry))
            #expect(plan.zone == .center)
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

            let dock = try #require(fixture.workspace.dockSplit)
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
            let entry = Self.makeEntry(
                sessionID: "dock-\(dropCase.targetKind)-\(dropCase.placement)"
            )
            let launch = try #require(entry.resumeLaunch)
            let drag = try dropHarness.beginVaultDrag(
                entry: entry,
                sessionRegistry: fixture.appDelegate.sessionDragRegistry,
                tabDragTransferRegistry: fixture.appDelegate.tabDragTransferRegistry
            )
            defer { drag.finish() }
            let baselinePanelIDs = Set(dock.panels.keys)
            let baselinePaneCount = dock.bonsplitController.allPaneIds.count
            let request = try dropHarness.dropRequest(
                for: drag,
                placement: dropCase.placement,
                targetPane: targetPane
            )
            let dropHandler = try #require(dock.bonsplitController.onExternalTabDrop)
            let handled = dropHandler(request)

            #expect(handled)
            #expect(fixture.appDelegate.sessionDragRegistry.entry(id: drag.dragID) == nil)
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
            _ = try #require(fixture.workspace.newBrowserSurface(
                inPane: targetPane,
                url: URL(string: "about:blank"),
                focus: true,
                creationPolicy: .restoration,
                allowsExternalBrowserFallback: false
            ))
            let duplicate = Self.makeEntry(sessionID: "repeated-folder-duplicate")
            let rows = SessionIndexRowSnapshot.rows(for: [
                duplicate,
                duplicate,
                Self.makeEntry(sessionID: "repeated-folder-distinct"),
            ])
            #expect(Set(rows.map(\.id)).count == rows.count)

            for row in rows {
                let drag = try dropHarness.beginVaultDrag(
                    entry: row.entry,
                    sessionRegistry: fixture.appDelegate.sessionDragRegistry,
                    tabDragTransferRegistry: fixture.appDelegate.tabDragTransferRegistry
                )
                defer { drag.finish() }
                let baselinePanelIDs = Set(fixture.workspace.panels.keys)
                let request = try dropHarness.dropRequest(
                    for: drag,
                    placement: .center,
                    targetPane: targetPane
                )
                let dropHandler = try #require(
                    fixture.workspace.bonsplitController.onExternalTabDrop
                )
                #expect(dropHandler(request))
                #expect(
                    fixture.appDelegate.sessionDragRegistry.entry(id: drag.dragID) == nil
                )

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
