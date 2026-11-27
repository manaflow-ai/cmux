import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension PiFeedOwnershipTests {
    @MainActor
    @Test
    func acknowledgedLegacyEventPreservesStaleWorkspaceMetadata() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        appDelegate.didAttemptStartupSessionRestore = true
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager
        let liveWorkspace = tabManager.addWorkspace(select: true)
        defer {
            if tabManager.tabs.contains(where: { $0.id == liveWorkspace.id }) {
                tabManager.closeWorkspace(liveWorkspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
            CmuxEventBus.shared.resetForTesting()
        }

        let staleWorkspaceId = UUID().uuidString
        let store = WorkstreamStore(ringCapacity: 10)
        FeedCoordinator.shared.install(store: store)
        CmuxEventBus.shared.resetForTesting()
        let event = WorkstreamEvent(
            sessionId: "codex-legacy-stale-workspace",
            hookEventName: .postToolUse,
            source: "codex",
            workspaceId: staleWorkspaceId,
            surfaceId: nil,
            toolName: "Bash",
            requestId: "codex-legacy-stale-workspace-request"
        )

        guard case .ok = await Self.ingestAcknowledgedOffMainActor([event]) else {
            Issue.record("legacy non-Pi Feed event with stale ambient metadata was rejected")
            return
        }
        let receivedPayload = try #require(Self.receivedFeedEventPayloads().first)
        #expect(store.items.count == 1)
        #expect(receivedPayload["workspace_id"] as? String == staleWorkspaceId)
        #expect(receivedPayload["surface_id"] is NSNull)
    }

    @MainActor
    @Test
    func acknowledgedBatchRejectsMixedPiAndLegacySources() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let surfaceId = try #require(workspace.focusedPanelId)
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let store = WorkstreamStore(ringCapacity: 10)
        FeedCoordinator.shared.install(store: store)
        let events = ["pi", "codex"].map { source in
            WorkstreamEvent(
                sessionId: "mixed-source-\(source)",
                hookEventName: .postToolUse,
                source: source,
                workspaceId: workspace.id.uuidString,
                surfaceId: surfaceId.uuidString,
                toolName: "Bash",
                requestId: "mixed-source-\(source)-request"
            )
        }

        guard case .err(let code, _, _) = await Self.ingestAcknowledgedOffMainActor(events) else {
            Issue.record("mixed authoritative Pi and legacy Feed batch was acknowledged")
            return
        }
        #expect(code == "not_found")
        #expect(store.items.isEmpty)
    }
}
