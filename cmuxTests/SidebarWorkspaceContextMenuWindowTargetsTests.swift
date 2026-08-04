import AppKit
import CmuxNotifications
import CmuxUpdater
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SidebarWorkspaceContextMenuWindowTargetsTests {
    private final class FocusedWorkspaceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedIds: [UUID] = []

        func record(_ id: UUID) {
            lock.lock()
            recordedIds.append(id)
            lock.unlock()
        }

        var ids: [UUID] {
            lock.lock()
            defer { lock.unlock() }
            return recordedIds
        }
    }

    @Test
    @MainActor
    func legacyMoveSelectedWorkspacesToNewWindowMovesFinalWorkspaceOnce() async throws {
        _ = NSApplication.shared

        let defaultsSuiteName = "SidebarWorkspaceContextMenuWindowTargetsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.set(
            CmuxExtensionSidebarSelection.defaultProviderId,
            forKey: CmuxExtensionSidebarSelection.defaultsKey
        )

        let featureFlags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { _ in nil }
        )
        featureFlags.setOverride(false, for: CmuxFeatureFlags.appKitSidebarListFlag)

        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        AppDelegate.shared = app

        let sourceManager = TabManager(autoWelcomeIfNeeded: false)
        while sourceManager.tabs.count < 4 {
            sourceManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        }
        let movedIds = Array(sourceManager.tabs.prefix(3).map(\.id))
        let remainingId = try #require(sourceManager.tabs.last?.id)
        let sourceWindowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(sourceWindowId.uuidString)")

        let fileExplorerState = FileExplorerState()
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let cmuxConfigStore = CmuxConfigStore()
        app.registerMainWindow(
            window,
            windowId: sourceWindowId,
            tabManager: sourceManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore
        )
        app.tabManager = sourceManager
        TerminalController.shared.setActiveTabManager(sourceManager)

        var selectedIds = Set(movedIds)
        var lastSelectionIndex: Int? = 2

        let root = VerticalTabsSidebar(
            updateViewModel: UpdateStateModel(),
            fileExplorerState: fileExplorerState,
            featureFlags: featureFlags,
            sidebarUnread: SidebarUnreadModel(),
            titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
            windowId: sourceWindowId,
            onSendFeedback: {},
            onToggleSidebar: {},
            onNewTab: {},
            observedWindowReference: WeakWindowReference(window),
            selection: .constant(.tabs),
            selectedTabIds: Binding(
                get: { selectedIds },
                set: { selectedIds = $0 }
            ),
            lastSidebarSelectionIndex: Binding(
                get: { lastSelectionIndex },
                set: { lastSelectionIndex = $0 }
            ),
            sidebarRenderWorkerClient: .constant(nil)
        )
        .frame(width: 280)
        .environmentObject(sourceManager)
        .environmentObject(cmuxConfigStore)
        .environmentObject(TerminalNotificationStore.shared)
        .environmentObject(sidebarState)
        .environmentObject(sidebarSelectionState)
        .defaultAppStorage(defaults)

        let hostingView = NSHostingView(rootView: root)
        window.contentView = hostingView
        window.orderFront(nil)

        defer {
            window.contentView = nil
            window.orderOut(nil)
            window.close()
            for destinationWindowId in app.mainWindowContexts.values
                .map(\.windowId)
                .filter({ $0 != sourceWindowId }) {
                app.discardMainWindowWithoutClosedHistory(windowId: destinationWindowId)
            }
            app.unregisterMainWindowContextForTesting(windowId: sourceWindowId)
            sourceManager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        await Self.drainMainRunLoop(for: window)
        let menu = try #require(Self.workspaceContextMenu(in: hostingView, window: window))
        let moveMenuTitle = String(
            localized: "contextMenu.moveWorkspacesToWindow",
            defaultValue: "Move Workspaces to Window"
        )
        let newWindowTitle = String(
            localized: "contextMenu.newWindow",
            defaultValue: "New Window"
        )
        let moveMenu = try #require(menu.items.first { $0.title == moveMenuTitle }?.submenu)
        let newWindowIndex = try #require(moveMenu.items.firstIndex { $0.title == newWindowTitle })

        let focusRecorder = FocusedWorkspaceRecorder()
        let focusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusTab,
            object: nil,
            queue: .main
        ) { notification in
            if let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID {
                focusRecorder.record(workspaceId)
            }
        }
        defer { NotificationCenter.default.removeObserver(focusObserver) }

        moveMenu.performActionForItem(at: newWindowIndex)
        await Self.drainMainRunLoop(for: window)

        let destination = try #require(app.mainWindowContexts.values.first { context in
            context.windowId != sourceWindowId
                && movedIds.allSatisfy { movedId in
                    context.tabManager.tabs.contains(where: { $0.id == movedId })
                }
        })
        #expect(sourceManager.tabs.map(\.id) == [remainingId])
        #expect(destination.tabManager.tabs.map(\.id) == movedIds)
        #expect(destination.tabManager.selectedTabId == movedIds.last)
        #expect(
            focusRecorder.ids.filter(Set(movedIds).contains).isEmpty,
            "The final workspace must be attached once with focus: true, not attached unfocused and then focused by a second move call."
        )
    }

    @Test
    @MainActor
    func menuPresentationResolvesWindowTargetsAfterRowRender() throws {
        let firstWindowId = UUID()
        let laterWindowId = UUID()
        var currentTargets = [
            SidebarWorkspaceWindowMoveTarget(
                windowId: firstWindowId,
                label: "Window 1",
                isCurrentWindow: true
            )
        ]
        var resolvedTopologies: [[UUID]] = []
        let actions = Self.actions {
            resolvedTopologies.append(currentTargets.map(\.windowId))
            return currentTargets
        }
        let row = TabItemView(
            snapshot: try Self.rowSnapshot(),
            actions: actions
        )

        // Rendering the lazy row must not freeze or resolve app-window state.
        _ = row.body
        #expect(resolvedTopologies.isEmpty)

        currentTargets = [
            SidebarWorkspaceWindowMoveTarget(
                windowId: firstWindowId,
                label: "Window 1",
                isCurrentWindow: true
            ),
            SidebarWorkspaceWindowMoveTarget(
                windowId: laterWindowId,
                label: "Window 2",
                isCurrentWindow: false
            )
        ]

        // SwiftUI evaluates this deferred wrapper when presenting the menu.
        _ = TabItemWorkspaceContextMenuContent(row: row).body
        #expect(resolvedTopologies == [[firstWindowId, laterWindowId]])
    }

    @MainActor
    private static func rowSnapshot() throws -> SidebarWorkspaceRowSnapshot {
        let suiteName = "SidebarWorkspaceContextMenuWindowTargetsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return SidebarWorkspaceRowSnapshot(
            workspaceId: UUID(),
            groupId: nil,
            index: 0,
            workspaceCount: 1,
            workspace: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(),
            isActive: true,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: false,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: false,
            rowSpacing: 0,
            showsModifierShortcutHints: false,
            isPointerHovering: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isBonsplitWorkspaceDropActive: false,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            contextMenu: SidebarWorkspaceContextMenuSnapshot(
                targetWorkspaceIds: [],
                remoteTargetWorkspaceIds: [],
                allRemoteTargetsConnecting: false,
                allRemoteTargetsDisconnected: false,
                pinState: nil,
                groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
                canCreateEmptyGroup: true,
                eligibleGroupTargetIds: [],
                allEligibleTargetsGroupId: nil,
                hasGroupedEligibleTarget: false,
                todoStatusLanes: [],
                canMarkRead: false,
                canMarkUnread: false,
                hasLatestNotification: false,
                notifications: []
            )
        )
    }

    @MainActor
    private static func actions(
        currentWindowMoveTargets: @escaping () -> [SidebarWorkspaceWindowMoveTarget]
    ) -> SidebarWorkspaceRowActions {
        SidebarWorkspaceRowActions(
            select: { _ in },
            setCustomTitle: { _ in },
            clearCustomTitle: {},
            clearCustomDescription: {},
            editDescription: {},
            closeWorkspace: {},
            moveBy: { _ in },
            moveTargetsToTop: { _ in },
            currentWindowMoveTargets: currentWindowMoveTargets,
            moveTargetsToWindow: { _, _ in },
            moveTargetsToNewWindow: { _ in },
            closeTargets: { _, _ in },
            closeOtherTargets: { _ in },
            closeTargetsBelow: {},
            closeTargetsAbove: {},
            performPin: {},
            createEmptyGroup: {},
            createGroup: { _ in },
            addTargetsToGroup: { _, _ in },
            removeTargetsFromGroup: { _ in },
            reconnectTargets: { _ in },
            disconnectTargets: { _ in },
            applyColor: { _, _ in },
            applyTodoStatus: { _, _ in },
            hideTodoStatus: { _ in },
            requestChecklistAdd: {},
            markRead: { _ in },
            markUnread: { _ in },
            clearLatestNotifications: { _ in },
            openNotification: { _ in },
            copyWorkspaceLinks: { _ in },
            openPullRequest: { _ in },
            openPort: { _ in },
            checklist: SidebarWorkspaceChecklistActions(
                setItemState: { _, _ in },
                removeItem: { _ in },
                addItem: { _ in },
                editItem: { _, _ in },
                moveItem: { _, _ in },
                openPane: {},
                addAttachments: { _ in },
                removeAttachment: { _, _ in },
                openAttachments: { _, _ in }
            ),
            onDragStart: { NSItemProvider() },
            bonsplitSourceWorkspaceId: { _ in nil },
            moveBonsplitTabToWorkspace: { _, _ in false },
            syncAfterBonsplitDrop: {},
            selectAfterBonsplitDrop: {},
            onToggleChecklistExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            onChecklistPopoverPresentedChange: { _ in },
            onContextMenuAppear: {},
            onContextMenuDisappear: {},
            onPointerFrameChange: { _ in },
            onPointerFrameDisappear: {}
        )
    }

    @MainActor
    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 30) async {
        for _ in 0..<iterations {
            autoreleasepool {
                window.contentView?.layoutSubtreeIfNeeded()
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
            await Task.yield()
        }
    }

    @MainActor
    private static func workspaceContextMenu<Content: View>(
        in hostingView: NSHostingView<Content>,
        window: NSWindow
    ) -> NSMenu? {
        let moveMenuTitle = String(
            localized: "contextMenu.moveWorkspacesToWindow",
            defaultValue: "Move Workspaces to Window"
        )
        let x = hostingView.bounds.midX
        for y in stride(
            from: Int(hostingView.bounds.maxY) - 1,
            through: 1,
            by: -4
        ) {
            guard let event = NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: x, y: CGFloat(y)),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ), let menu = hostingView.menu(for: event) else {
                continue
            }
            if menu.items.contains(where: { $0.title == moveMenuTitle }) {
                return menu
            }
        }
        return nil
    }
}
