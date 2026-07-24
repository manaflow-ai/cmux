import CMUXAgentLaunch
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class PiFeedDockPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle = "Pi Feed Dock Test"
    let displayIcon: String? = "terminal.fill"
    var isDirty = false

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}

@MainActor
private extension DockSplitStore {
    @discardableResult
    func seedPiFeedPanel() throws -> PiFeedDockPanel {
        let panel = PiFeedDockPanel()
        let pane = try #require(bonsplitController.allPaneIds.first)
        panels[panel.id] = panel
        let tabID = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: panel.panelType.rawValue,
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        surfaceIdToPanelId[tabID] = panel.id
        return panel
    }
}

@Suite("Pi Feed Dock ownership", .serialized)
struct PiFeedDockOwnershipTests {
    @MainActor
    @Test("Acknowledged Feed follows a surface into its window Dock")
    func acknowledgedFeedRehomesStaleWorkspaceClaimToWindowDockOwner() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let dock = appDelegate.windowDock(forWindowId: windowID)
            let panel = try dock.seedPiFeedPanel()
            var insertedEvent: WorkstreamEvent?
            let store = WorkstreamStore(ringCapacity: 10) {
                insertedEvent = $0
                return nil
            }
            FeedCoordinator.shared.install(store: store)
            let event = WorkstreamEvent(
                sessionId: "pi-window-dock-feed",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: workspace.id.uuidString,
                surfaceId: panel.id.uuidString,
                requestId: "pi-window-dock-feed-request"
            )

            let result = await Self.ingestAcknowledgedOffMainActor([event])
            let payload = try Self.acknowledgmentPayload(result)

            #expect(payload["workspace_id"] as? String == windowID.uuidString)
            #expect(payload["surface_id"] as? String == panel.id.uuidString)
            #expect(insertedEvent?.workspaceId == windowID.uuidString)
            #expect(insertedEvent?.surfaceId == panel.id.uuidString)
            #expect(store.items.count == 1)
            #expect(appDelegate.tabManagerFor(windowId: windowID) === manager)
        }
    }

    @MainActor
    @Test("Acknowledged Feed follows a surface into its workspace Dock")
    func acknowledgedFeedRehomesStaleWorkspaceClaimToWorkspaceDockOwner() async throws {
        try await withAppContext { _, manager, workspace, _ in
            let staleWorkspace = manager.addWorkspace(select: false)
            let panel = try workspace.dockSplit.seedPiFeedPanel()
            var insertedEvent: WorkstreamEvent?
            let store = WorkstreamStore(ringCapacity: 10) {
                insertedEvent = $0
                return nil
            }
            FeedCoordinator.shared.install(store: store)
            let event = WorkstreamEvent(
                sessionId: "pi-workspace-dock-feed",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: staleWorkspace.id.uuidString,
                surfaceId: panel.id.uuidString,
                requestId: "pi-workspace-dock-feed-request"
            )

            let result = await Self.ingestAcknowledgedOffMainActor([event])
            let payload = try Self.acknowledgmentPayload(result)

            #expect(payload["workspace_id"] as? String == workspace.id.uuidString)
            #expect(payload["surface_id"] as? String == panel.id.uuidString)
            #expect(insertedEvent?.workspaceId == workspace.id.uuidString)
            #expect(insertedEvent?.surfaceId == panel.id.uuidString)
            #expect(store.items.count == 1)
        }
    }

    @MainActor
    @Test("Surface-less Feed accepts a live window Dock owner")
    func surfaceLessFeedAcceptsWindowDockOwner() async throws {
        try await withAppContext { appDelegate, _, _, windowID in
            _ = appDelegate.windowDock(forWindowId: windowID)
            var insertedEvent: WorkstreamEvent?
            let store = WorkstreamStore(ringCapacity: 10) {
                insertedEvent = $0
                return nil
            }
            FeedCoordinator.shared.install(store: store)
            let event = WorkstreamEvent(
                sessionId: "pi-window-dock-owner-feed",
                hookEventName: .postToolUse,
                source: "pi",
                workspaceId: "  \(windowID.uuidString) \n",
                requestId: "pi-window-dock-owner-feed-request"
            )

            let result = await Self.ingestAcknowledgedOffMainActor([event])
            let payload = try Self.acknowledgmentPayload(result)

            #expect(payload["workspace_id"] as? String == windowID.uuidString)
            #expect(payload["surface_id"] == nil)
            #expect(insertedEvent?.workspaceId == windowID.uuidString)
            #expect(insertedEvent?.surfaceId == nil)
            #expect(store.items.count == 1)
        }
    }

    @MainActor
    private func withAppContext(
        _ body: @MainActor (AppDelegate, TabManager, Workspace, UUID) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            appDelegate.didAttemptStartupSessionRestore = true
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            let workspace = manager.addWorkspace(select: true)
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
                appDelegate.tabManager = nil
                AppDelegate.shared = previousAppDelegate
            }

            try await body(appDelegate, manager, workspace, windowID)
        }
    }

    private static func acknowledgmentPayload(
        _ result: TerminalController.V2CallResult
    ) throws -> [String: Any] {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any] else {
            Issue.record("expected authoritative Pi Feed insertion, got \(result)")
            return [:]
        }
        return payload
    }

    private static func ingestAcknowledgedOffMainActor(
        _ events: [WorkstreamEvent]
    ) async -> TerminalController.V2CallResult {
        let resultBox = PiFeedV2CallResultBox()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                resultBox.value = TerminalController.shared.v2IngestAcknowledgedFeedEvents(events)
                continuation.resume()
            }
        }
        return resultBox.value!
    }
}
