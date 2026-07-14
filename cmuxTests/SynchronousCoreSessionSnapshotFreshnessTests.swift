import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SynchronousCoreSessionSnapshotFreshnessTests {
    @Test
    func synchronousCoreSnapshotIgnoresSharedStaleTolerantAgentIndex() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer { AppDelegate.shared = previousAppDelegate }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let sharedIndex = SharedLiveAgentIndex.shared
        let previousResult = sharedIndex.latestCompletedLoadResult
        let previousCompletedAt = sharedIndex.latestCompletedAt
        defer {
            sharedIndex.latestCompletedLoadResult = previousResult
            sharedIndex.latestCompletedAt = previousCompletedAt
        }
        sharedIndex.latestCompletedLoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspace.id,
                panelId: panelId,
                sessionId: "stale-shared-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
        sharedIndex.latestCompletedAt = .now

        let snapshot = try #require(
            app.debugBuildSessionSnapshotForTesting(includeScrollback: false)
        )
        let terminal = try #require(
            snapshot.windows.first?.tabManager.workspaces.first?.panels
                .first(where: { $0.id == panelId })?
                .terminal
        )

        #expect(
            terminal.agent == nil,
            "A synchronous core snapshot must not enrich itself from a stale-tolerant shared cache."
        )
    }
}
