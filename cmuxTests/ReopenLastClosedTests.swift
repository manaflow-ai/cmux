import AppKit
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
