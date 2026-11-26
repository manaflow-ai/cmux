import AppKit
import Combine
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceRecoveryReviewRegressionTests {
    @Test
    func generatedProWorkspaceKeepsGeneratedIdentity() throws {
        _ = NSApplication.shared
        let browserDefaults = UserDefaults.standard
        let previousBrowserDisabled = browserDefaults.object(
            forKey: BrowserAvailabilitySettings.disabledKey
        )
        BrowserAvailabilitySettings.setDisabled(false)
        defer {
            if let previousBrowserDisabled {
                browserDefaults.set(
                    previousBrowserDisabled,
                    forKey: BrowserAvailabilitySettings.disabledKey
                )
            } else {
                browserDefaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
                NotificationCenter.default.post(
                    name: BrowserAvailabilitySettings.didChangeNotification,
                    object: nil
                )
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager(
            initialWorkingDirectory: "/tmp/pro-workspace-customization",
            autoWelcomeIfNeeded: false
        )
        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }
        let pricingURL = try #require(URL(string: "https://cmux.com/app-pricing?cmux_app=1"))

        let proWorkspace = try #require(appDelegate.performProUpgradeWorkspaceAction(
            title: "cmux Pro",
            url: pricingURL,
            tabManager: manager
        ))

        #expect(proWorkspace.title == "cmux Pro")
        #expect(proWorkspace.customColor == nil)
    }

    @Test
    func sessionRestoreKeepsDistinctCustomizationForWorkspacesSharingADirectory() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let directory = "/tmp/shared-workspace-customization"
        let snapshots = try distinctWorkspaceSnapshots(in: directory)
        fixture.legacyStore.setCustomTitle("Directory Label", for: directory)
        fixture.legacyStore.setCustomColor("#ABCDEF", for: directory)

        let restoredManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceCustomizationStore: fixture.store
        )
        restoredManager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: snapshots
        ))

        let restoredByStableId = Dictionary(
            uniqueKeysWithValues: restoredManager.tabs.map { ($0.stableId, $0) }
        )
        let firstStableId = try #require(snapshots[0].stableId)
        let secondStableId = try #require(snapshots[1].stableId)
        let first = try #require(restoredByStableId[firstStableId])
        let second = try #require(restoredByStableId[secondStableId])
        #expect(first.customTitle == "First Workspace")
        #expect(first.customColor == "#112233")
        #expect(second.customTitle == "Second Workspace")
        #expect(second.customColor == "#445566")
    }

    @Test
    func closedWorkspaceRestoreKeepsDistinctCustomizationForWorkspacesSharingADirectory() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let directory = "/tmp/shared-closed-workspace-customization"
        let snapshots = try distinctWorkspaceSnapshots(in: directory)
        fixture.legacyStore.setCustomTitle("Directory Label", for: directory)
        fixture.legacyStore.setCustomColor("#ABCDEF", for: directory)
        let restoredManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceCustomizationStore: fixture.store
        )

        for (index, snapshot) in snapshots.enumerated() {
            #expect(restoredManager.restoreClosedWorkspace(ClosedWorkspaceHistoryEntry(
                workspaceId: try #require(snapshot.workspaceId),
                windowId: nil,
                workspaceIndex: index,
                snapshot: snapshot
            )))
        }

        let restoredByStableId = Dictionary(
            uniqueKeysWithValues: restoredManager.tabs.map { ($0.stableId, $0) }
        )
        let firstStableId = try #require(snapshots[0].stableId)
        let secondStableId = try #require(snapshots[1].stableId)
        let first = try #require(restoredByStableId[firstStableId])
        let second = try #require(restoredByStableId[secondStableId])
        #expect(first.customTitle == "First Workspace")
        #expect(first.customColor == "#112233")
        #expect(second.customTitle == "Second Workspace")
        #expect(second.customColor == "#445566")
    }

    @Test
    func loadTimeWorkspaceCapacityTrimIsPersisted() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-closed-workspace-trim-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let historyURL = temporaryDirectory.appending(path: "history.json")
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)

        let seedStore = ClosedItemHistoryStore(
            workspaceCapacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        for index in 0..<3 {
            seedStore.push(workspaceRecord(index: index, from: workspace))
        }

        let boundedStore = ClosedItemHistoryStore(
            workspaceCapacity: 2,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: false,
            persistsRecordsSynchronously: true
        )
        let loadedRevision = await boundedStore.$revision.values.first { $0 > 0 }
        #expect(loadedRevision != nil)
        #expect(boundedStore.menuSnapshot().totalItemCount == 2)

        let reloadedStore = ClosedItemHistoryStore(
            workspaceCapacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        #expect(reloadedStore.menuSnapshot().totalItemCount == 2)
        #expect(reloadedStore.menuSnapshot().items.map(\.title) == ["Closed 2", "Closed 1"])
    }

    private func makeCustomizationStore() throws -> (
        store: WorkspaceCustomizationStore,
        legacyStore: WorkspaceDirectoryCustomizationStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "WorkspaceCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let legacyStorageKey = "test.legacy-customizations"
        return (
            WorkspaceCustomizationStore(
                defaults: defaults,
                storageKey: "test.customizations",
                legacyStorageKey: legacyStorageKey
            ),
            WorkspaceDirectoryCustomizationStore(
                defaults: defaults,
                storageKey: legacyStorageKey
            ),
            defaults,
            suiteName
        )
    }

    private func distinctWorkspaceSnapshots(
        in directory: String
    ) throws -> [SessionWorkspaceSnapshot] {
        let manager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false
        )
        let first = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace(
            workingDirectory: directory,
            inheritWorkingDirectory: false,
            select: false,
            placementOverride: .end
        )
        #expect(manager.setCustomTitle(tabId: first.id, title: "First Workspace"))
        #expect(manager.setCustomTitle(tabId: second.id, title: "Second Workspace"))
        manager.setTabColor(tabId: first.id, color: "#112233")
        manager.setTabColor(tabId: second.id, color: "#445566")

        let snapshots = manager.sessionSnapshot(includeScrollback: false).workspaces
        #expect(snapshots.map(\.customTitle) == ["First Workspace", "Second Workspace"])
        #expect(snapshots.map(\.customColor) == ["#112233", "#445566"])
        return snapshots
    }

    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    private func workspaceRecord(
        index: Int,
        from workspace: Workspace
    ) -> ClosedItemHistoryRecord {
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.customTitle = "Closed \(index)"
        return ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: UUID(),
                windowId: nil,
                workspaceIndex: index,
                snapshot: snapshot
            ))
        )
    }
}
