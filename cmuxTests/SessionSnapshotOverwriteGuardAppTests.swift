import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Incident 2026-09-26: a relaunch that restored one empty workspace wrote it
/// over the full layout, and a second relaunch copied it over `-previous` too.
@Suite(.serialized)
struct SessionSnapshotOverwriteGuardAppTests {
    @MainActor
    @Test
    func poorerYoungLaunchDoesNotReachThePrimaryWriteUntilTheLayoutChanges() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager(initialWorkingDirectory: "/tmp/cmux-guard", autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let launch = Date()
        app.sessionSnapshotOverwriteGuard = SessionSnapshotOverwriteGuard(
            baseline: SessionSnapshotRichness(workspaces: 6, panels: 12),
            launchDate: launch
        )
        let trivial = try #require(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
        #expect(trivial.richness < SessionSnapshotRichness(workspaces: 6, panels: 12))

        #expect(app.snapshotAllowedByOverwriteGuard(trivial, now: launch) == nil)
        #expect(app.snapshotAllowedByOverwriteGuard(trivial, now: launch) == nil)

        _ = manager.addWorkspace(workingDirectory: "/tmp/cmux-guard-2")
        let changed = try #require(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
        #expect(changed.structureSignature != trivial.structureSignature)
        #expect(app.snapshotAllowedByOverwriteGuard(changed, now: launch) != nil)
        #expect(app.sessionSnapshotOverwriteGuard?.isMature == true)
    }

    @MainActor
    @Test
    func startingAnAgentInTheHeldLayoutCountsAsAChange() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager(initialWorkingDirectory: "/tmp/cmux-guard-agent", autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let launch = Date()
        app.sessionSnapshotOverwriteGuard = SessionSnapshotOverwriteGuard(
            baseline: SessionSnapshotRichness(workspaces: 6, panels: 12),
            launchDate: launch
        )
        let idle = try #require(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
        #expect(app.snapshotAllowedByOverwriteGuard(idle, now: launch) == nil)

        var withAgent = idle
        let panelIndex = try #require(
            withAgent.windows[0].tabManager.workspaces[0].panels.firstIndex { $0.terminal != nil }
        )
        withAgent.windows[0].tabManager.workspaces[0].panels[panelIndex].terminal?.agent =
            SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "11111111-2222-3333-4444-555555555555",
                workingDirectory: "/tmp/cmux-guard-agent",
                launchCommand: nil
            )
        #expect(withAgent.richness == idle.richness)
        #expect(app.snapshotAllowedByOverwriteGuard(withAgent, now: launch) != nil)
    }

    @MainActor
    @Test
    func sessionOlderThanTheMaturityIntervalWritesEvenWhenPoorer() throws {
        let app = AppDelegate()
        let launch = Date(timeIntervalSince1970: 1_000)
        app.sessionSnapshotOverwriteGuard = SessionSnapshotOverwriteGuard(
            baseline: SessionSnapshotRichness(workspaces: 6, panels: 12),
            launchDate: launch
        )
        let trivial = AppSessionSnapshot(version: SessionSnapshotSchema.currentVersion, createdAt: 0, windows: [])
        let late = launch.addingTimeInterval(SessionSnapshotOverwriteGuard.defaultMaturityInterval)
        #expect(app.snapshotAllowedByOverwriteGuard(trivial, now: late) != nil)
    }
}
