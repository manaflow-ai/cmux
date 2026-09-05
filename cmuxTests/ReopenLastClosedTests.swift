import AppKit
import Combine
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias AppStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias AppStoredShortcut = cmux.StoredShortcut
#endif

@MainActor
@Suite("Reopen last closed", .serialized)
struct ReopenLastClosedTests {
    private enum RestoredKind: Equatable {
        case panel
        case window
    }

    /// The production default bounds closed panels without touching user history in this test.
    /// https://github.com/manaflow-ai/cmux/issues/10352
    @Test
    func defaultCapacityBoundsClosedPanelHistoryAndKeepsNewestRecords() throws {
        let store = ClosedItemHistoryStore(
            capacity: ClosedItemHistoryStore.defaultTotalCapacity,
            loadPersisted: false
        )

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let baseSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first
        )
        let expectedCapacity = ClosedItemHistoryStore.defaultTotalCapacity

        for index in 0...expectedCapacity {
            var snapshot = baseSnapshot
            snapshot.customTitle = "Closed \(index)"
            store.push(ClosedItemHistoryRecord(
                closedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                entry: .panel(ClosedPanelHistoryEntry(
                    workspaceId: workspace.id,
                    paneId: UUID(),
                    tabIndex: 0,
                    snapshot: snapshot
                ))
            ))
        }

