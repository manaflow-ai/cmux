import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent notification move races", .serialized)
@MainActor
struct AgentNotificationMoveRaceTests {
    private struct Fixture {
        let store: TerminalNotificationStore
        let appDelegate: AppDelegate
        let manager: TabManager
        let source: Workspace
        let destination: Workspace
        let panelId: UUID
        let restore: () -> Void
    }

    private func makeFixture(policyHook: Bool = false) throws -> Fixture {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var configRoot: URL?
        var configStore: CmuxConfigStore?
        if policyHook {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cmux-notification-move-race-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configURL = root.appendingPathComponent("cmux.json")
            try #"{"notifications":{"hooks":[{"id":"move-race","command":"cat"}]}}"#
                .write(to: configURL, atomically: true, encoding: .utf8)
            let loadedStore = CmuxConfigStore(
                globalConfigPath: configURL.path,
                startFileWatchers: false
            )
            loadedStore.loadAll()
            configRoot = root
            configStore = loadedStore
        }

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            cmuxConfigStore: configStore
        )
        let source = manager.addWorkspace(select: true)
        let destination = manager.addWorkspace(select: false)
        let panelId = try #require(source.focusedPanelId)

        return Fixture(
            store: store,
            appDelegate: appDelegate,
            manager: manager,
            source: source,
            destination: destination,
            panelId: panelId,
            restore: {
                for workspace in [source, destination] where manager.tabs.contains(where: { $0.id == workspace.id }) {
                    manager.closeWorkspace(workspace)
                }
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                store.replaceNotificationsForTesting([])
                store.resetNotificationDeliveryHandlerForTesting()
                store.resetSuppressedNotificationFeedbackHandlerForTesting()
                appDelegate.tabManager = originalTabManager
                appDelegate.notificationStore = originalNotificationStore
                AppFocusState.overrideIsFocused = originalAppFocusOverride
                if let configRoot { try? FileManager.default.removeItem(at: configRoot) }
            }
        )
    }

    private func movePanel(_ fixture: Fixture) throws {
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let destinationPaneId = try #require(fixture.destination.bonsplitController.allPaneIds.first)
        #expect(
            fixture.destination.attachDetachedSurface(
                transfer,
                inPane: destinationPaneId,
                focus: false
            ) != nil
        )
    }

    @Test("Moving a pane preserves its pending notification")
    func paneMovePreservesPendingNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Queued before move"
        )
        try movePanel(fixture)
        TerminalMutationBus.shared.drainForTesting()

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(recorded.map(\.tabId) == [fixture.destination.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
    }

    @Test("Policy-delayed delivery resolves the pane owner again after a move")
    func policyDelayedDeliveryRetargetsAtFinalApply() async throws {
        let fixture = try makeFixture(policyHook: true)
        defer { fixture.restore() }

        try await confirmation("policy-delayed notification delivered") { delivered in
            fixture.store.configureNotificationDeliveryHandlerForTesting { _, _ in delivered() }
            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: fixture.source.id,
                surfaceID: nil,
                paneID: nil
            )
            let result = TerminalController.shared.controlNotificationCreateForSurface(
                routing: routing,
                surfaceID: fixture.panelId,
                title: "Claude Code",
                subtitle: "Completed",
                body: "Policy delayed"
            )
            guard case .delivered = result else {
                Issue.record("Expected local surface delivery, got \(result)")
                return
            }

            // `addNotification` has scheduled policy evaluation but cannot run
            // it until this MainActor job yields, so the move deterministically
            // occurs between initial routing and final apply.
            try movePanel(fixture)
            while fixture.store.notifications.isEmpty { await Task.yield() }
        }

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(recorded.map(\.tabId) == [fixture.destination.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
    }

    @Test("Policy-delayed relay delivery stays in its authorized workspace")
    func policyDelayedRelayDeliveryDoesNotCrossWorkspaceBoundary() async throws {
        let fixture = try makeFixture(policyHook: true)
        defer { fixture.restore() }

        try await confirmation("policy-delayed relay notification delivered") { delivered in
            fixture.store.configureNotificationDeliveryHandlerForTesting { _, _ in delivered() }
            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: fixture.source.id,
                surfaceID: nil,
                paneID: nil
            )
            let result = TerminalController.shared.controlNotificationCreateForTarget(
                routing: routing,
                workspaceID: fixture.source.id,
                surfaceID: fixture.panelId,
                title: "Relay",
                subtitle: "Completed",
                body: "Policy delayed"
            )
            guard case .delivered = result else {
                Issue.record("Expected relay-target delivery, got \(result)")
                return
            }

            try movePanel(fixture)
            while fixture.store.notifications.isEmpty { await Task.yield() }
        }

        let recorded = fixture.store.notifications.filter { $0.title == "Relay" }
        #expect(recorded.map(\.tabId) == [fixture.source.id])
        #expect(!recorded.contains { $0.tabId == fixture.destination.id })
    }

    @Test("A surface clear follows a stored notification to its current workspace")
    func surfaceClearRetargetsStoredNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stored before move"
        )
        try movePanel(fixture)
        #expect(fixture.store.notifications.map(\.tabId) == [fixture.destination.id])

        fixture.store.clearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        )

        #expect(fixture.store.notifications.isEmpty)
        #expect(!fixture.store.hasUnreadNotification(
            forTabId: fixture.destination.id,
            surfaceId: fixture.panelId
        ))
    }
}
