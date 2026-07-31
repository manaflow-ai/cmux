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

        let directory = "/tmp/pro-workspace-customization"

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager(
            initialWorkingDirectory: directory,
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
