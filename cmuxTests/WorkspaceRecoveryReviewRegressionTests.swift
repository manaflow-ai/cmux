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
    func generatedProWorkspaceDoesNotOverwriteStickyProjectIdentity() throws {
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

        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let directory = "/tmp/pro-workspace-customization"
        fixture.store.setCustomTitle("Project Label", for: directory)
        fixture.store.setCustomColor("#123456", for: directory)

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: fixture.store
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
        #expect(proWorkspace.customizationDirectory == nil)
        #expect(proWorkspace.customColor == nil)
        #expect(
            fixture.store.customization(for: directory) ==
                WorkspaceDirectoryCustomization(
                    customTitle: "Project Label",
                    customColor: "#123456"
                )
        )
    }

    @Test
    func legacyLocalSnapshotInfersItsStickyCustomizationRoot() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let directory = "/tmp/legacy-sticky-project"
        fixture.store.setCustomTitle("Current Label", for: directory)
        fixture.store.setCustomColor("#778899", for: directory)

        let sourceManager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false
        )
        let sourceWorkspace = try #require(sourceManager.selectedWorkspace)
        sourceWorkspace.setCustomTitle("Legacy Snapshot Label")
        sourceWorkspace.setCustomColor("#111111")
        var snapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        snapshot.workspaces[0].customizationDirectory = nil
        snapshot.workspaces[0].usesWorkspaceDirectoryCustomization = nil

        let restoredManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: fixture.store
        )
        restoredManager.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try #require(restoredManager.selectedWorkspace)
        #expect(restoredWorkspace.customTitle == "Current Label")
        #expect(restoredWorkspace.customColor == "#778899")
        #expect(
            restoredWorkspace.customizationDirectory ==
                fixture.store.directoryKey(for: directory)
        )
    }

    @Test
    func explicitlyIneligibleSnapshotDoesNotAdoptStickyProjectIdentity() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let directory = "/tmp/ineligible-sticky-project"
        fixture.store.setCustomTitle("Project Label", for: directory)

        let sourceManager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false
        )
        let sourceWorkspace = try #require(sourceManager.selectedWorkspace)
        sourceWorkspace.setCustomTitle("Generated Workspace")
        var snapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        snapshot.workspaces[0].customizationDirectory = nil
        snapshot.workspaces[0].usesWorkspaceDirectoryCustomization = false

        let restoredManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: fixture.store
        )
        restoredManager.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try #require(restoredManager.selectedWorkspace)
        #expect(restoredWorkspace.customTitle == "Generated Workspace")
        #expect(restoredWorkspace.customizationDirectory == nil)
        #expect(restoredManager.setCustomTitle(
            tabId: restoredWorkspace.id,
            title: "Later Generated Rename"
        ))
        #expect(fixture.store.customization(for: directory)?.customTitle == "Project Label")
    }

    @Test
    func legacyGeneratedSnapshotCannotSeedStickyProjectIdentity() throws {
        let fixture = try makeCustomizationStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let directory = "/tmp/legacy-generated-workspace"

        let sourceManager = TabManager(
            initialWorkingDirectory: directory,
            autoWelcomeIfNeeded: false
        )
        let sourceWorkspace = try #require(sourceManager.selectedWorkspace)
        sourceWorkspace.setCustomTitle("cmux Pro")
        sourceWorkspace.setCustomColor("#111111")
        var snapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        snapshot.workspaces[0].customizationDirectory = nil
        snapshot.workspaces[0].usesWorkspaceDirectoryCustomization = nil

        let restoredManager = TabManager(
            autoWelcomeIfNeeded: false,
            workspaceDirectoryCustomizationStore: fixture.store
        )
        restoredManager.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try #require(restoredManager.selectedWorkspace)
        #expect(restoredWorkspace.customTitle == "cmux Pro")
        #expect(restoredWorkspace.customizationDirectory == nil)
        #expect(fixture.store.customization(for: directory) == nil)
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
        store: WorkspaceDirectoryCustomizationStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "WorkspaceDirectoryCustomizationStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (
            WorkspaceDirectoryCustomizationStore(
                defaults: defaults,
                storageKey: "test.customizations"
            ),
            defaults,
            suiteName
        )
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
