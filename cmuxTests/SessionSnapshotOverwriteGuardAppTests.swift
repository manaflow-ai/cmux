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

        #expect(app.snapshotAllowedByOverwriteGuard(trivial, removeWhenEmpty: false, now: launch) == nil)
        #expect(app.snapshotAllowedByOverwriteGuard(trivial, removeWhenEmpty: false, now: launch) == nil)

        _ = manager.addWorkspace(workingDirectory: "/tmp/cmux-guard-2")
        let changed = try #require(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
        #expect(changed.structureSignature != trivial.structureSignature)
        #expect(app.snapshotAllowedByOverwriteGuard(changed, removeWhenEmpty: false, now: launch) != nil)
        #expect(app.sessionSnapshotOverwriteGuard?.isMature == true)
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
        #expect(app.snapshotAllowedByOverwriteGuard(trivial, removeWhenEmpty: false, now: late) != nil)
    }
}
