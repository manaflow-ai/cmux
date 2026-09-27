import AppKit
import CmuxNotifications
import CmuxUpdater
import Observation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar snapshot ownership", .serialized)
struct SidebarSnapshotOwnerTests {
    @Test func eventBatchesPublishOneRevisionAndProjectionDoesNotPublish() {
        let cache = SidebarRowSnapshotCache()
        let ids = Set((0..<100).map { _ in UUID() })
        let snapshot = SidebarWorkspaceRowSuspensionTests.makeModel().snapshot
        cache.replace(with: Dictionary(uniqueKeysWithValues: ids.map { ($0, snapshot) }))
        let initialRevision = cache.revision
        for id in ids { _ = cache.value(for: id) }
        #expect(cache.revision == initialRevision)
        let changed = SidebarWorkspaceRowSuspensionTests.makeModel(customDescription: "Changed").snapshot
        cache.refresh(workspaceIds: ids) { _ in changed }
        #expect(cache.revision == initialRevision + 1)
        cache.refresh(workspaceIds: ids) { _ in changed }
        #expect(cache.revision == initialRevision + 1)
        cache.prune(keeping: [])
        #expect(cache.revision == initialRevision + 1)
        #expect(cache.snapshotsById.isEmpty)
    }

    @Test func membershipReconciliationBuildsOnlyNewWorkspaceSnapshots() throws {
        let cache = SidebarRowSnapshotCache()
        let snapshot = SidebarWorkspaceRowSuspensionTests.makeModel().snapshot
        let ids = Set((0..<100).map { _ in UUID() })
        cache.reconcile(workspaceIds: ids, presentationKey: snapshot.presentationKey) { _ in snapshot }
        let retired = try #require(ids.first)
        let replacement = UUID()
        let nextIds = ids.subtracting([retired]).union([replacement])
        var requested: Set<UUID> = []
        cache.reconcile(workspaceIds: nextIds, presentationKey: snapshot.presentationKey) { id in
            requested.insert(id)
            return snapshot
        }
        #expect(requested == [replacement])
        #expect(cache.value(for: retired) == nil)
        #expect(Set(cache.snapshotsById.keys) == nextIds)
        let revision = cache.revision
        cache.reconcile(workspaceIds: nextIds, presentationKey: snapshot.presentationKey) { _ in
            Issue.record("Unchanged membership must reuse its presentation snapshots")
            return snapshot
        }
        #expect(cache.revision == revision)
    }

    @Test(arguments: [true, false])
    func mountedSidebarUsesOneOwnerAcrossUpdatesAndWorkspaceRemoval(appKit: Bool) async throws {
        _ = NSApplication.shared
        let suiteName = "SidebarSnapshotOwnerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(CmuxExtensionSidebarSelection.defaultProviderId, forKey: CmuxExtensionSidebarSelection.defaultsKey)
        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })
        flags.setOverride(appKit, for: CmuxFeatureFlags.appKitSidebarListFlag)
        let cache = SidebarRowSnapshotCache()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let initialCoalescing = WindowTerminalPortal.usesCoalescedAnchorFailsafe
        defer { WindowTerminalPortal.usesCoalescedAnchorFailsafe = initialCoalescing }
        let root = VerticalTabsSidebar(
            updateViewModel: UpdateStateModel(),
            fileExplorerState: FileExplorerState(),
            featureFlags: flags,
            sidebarUnread: SidebarUnreadModel(),
            titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
            windowId: UUID(),
            onSendFeedback: {}, onToggleSidebar: {}, onNewTab: {},
            observedWindowReference: WeakWindowReference(),
            chromeBackgroundColor: .black,
            selection: .constant(.tabs),
            selectedTabIds: .constant([]),
            lastSidebarSelectionIndex: .constant(nil),
            sidebarRenderWorkerClient: .constant(nil),
            workspaceSnapshotCache: cache
        )
        .environmentObject(manager)
        .environmentObject(CmuxConfigStore())
        .environmentObject(TerminalNotificationStore.shared)
        .environmentObject(SidebarState())
        .environmentObject(SidebarSelectionState())
        .defaultAppStorage(defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        defer { window.contentView = nil; window.close() }
        #expect(await converge(window) { Set(cache.snapshotsById.keys) == Set(manager.tabs.map(\.id)) })
        for cycle in 0..<5 {
            let workspace = manager.addWorkspace(
                initialSurface: .cloudVMLoading, select: false,
                autoWelcomeIfNeeded: false, autoRefreshMetadata: false
            )
            #expect(await converge(window) { cache.value(for: workspace.id) != nil })
            workspace.setCustomTitle("Updated \(cycle)")
            // Membership reconciliation must preserve an already queued title update.
            let sibling = manager.addWorkspace(
                initialSurface: .cloudVMLoading, select: false,
                autoWelcomeIfNeeded: false, autoRefreshMetadata: false
            )
            #expect(await converge(window) { cache.value(for: workspace.id)?.title == "Updated \(cycle)" })
            manager.closeWorkspace(sibling, recordHistory: false)
            manager.closeWorkspace(workspace, recordHistory: false)
            #expect(await converge(window) { cache.value(for: workspace.id) == nil })
            #expect(Set(cache.snapshotsById.keys) == Set(manager.tabs.map(\.id)))
        }
        print("SIDEBAR_SNAPSHOT_LIFETIME renderer=\(appKit ? "appkit" : "swiftui") cycles=5 retained=\(cache.snapshotsById.count) live=\(manager.tabs.count)")
    }

    private func converge(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
            if condition() { return true }
        } while .now < deadline
        return false
    }
}
