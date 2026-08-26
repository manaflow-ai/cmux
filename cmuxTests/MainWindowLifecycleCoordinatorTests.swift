import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Main window lifecycle coordinator", .serialized)
struct MainWindowLifecycleCoordinatorTests {
    @Test("Closing window ids cannot be registered again")
    func closingWindowIdsCannotBeRegisteredAgain() {
        let coordinator = MainWindowLifecycleCoordinator()
        let windowId = UUID()
        let originalManager = TabManager(autoWelcomeIfNeeded: false)
        let replacementManager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            tearDown(originalManager)
            tearDown(replacementManager)
        }

        let original = makeContext(windowId: windowId, manager: originalManager)
        coordinator.register(original, lookupKey: ObjectIdentifier(originalManager))
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: originalManager,
            window: nil,
            sidebar: original.sidebarState,
            sidebarSelection: original.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: false
        )
        #expect(coordinator.transitionToClosing(route, from: original))

        let replacement = makeContext(windowId: windowId, manager: replacementManager)
        coordinator.register(replacement, lookupKey: ObjectIdentifier(replacementManager))

        #expect(coordinator.registeredContext(windowId: windowId) == nil)
        #expect(coordinator.teardownRoute(windowId: windowId) === route)
    }

    @Test("Frozen orphan ids cannot be registered again")
    func frozenOrphanIdsCannotBeRegisteredAgain() {
        let app = AppDelegate()
        let windowId = UUID()
        let originalManager = TabManager(autoWelcomeIfNeeded: false)
        let replacementManager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            tearDown(originalManager)
            tearDown(replacementManager)
        }

        let original = makeContext(windowId: windowId, manager: originalManager)
        app.mainWindowLifecycleCoordinator.register(
            original,
            lookupKey: ObjectIdentifier(originalManager)
        )
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            frozenWindowSnapshot: emptyWindowSnapshot(windowId: windowId)
        )
        #expect(
            app.mainWindowLifecycleCoordinator.transitionToOrphaned(
                route,
                from: original
            )
        )
        #expect(app.availableWindowIdForNewMainWindow(preferredWindowId: windowId) == nil)

        let replacement = makeContext(windowId: windowId, manager: replacementManager)
        app.mainWindowLifecycleCoordinator.register(
            replacement,
            lookupKey: ObjectIdentifier(replacementManager)
        )

        #expect(app.mainWindowLifecycleCoordinator.registeredContext(windowId: windowId) == nil)
        #expect(app.mainWindowLifecycleCoordinator.orphanedRoute(windowId: windowId) === route)
    }

    @Test("Matching frozen orphan is consumed before session reopen")
    func matchingFrozenOrphanIsConsumedBeforeSessionReopen() {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { tearDown(manager) }

        let context = makeContext(windowId: windowId, manager: manager)
        app.mainWindowLifecycleCoordinator.register(
            context,
            lookupKey: ObjectIdentifier(manager)
        )
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            frozenWindowSnapshot: emptyWindowSnapshot(windowId: windowId)
        )
        #expect(
            app.mainWindowLifecycleCoordinator.transitionToOrphaned(
                route,
                from: context
            )
        )
        #expect(app.availableWindowIdForNewMainWindow(preferredWindowId: windowId) == nil)

        #expect(
            app.mainWindowLifecycleCoordinator.removeFrozenOrphanRoute(windowId: windowId)
        )
        #expect(app.availableWindowIdForNewMainWindow(preferredWindowId: windowId) == windowId)
        #expect(app.mainWindowLifecycleCoordinator.orphanedRoute(windowId: windowId) == nil)
    }

    @Test("Live orphan registration reattaches the original context")
    func liveOrphanRegistrationReattachesOriginalContext() {
        let coordinator = MainWindowLifecycleCoordinator()
        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { tearDown(manager) }

        let original = makeContext(windowId: windowId, manager: manager)
        coordinator.register(original, lookupKey: ObjectIdentifier(manager))
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: manager,
            window: nil,
            sidebar: original.sidebarState,
            sidebarSelection: original.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: true
        )
        #expect(coordinator.transitionToOrphaned(route, from: original))

        let replacement = AppDelegate.MainWindowContext(
            windowId: windowId,
            tabManager: manager,
            sidebarState: original.sidebarState,
            sidebarSelectionState: original.sidebarSelectionState,
            fileExplorerState: nil,
            cmuxConfigStore: nil,
            window: nil,
            workspaceTerminalFontSizeArbiter:
                WorkspaceTerminalFontSizeArbiter()
        )
        coordinator.register(replacement, lookupKey: ObjectIdentifier(replacement))

        #expect(coordinator.registeredContext(windowId: windowId) === original)
        #expect(coordinator.orphanedRoute(windowId: windowId) == nil)
    }

    @Test("Hidden orphan window does not block replacement registration")
    func hiddenOrphanWindowDoesNotBlockReplacementRegistration() {
        let coordinator = MainWindowLifecycleCoordinator()
        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let originalWindow = makeWindow()
        let replacementWindow = makeWindow()
        defer {
            originalWindow.close()
            replacementWindow.close()
            tearDown(manager)
        }

        let original = AppDelegate.MainWindowContext(
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: nil,
            cmuxConfigStore: nil,
            window: originalWindow,
            workspaceTerminalFontSizeArbiter:
                WorkspaceTerminalFontSizeArbiter()
        )
        coordinator.register(
            original,
            lookupKey: ObjectIdentifier(originalWindow)
        )
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: manager,
            window: originalWindow,
            sidebar: original.sidebarState,
            sidebarSelection: original.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: true
        )
        #expect(coordinator.transitionToOrphaned(route, from: original))
        #expect(!originalWindow.isVisible)
        #expect(!originalWindow.isMiniaturized)

        let replacement = AppDelegate.MainWindowContext(
            windowId: windowId,
            tabManager: manager,
            sidebarState: original.sidebarState,
            sidebarSelectionState: original.sidebarSelectionState,
            fileExplorerState: nil,
            cmuxConfigStore: nil,
            window: replacementWindow,
            workspaceTerminalFontSizeArbiter:
                WorkspaceTerminalFontSizeArbiter()
        )
        let registered = coordinator.register(
            replacement,
            lookupKey: ObjectIdentifier(replacementWindow)
        )

        #expect(registered === original)
        #expect(coordinator.registeredContext(windowId: windowId) === original)
        #expect(coordinator.orphanedRoute(windowId: windowId) == nil)
        #expect(originalWindow.identifier == nil)
    }

    @Test("Lookup repair updates the lifecycle record key")
    func lookupRepairUpdatesLifecycleRecordKey() {
        let coordinator = MainWindowLifecycleCoordinator()
        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { tearDown(manager) }

        let context = makeContext(windowId: windowId, manager: manager)
        let originalLookupKey = ObjectIdentifier(manager)
        #expect(coordinator.register(context, lookupKey: originalLookupKey) === context)

        // AppKit identity repair can replace the exact-window key while the
        // stable window record remains registered. The two indexes must move
        // together so the next lifecycle transition still finds the context.
        let repairedLookupKey = ObjectIdentifier(context)
        coordinator.replaceRegisteredContextLookups([repairedLookupKey: context])

        #expect(coordinator.registeredContext(for: repairedLookupKey) === context)
        #expect(coordinator.registeredContext(windowId: windowId) === context)

        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: manager,
            window: nil,
            sidebar: context.sidebarState,
            sidebarSelection: context.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: true
        )
        #expect(coordinator.transitionToOrphaned(route, from: context))
    }

    @Test("Frozen orphan retention keeps only the newest configured records")
    func frozenOrphanRetentionKeepsNewestRecords() {
        let coordinator = MainWindowLifecycleCoordinator(
            maximumFrozenOrphanRecords: 2
        )
        let windowIds = (0..<4).map { _ in UUID() }
        var managers: [TabManager] = []
        defer {
            for manager in managers {
                for workspace in manager.tabs {
                    workspace.teardownAllPanels()
                    workspace.teardownRemoteConnection()
                    workspace.owningTabManager = nil
                }
            }
        }

        for windowId in windowIds {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            managers.append(manager)
            let context = AppDelegate.MainWindowContext(
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: nil,
                cmuxConfigStore: nil,
                window: nil,
                workspaceTerminalFontSizeArbiter:
                    WorkspaceTerminalFontSizeArbiter()
            )
            coordinator.register(
                context,
                lookupKey: ObjectIdentifier(manager)
            )
            let route = RecoverableMainWindowRoute(
                windowId: windowId,
                frozenWindowSnapshot: emptyWindowSnapshot(windowId: windowId)
            )
            #expect(coordinator.transitionToOrphaned(route, from: context))
        }

        #expect(coordinator.orphanedRoute(windowId: windowIds[0]) == nil)
        #expect(coordinator.orphanedRoute(windowId: windowIds[1]) == nil)
        #expect(coordinator.orphanedRoute(windowId: windowIds[2]) != nil)
        #expect(coordinator.orphanedRoute(windowId: windowIds[3]) != nil)
        #expect(coordinator.orphanedRoutes().map(\.windowId) == [windowIds[3], windowIds[2]])
    }

    @Test("Frozen orphan retention follows orphaning order")
    func frozenOrphanRetentionFollowsOrphaningOrder() {
        let coordinator = MainWindowLifecycleCoordinator(maximumFrozenOrphanRecords: 2)
        let windowIds = (0..<3).map { _ in UUID() }
        let managers = windowIds.map { _ in TabManager(autoWelcomeIfNeeded: false) }
        defer { managers.forEach { tearDown($0) } }

        let contexts = zip(windowIds, managers).map { windowId, manager in
            makeContext(windowId: windowId, manager: manager)
        }
        for (context, manager) in zip(contexts, managers) {
            coordinator.register(context, lookupKey: ObjectIdentifier(manager))
        }

        for index in [2, 0, 1] {
            let route = RecoverableMainWindowRoute(
                windowId: windowIds[index],
                frozenWindowSnapshot: emptyWindowSnapshot(windowId: windowIds[index])
            )
            #expect(coordinator.transitionToOrphaned(route, from: contexts[index]))
        }

        #expect(coordinator.orphanedRoutes().map(\.windowId) == [windowIds[1], windowIds[0]])
    }

    @Test("Inactive pruning preserves frozen persistence routes")
    func inactivePruningPreservesFrozenPersistenceRoutes() {
        let app = AppDelegate()
        let windowId = UUID()
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            frozenWindowSnapshot: emptyWindowSnapshot(windowId: windowId)
        )
        #expect(app.mainWindowLifecycleCoordinator.rememberStandaloneOrphanedRoute(route))

        app.retireInactiveRecoverableMainWindowRoutes(reason: "frozen-route-regression")

        #expect(app.mainWindowLifecycleCoordinator.orphanedRoute(windowId: windowId) === route)
        #expect(route.frozenWindowSnapshot != nil)
        app.forgetRecoverableMainWindowRoute(windowId: windowId)
    }

    @Test("Ineligible remote orphan does not consume a freeze slot")
    func ineligibleRemoteOrphanDoesNotConsumeFreezeSlot() throws {
        let coordinator = MainWindowLifecycleCoordinator()
        let eligibleWindowId = UUID()
        let remoteWindowId = UUID()
        let eligibleManager = TabManager(autoWelcomeIfNeeded: false)
        let remoteManager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            tearDown(eligibleManager)
            tearDown(remoteManager)
        }

        let remoteWorkspace = remoteManager.addWorkspace(
            title: "remote",
            select: true,
            autoWelcomeIfNeeded: false
        )
        remoteWorkspace.isRemoteTmuxMirror = true
        _ = eligibleManager.addWorkspace(
            title: "eligible",
            select: true,
            autoWelcomeIfNeeded: false
        )
        let eligibleContext = makeContext(
            windowId: eligibleWindowId,
            manager: eligibleManager
        )
        let remoteContext = makeContext(
            windowId: remoteWindowId,
            manager: remoteManager
        )
        coordinator.register(
            eligibleContext,
            lookupKey: ObjectIdentifier(eligibleManager)
        )
        coordinator.register(
            remoteContext,
            lookupKey: ObjectIdentifier(remoteManager)
        )
        let eligibleRoute = RecoverableMainWindowRoute(
            windowId: eligibleWindowId,
            tabManager: eligibleManager,
            window: nil,
            sidebar: eligibleContext.sidebarState,
            sidebarSelection: eligibleContext.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: true
        )
        let remoteRoute = RecoverableMainWindowRoute(
            windowId: remoteWindowId,
            tabManager: remoteManager,
            window: nil,
            sidebar: remoteContext.sidebarState,
            sidebarSelection: remoteContext.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: true
        )
        #expect(coordinator.transitionToOrphaned(eligibleRoute, from: eligibleContext))
        #expect(coordinator.transitionToOrphaned(remoteRoute, from: remoteContext))

        #expect(
            coordinator.shouldFreezeWindowlessRoute(
                windowId: eligibleWindowId,
                availablePersistenceSlots: 1
            )
        )
        #expect(
            !coordinator.shouldFreezeWindowlessRoute(
                windowId: remoteWindowId,
                availablePersistenceSlots: 1
            )
        )
    }

    @Test("Frozen orphan snapshots occupy the freeze slot cap")
    func frozenOrphanSnapshotsOccupyFreezeSlotCap() {
        let coordinator = MainWindowLifecycleCoordinator()
        let frozenWindowId = UUID()
        let liveWindowId = UUID()
        let frozenManager = TabManager(autoWelcomeIfNeeded: false)
        let liveManager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            tearDown(frozenManager)
            tearDown(liveManager)
        }

        let frozenContext = makeContext(
            windowId: frozenWindowId,
            manager: frozenManager
        )
        let liveContext = makeContext(
            windowId: liveWindowId,
            manager: liveManager
        )
        coordinator.register(
            frozenContext,
            lookupKey: ObjectIdentifier(frozenManager)
        )
        coordinator.register(
            liveContext,
            lookupKey: ObjectIdentifier(liveManager)
        )
        let frozenRoute = RecoverableMainWindowRoute(
            windowId: frozenWindowId,
            frozenWindowSnapshot: emptyWindowSnapshot(windowId: frozenWindowId)
        )
        let liveRoute = RecoverableMainWindowRoute(
            windowId: liveWindowId,
            tabManager: liveManager,
            window: nil,
            sidebar: liveContext.sidebarState,
            sidebarSelection: liveContext.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: true
        )
        #expect(coordinator.transitionToOrphaned(liveRoute, from: liveContext))
        #expect(coordinator.transitionToOrphaned(frozenRoute, from: frozenContext))

        #expect(
            !coordinator.shouldFreezeWindowlessRoute(
                windowId: liveWindowId,
                availablePersistenceSlots: 1
            )
        )
    }

    @Test("Windowless recovery detection is coalesced and canceled when unused")
    func windowlessRecoveryDetectionIsCoalescedAndCanceledWhenUnused() async {
        let coordinator = MainWindowLifecycleCoordinator()
        let probe = WindowlessRecoveryLoadProbe()
        let firstBindings: [SurfaceResumeBindingIndex.PanelKey: Int64] = [:]
        let laterKey = SurfaceResumeBindingIndex.PanelKey(
            workspaceId: UUID(),
            panelId: UUID()
        )
        let laterBindings = [laterKey: Int64(42)]
        let loader: @Sendable (
            [SurfaceResumeBindingIndex.PanelKey: Int64]
        ) async -> ProcessDetectedResumeIndexes? = { bindings in
            await probe.load(bindings: bindings)
        }

        let first = Task { @MainActor in
            await coordinator.loadWindowlessRecoveryResumeIndexes(
                ttyDeviceBindings: firstBindings,
                loader: loader
            )
        }
        await probe.waitUntilStarted()
        let second = Task { @MainActor in
            await coordinator.loadWindowlessRecoveryResumeIndexes(
                ttyDeviceBindings: laterBindings,
                loader: loader
            )
        }
        await Task.yield()

        coordinator.cancelWindowlessRecoveryResumeIndexesLoadIfUnused()
        await probe.release()
        _ = await first.value
        _ = await second.value

        #expect(await probe.loadCount > 0)
        #expect(await probe.loadCount <= 2)
        #expect(await probe.observedBinding(laterKey))
        #expect(await probe.observedCancellation)
    }

    @Test("Unavailable windowless recovery detection stays unavailable")
    func unavailableWindowlessRecoveryDetectionStaysUnavailable() async {
        let coordinator = MainWindowLifecycleCoordinator()
        let result = await coordinator.loadWindowlessRecoveryResumeIndexes(
            ttyDeviceBindings: [:],
            loader: { _ in nil }
        )

        #expect(result == nil)
    }

    @Test("Removing a windowless orphan cancels its owned freeze task")
    func removingWindowlessOrphanCancelsItsOwnedFreezeTask() async {
        let coordinator = MainWindowLifecycleCoordinator()
        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { tearDown(manager) }

        let context = makeContext(windowId: windowId, manager: manager)
        coordinator.register(context, lookupKey: ObjectIdentifier(manager))
        let route = RecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: manager,
            window: nil,
            sidebar: context.sidebarState,
            sidebarSelection: context.sidebarSelectionState,
            frozenWindowDockSnapshot: nil,
            retainTabManager: true
        )
        #expect(coordinator.transitionToOrphaned(route, from: context))

        let task: Task<Void, Never> = Task { @MainActor in
            for _ in 0..<256 {
                if Task.isCancelled { return }
                await Task.yield()
            }
        }
        coordinator.retainWindowlessRouteFreezeTask(
            task,
            windowId: windowId,
            token: UUID()
        )
        coordinator.removeRecoverableRoute(windowId: windowId)

        _ = await task.value
        #expect(task.isCancelled)
    }

    private func emptyWindowSnapshot(windowId: UUID) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: windowId,
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: nil,
                workspaces: []
            ),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            )
        )
    }

    private func makeContext(
        windowId: UUID,
        manager: TabManager
    ) -> AppDelegate.MainWindowContext {
        AppDelegate.MainWindowContext(
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: nil,
            cmuxConfigStore: nil,
            window: nil,
            workspaceTerminalFontSizeArbiter:
                WorkspaceTerminalFontSizeArbiter()
        )
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func tearDown(_ manager: TabManager) {
        for workspace in manager.tabs {
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            workspace.owningTabManager = nil
        }
    }
}

private actor WindowlessRecoveryLoadProbe {
    private(set) var loadCount = 0
    private(set) var observedCancellation = false
    private(set) var observedBindingKeys: Set<SurfaceResumeBindingIndex.PanelKey> = []
    private var hasStarted = false
    private var isReleased = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func load(
        bindings: [SurfaceResumeBindingIndex.PanelKey: Int64]
    ) async -> ProcessDetectedResumeIndexes {
        loadCount += 1
        observedBindingKeys.formUnion(bindings.keys)
        hasStarted = true
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll(keepingCapacity: false)

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        observedCancellation = Task.isCancelled
        return .cached(restorableAgentIndex: .empty)
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll(keepingCapacity: false)
    }

    func observedBinding(_ key: SurfaceResumeBindingIndex.PanelKey) -> Bool {
        observedBindingKeys.contains(key)
    }
}