        let menuSnapshot = store.menuSnapshot()
        #expect(menuSnapshot.totalItemCount == expectedCapacity)
        #expect(menuSnapshot.items.first?.title == "Closed \(expectedCapacity)")
        #expect(menuSnapshot.items.last?.title == "Closed 1")
        #expect(!menuSnapshot.items.contains { $0.title == "Closed 0" })
    }

    /// A synchronous load trims by close time and rewrites the bounded file.
    @Test
    func loadTimeTotalCapacityTrimKeepsNewestRecordsAndPersistsTrim() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-panel-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let historyURL = temporaryDirectory.appendingPathComponent("history.json")
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first
        )
        let seedStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )

        seedStore.push(panelRecord(
            title: "Newest",
            closedAt: 30,
            workspace: workspace,
            snapshot: panelSnapshot
        ))
        seedStore.push(panelRecord(
            title: "Oldest",
            closedAt: 10,
            workspace: workspace,
            snapshot: panelSnapshot
        ))
        seedStore.push(panelRecord(
            title: "Middle",
            closedAt: 20,
            workspace: workspace,
            snapshot: panelSnapshot
        ))

        let boundedStore = ClosedItemHistoryStore(
            capacity: 2,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        #expect(boundedStore.menuSnapshot().totalItemCount == 2)
        #expect(boundedStore.menuSnapshot().items.map(\.title) == ["Newest", "Middle"])

        let reloadedStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        #expect(reloadedStore.menuSnapshot().totalItemCount == 2)
        #expect(reloadedStore.menuSnapshot().items.map(\.title) == ["Newest", "Middle"])
    }

    /// The production async loader must hand only bounded history to the main-actor store.
    @Test(.timeLimit(.minutes(1)))
    func asyncLoadTrimsLegacyHistoryBeforeItReachesTheStore() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-panel-async-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let historyURL = temporaryDirectory.appendingPathComponent("history.json")
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first
        )
        let seedStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        seedStore.push(panelRecord(
            title: "Newest",
            closedAt: 30,
            workspace: workspace,
            snapshot: panelSnapshot
        ))
        seedStore.push(panelRecord(
            title: "Oldest",
            closedAt: 10,
            workspace: workspace,
            snapshot: panelSnapshot
        ))
        seedStore.push(panelRecord(
            title: "Middle",
            closedAt: 20,
            workspace: workspace,
            snapshot: panelSnapshot
        ))

        let boundedStore = ClosedItemHistoryStore(
            capacity: 2,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: false,
            persistsRecordsSynchronously: true
        )
        for await _ in boundedStore.$revision.values {
            if boundedStore.menuSnapshot().totalItemCount == 2 {
                break
            }
        }
        #expect(boundedStore.menuSnapshot().items.map(\.title) == ["Newest", "Middle"])
        boundedStore.flushPendingSaves()

        let reloadedStore = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        #expect(reloadedStore.menuSnapshot().items.map(\.title) == ["Newest", "Middle"])
    }

    /// The workspace-specific sub-cap still retains the newest workspace entries.
    @Test
    func workspaceCapacityStillKeepsNewestWorkspaceRecords() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        let store = ClosedItemHistoryStore(
            workspaceCapacity: 2,
            loadPersisted: false
        )

        for index in [1, 2, 0] {
            var snapshot = workspaceSnapshot
            snapshot.customTitle = "Workspace \(index)"
            store.push(ClosedItemHistoryRecord(
                closedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                entry: .workspace(ClosedWorkspaceHistoryEntry(
                    workspaceId: UUID(),
                    windowId: nil,
                    workspaceIndex: index,
                    snapshot: snapshot
                ))
            ))
        }

        #expect(store.menuSnapshot().items.map(\.title) == ["Workspace 2", "Workspace 1"])
    }

    /// Bounded selection must match the stable full-sort definition across legacy-scale input.
    @Test
    func totalCapacityHeapMatchesStableRecencyReference() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first
        )
        let recordCount = 2_048
        let capacity = 137
        let records = (0..<recordCount).map { index in
            ClosedItemHistoryRecord(
                closedAt: Date(timeIntervalSince1970: TimeInterval((index * 37) % 251)),
                entry: .panel(ClosedPanelHistoryEntry(
                    workspaceId: workspace.id,
                    paneId: UUID(),
                    tabIndex: 0,
                    snapshot: panelSnapshot
                ))
            )
        }
        let expectedIds = records.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.closedAt != rhs.element.closedAt {
                    return lhs.element.closedAt < rhs.element.closedAt
                }
                return lhs.offset < rhs.offset
            }
            .suffix(capacity)
            .map(\.element.id)

        let trimmed = ClosedItemHistoryCapacityPolicy(
            totalCapacity: capacity,
            workspaceCapacity: nil
        ).trimming(records)

        #expect(trimmed.map(\.id) == expectedIds)
    }

    /// Duplicate persisted IDs must not let either capacity bound retain extra records.
    @Test
    func capacityTrimmingUsesPositionsWhenRecordIDsAreDuplicated() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(workspaceSnapshot.panels.first)
        let duplicateID = UUID()
        let panelRecords = [1, 2].map { index in
            ClosedItemHistoryRecord(
                id: duplicateID,
                closedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                entry: .panel(ClosedPanelHistoryEntry(
                    workspaceId: workspace.id,
                    paneId: UUID(),
                    tabIndex: 0,
                    snapshot: panelSnapshot
                ))
            )
        }
        let panelTrimmed = ClosedItemHistoryCapacityPolicy(
            totalCapacity: 1,
            workspaceCapacity: nil
        ).trimming(panelRecords)
        #expect(panelTrimmed.count == 1)
        #expect(panelTrimmed.first?.closedAt == Date(timeIntervalSince1970: 2))

        let workspaceRecords = [1, 2].map { index in
            ClosedItemHistoryRecord(
                id: duplicateID,
                closedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                entry: .workspace(ClosedWorkspaceHistoryEntry(
                    workspaceId: UUID(),
                    windowId: nil,
                    workspaceIndex: index,
                    snapshot: workspaceSnapshot
                ))
            )
        }
        let workspaceTrimmed = ClosedItemHistoryCapacityPolicy(
            totalCapacity: nil,
            workspaceCapacity: 1
        ).trimming(workspaceRecords)
        #expect(workspaceTrimmed.count == 1)
        #expect(workspaceTrimmed.first?.closedAt == Date(timeIntervalSince1970: 2))
    }

    /// Reinsertion protects the exact position even when malformed history repeats its ID.
    @Test
    func protectedInsertionUsesItsPositionWhenRecordIDsAreDuplicated() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(workspaceSnapshot.panels.first)
        let duplicateID = UUID()

        let totalStore = ClosedItemHistoryStore(capacity: 2, loadPersisted: false)
        totalStore.push(panelRecord(
            id: duplicateID,
            title: "Existing Duplicate",
            closedAt: 2,
            workspace: workspace,
            snapshot: panelSnapshot
        ))
        totalStore.push(panelRecord(
            title: "Newest",
            closedAt: 3,
            workspace: workspace,
            snapshot: panelSnapshot
        ))
        totalStore.insert(panelRecord(
            id: duplicateID,
            title: "Protected Insertion",
            closedAt: 1,
            workspace: workspace,
            snapshot: panelSnapshot
        ), at: 2)
        #expect(totalStore.menuSnapshot().items.map(\.title) == ["Newest", "Protected Insertion"])

        let workspaceStore = ClosedItemHistoryStore(
            workspaceCapacity: 2,
            loadPersisted: false
        )
        workspaceStore.push(workspaceRecord(
            id: duplicateID,
            title: "Existing Workspace Duplicate",
            closedAt: 2,
            workspaceIndex: 0,
            snapshot: workspaceSnapshot
        ))
        workspaceStore.push(workspaceRecord(
            title: "Newest Workspace",
            closedAt: 3,
            workspaceIndex: 1,
            snapshot: workspaceSnapshot
        ))
        workspaceStore.insert(workspaceRecord(
            id: duplicateID,
            title: "Protected Workspace Insertion",
            closedAt: 1,
            workspaceIndex: 2,
            snapshot: workspaceSnapshot
        ), at: 2)
        #expect(workspaceStore.menuSnapshot().items.map(\.title) == [
            "Newest Workspace",
            "Protected Workspace Insertion",
        ])
    }

    /// Restoring a later duplicate ID removes the selected record, not the earlier duplicate.
    @Test
    func restoringDuplicateIDsRemovesTheSelectedRecordPosition() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first
        )
        let duplicateID = UUID()
        let store = ClosedItemHistoryStore(capacity: 10, loadPersisted: false)
        store.push(panelRecord(
            id: duplicateID,
            title: "Older Duplicate",
            closedAt: 1,
            workspace: workspace,
            snapshot: panelSnapshot
        ))
        store.push(panelRecord(
            id: duplicateID,
            title: "Newer Duplicate",
            closedAt: 2,
            workspace: workspace,
            snapshot: panelSnapshot
        ))

        var restoredTitle: String?
        #expect(store.restoreFirstRestorable { entry in
            guard case .panel(let panelEntry) = entry else { return false }
            restoredTitle = panelEntry.snapshot.customTitle
            return true
        })
        #expect(restoredTitle == "Newer Duplicate")
        #expect(store.menuSnapshot().items.map(\.title) == ["Older Duplicate"])
    }

    /// Builds a panel history fixture with a deterministic close timestamp.
    private func panelRecord(
        id: UUID = UUID(),
        title: String,
        closedAt: TimeInterval,
        workspace: Workspace,
        snapshot: SessionPanelSnapshot
    ) -> ClosedItemHistoryRecord {
        var snapshot = snapshot
        snapshot.customTitle = title
        return ClosedItemHistoryRecord(
            id: id,
            closedAt: Date(timeIntervalSince1970: closedAt),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: snapshot
            ))
        )
    }

    /// Builds a workspace history fixture with a deterministic close timestamp.
    private func workspaceRecord(
        id: UUID = UUID(),
        title: String,
        closedAt: TimeInterval,
        workspaceIndex: Int,
        snapshot: SessionWorkspaceSnapshot
    ) -> ClosedItemHistoryRecord {
        var snapshot = snapshot
        snapshot.customTitle = title
        return ClosedItemHistoryRecord(
            id: id,
            closedAt: Date(timeIntervalSince1970: closedAt),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: UUID(),
                windowId: nil,
                workspaceIndex: workspaceIndex,
                snapshot: snapshot
            ))
        )
    }

    @Test
    func mixedHistoryRestoresNewestOnceAndPreservesWindowGeometry() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first
        )
        let windowFrame = SessionRectSnapshot(
            x: 120,
            y: 180,
            width: 960,
            height: 640
        )
        let windowSnapshot = SessionWindowSnapshot(
            frame: windowFrame,
            display: nil,
            tabManager: manager.sessionSnapshot(includeScrollback: false),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            )
        )
        let store = ClosedItemHistoryStore(capacity: 10, loadPersisted: false)
        store.push(ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: panelSnapshot
            ))
        ))
        store.push(ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 2),
            entry: .window(ClosedWindowHistoryEntry(snapshot: windowSnapshot))
        ))

        var restoredKinds: [RestoredKind] = []
        var restoredWindowFrame: SessionRectSnapshot?
        #expect(store.restoreFirstRestorable { entry in
            switch entry {
            case .panel:
                restoredKinds.append(.panel)
            case .window(let window):
                restoredKinds.append(.window)
                restoredWindowFrame = window.snapshot.frame
            case .workspace:
                Issue.record("Unexpected workspace entry")
                return false
            }
            return true
        })

        #expect(restoredKinds == [.window])
        #expect(restoredWindowFrame == windowFrame)
        #expect(store.menuSnapshot().totalItemCount == 1)

        #expect(store.restoreFirstRestorable { entry in
            guard case .panel = entry else {
                Issue.record("Expected the older panel entry")
                return false
            }
            restoredKinds.append(.panel)
            return true
        })
        #expect(restoredKinds == [.window, .panel])
        #expect(!store.restoreFirstRestorable { _ in true })
    }

    #if DEBUG
    @Test
    func commandShiftTRestoresClosedWindowsInLIFOOrder() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let shortcutActions: [KeyboardShortcutSettings.Action] = [
            .reopenClosedWorkspace,
            .reopenClosedBrowserPanel,
        ]
        let savedShortcutData = Dictionary(
            uniqueKeysWithValues: shortcutActions.map {
                ($0, UserDefaults.standard.data(forKey: $0.defaultsKey))
            }
        )
        let originalFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "reopen-last-closed"
        )
        let baselineWindowIds = mainWindowIds(appDelegate: appDelegate)
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            for windowId in mainWindowIds(appDelegate: appDelegate).subtracting(baselineWindowIds) {
                appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId)
            }
            ClosedItemHistoryStore.shared.removeAll()
            KeyboardShortcutSettings.settingsFileStore = originalFileStore
            for action in shortcutActions {
                if let data = savedShortcutData[action] ?? nil {
                    UserDefaults.standard.set(data, forKey: action.defaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: action.defaultsKey)
                }
            }
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }
        for action in shortcutActions {
            KeyboardShortcutSettings.resetShortcut(for: action)
        }
        appDelegate.debugResetShortcutRoutingStateForTesting()

        let olderWindowId = appDelegate.createMainWindow(shouldActivate: false)
        let newerWindowId = appDelegate.createMainWindow(shouldActivate: false)
        let olderWindow = try #require(appDelegate.mainWindow(for: olderWindowId))
        let newerWindow = try #require(appDelegate.mainWindow(for: newerWindowId))
        let olderManager = try #require(appDelegate.tabManagerFor(windowId: olderWindowId))
        let newerManager = try #require(appDelegate.tabManagerFor(windowId: newerWindowId))
        try #require(olderManager.selectedWorkspace).setCustomTitle("Older Window Workspace")
        try #require(newerManager.selectedWorkspace).setCustomTitle("Newest Window Workspace")
        _ = newerManager.addWorkspace(
            title: "Newest Window Second Workspace",
            select: false,
            autoWelcomeIfNeeded: false
        )

        let visibleFrame = try #require((newerWindow.screen ?? NSScreen.main)?.visibleFrame)
        let olderFrame = fittedTestFrame(in: visibleFrame, xOffset: 48, yOffset: 56)
        let newerFrame = fittedTestFrame(in: visibleFrame, xOffset: 136, yOffset: 104)
        olderWindow.setFrame(olderFrame, display: false)
        newerWindow.setFrame(newerFrame, display: false)
        olderWindow.animationBehavior = .none
        newerWindow.animationBehavior = .none

        olderWindow.performClose(nil)
        #expect(waitUntil {
            !mainWindowIds(appDelegate: appDelegate).contains(olderWindowId)
        })
        #expect(appDelegate.closeMainWindow(windowId: newerWindowId))
        #expect(waitUntil {
            !mainWindowIds(appDelegate: appDelegate).contains(newerWindowId)
        })
        #expect(ClosedItemHistoryStore.shared.menuSnapshot().totalItemCount == 2)

        try pressCommandShiftT(appDelegate: appDelegate)
        #expect(waitUntil {
            mainWindowIds(appDelegate: appDelegate).subtracting(baselineWindowIds).count == 1
        })
        let newestRestoredId = try #require(
            mainWindowIds(appDelegate: appDelegate).subtracting(baselineWindowIds).first { windowId in
                appDelegate.tabManagerFor(windowId: windowId)?.tabs.contains {
                    $0.customTitle == "Newest Window Workspace"
                } == true
            }
        )
        let newestRestoredManager = try #require(
            appDelegate.tabManagerFor(windowId: newestRestoredId)
        )
        #expect(newestRestoredManager.tabs.map(\.customTitle) == [
            "Newest Window Workspace",
            "Newest Window Second Workspace",
        ])
        assertFrame(
            try #require(appDelegate.mainWindow(for: newestRestoredId)).frame,
            equals: newerFrame
        )

        try pressCommandShiftT(appDelegate: appDelegate)
        #expect(waitUntil {
            mainWindowIds(appDelegate: appDelegate).subtracting(baselineWindowIds).count == 2
        })
        let olderRestoredId = try #require(
            mainWindowIds(appDelegate: appDelegate).subtracting(baselineWindowIds).first { windowId in
                appDelegate.tabManagerFor(windowId: windowId)?.tabs.contains {
                    $0.customTitle == "Older Window Workspace"
                } == true
            }
        )
        assertFrame(
            try #require(appDelegate.mainWindow(for: olderRestoredId)).frame,
            equals: olderFrame
        )
        #expect(!ClosedItemHistoryStore.shared.canReopen)
    }
    #endif

    @Test
    func reopenLastClosedShortcutIsCustomizableAndMappedToThePaletteCommand() throws {
        let expected = AppStoredShortcut(
            key: "t",
            command: true,
            shift: true,
            option: false,
            control: false
        )
        #expect(
            KeyboardShortcutSettings.Action.reopenClosedBrowserPanel.defaultShortcut == expected
        )
        #expect(
            KeyboardShortcutSettings.settingsVisibleActions.contains(.reopenClosedBrowserPanel)
        )
        let settingsAction = try #require(
            ShortcutAction(
                rawValue: KeyboardShortcutSettings.Action.reopenClosedBrowserPanel.rawValue
            )
        )
        #expect(
            settingsAction.defaultStroke ==
                CmuxSettings.ShortcutStroke(key: "t", command: true, shift: true)
        )
        #expect(settingsAction.group == .navigation)
        #expect(
            settingsAction.displayName ==
                KeyboardShortcutSettings.Action.reopenClosedBrowserPanel.label
        )
        #expect(ShortcutAction.settingsVisibleActions.contains(settingsAction))
        #expect(ShortcutAction.reopenClosedWorkspace.defaultStroke == nil)
        #expect(KeyboardShortcutSettings.Action.reopenClosedWorkspace.defaultShortcut.isUnbound)
        #expect(
            ContentView.commandPaletteShortcutAction(
                forCommandID: "palette.reopenClosedBrowserTab"
            ) == .reopenClosedBrowserPanel
        )
    }

    #if DEBUG
    private func pressCommandShiftT(appDelegate: AppDelegate) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        ))
        #expect(appDelegate.debugHandleCustomShortcut(event: event))
    }

    private func fittedTestFrame(
        in visibleFrame: NSRect,
        xOffset: Double,
        yOffset: Double
    ) -> NSRect {
        let width = min(720, max(460, visibleFrame.width - 180))
        let height = min(500, max(360, visibleFrame.height - 180))
        return NSRect(
            x: min(visibleFrame.minX + xOffset, visibleFrame.maxX - width),
            y: max(visibleFrame.minY, visibleFrame.maxY - height - yOffset),
            width: width,
            height: height
        )
    }

    private func assertFrame(
        _ actual: NSRect,
        equals expected: NSRect,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual.minX - expected.minX) <= 1, sourceLocation: sourceLocation)
        #expect(abs(actual.minY - expected.minY) <= 1, sourceLocation: sourceLocation)
        #expect(abs(actual.width - expected.width) <= 1, sourceLocation: sourceLocation)
        #expect(abs(actual.height - expected.height) <= 1, sourceLocation: sourceLocation)
    }

    private func mainWindowIds(appDelegate: AppDelegate) -> Set<UUID> {
        Set(appDelegate.mainWindowContexts.values.map(\.windowId))
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 1)
        while !condition(), Date.now < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }
    #endif
}
