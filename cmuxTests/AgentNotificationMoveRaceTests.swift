import AppKit
import CmuxControlSocket
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent notification regressions", .serialized)
@MainActor
struct AgentNotificationRegressionTests {
    struct Fixture {
        let store: TerminalNotificationStore
        let appDelegate: AppDelegate
        let manager: TabManager
        let source: Workspace
        let destination: Workspace
        let panelId: UUID
        let restore: () -> Void
    }

    func makeFixture(
        policyHookCommand: String? = nil,
        policyHookTimeoutSeconds: TimeInterval? = nil
    ) throws -> Fixture {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        let configRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-notification-move-race-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let configURL = configRoot.appendingPathComponent("cmux.json")
        if let policyHookCommand {
            let encodedCommand = try String(data: JSONEncoder().encode(policyHookCommand), encoding: .utf8)
            let timeoutJSON = policyHookTimeoutSeconds.map { ",\"timeoutSeconds\":\($0)" } ?? ""
            try #"{"notifications":{"hooks":[{"id":"move-race","command":\#(encodedCommand ?? "\"cat\"")\#(timeoutJSON)}]}}"#
                .write(to: configURL, atomically: true, encoding: .utf8)
        }
        let configStore = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false
        )
        configStore.loadAll()

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
                try? FileManager.default.removeItem(at: configRoot)
            }
        )
    }

    func movePanel(_ fixture: Fixture) throws {
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

    func waitForNotification(in store: TerminalNotificationStore) async {
        // Generous for loaded CI runners; only slows the failure path.
        let deadline = ContinuousClock.now + .seconds(15)
        while store.notifications.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        if store.notifications.isEmpty {
            Issue.record("Timed out waiting for policy-delayed notification")
        }
    }

    private func waitForFile(at url: URL) async -> Bool {
        // Generous for loaded CI runners; only slows the failure path.
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @Test("Workspace clear resolves a repeated pending surface only once")
    func workspaceClearMemoizesPendingSurfaceResolution() {
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer { bus.discardPendingNotifications() }
        let claimedTabId = UUID()
        let liveTabId = UUID()
        let surfaceId = UUID()
        for index in 0..<128 {
            bus.enqueueNotification(
                tabId: claimedTabId,
                surfaceId: surfaceId,
                title: "Claude Code",
                subtitle: "Completed",
                body: "Queued \(index)",
                coalesces: false
            )
        }

        var resolutionCount = 0
        let sequences = bus.pendingNotificationSequencesResolvingLiveOwner(
            forTabId: liveTabId,
            liveOwnerResolver: { _, _ in
                resolutionCount += 1
                return liveTabId
            }
        )

        #expect(sequences.count == 128)
        #expect(resolutionCount == 1)
    }

    @Test("Source-confined synchronous delivery does not follow a moved surface")
    func sourceConfinedSynchronousDeliveryDoesNotRetarget() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        try movePanel(fixture)

        TerminalController.shared.deliverNotificationSynchronously(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Relay",
            subtitle: "Completed",
            body: "Confined to authorized source",
            retargetsToLiveSurfaceOwner: false
        )

        let recorded = fixture.store.notifications.filter { $0.title == "Relay" }
        #expect(recorded.map(\.tabId) == [fixture.source.id])
        #expect(!recorded.contains { $0.tabId == fixture.destination.id })
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

    @Test("Desktop OSC suppression follows the live pane owner after hook lookup")
    func desktopOSCSuppressionUsesLiveOwnerAfterHookLookup() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        try movePanel(fixture)
        fixture.destination.recordAgentPID(
            key: "codex.codex-session-live-owner",
            pid: pid_t(12_345),
            panelId: fixture.panelId
        )

        await fixture.store.addDesktopNotificationResolvingHooks(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            hookDirectory: nil,
            title: "OSC live-owner suppression",
            body: "Must be suppressed by the destination"
        )

        #expect(!fixture.store.notifications.contains { $0.title == "OSC live-owner suppression" })
    }

    @Test("Policy-delayed delivery resolves the pane owner again after a move")
    func policyDelayedDeliveryRetargetsAtFinalApply() async throws {
        let fixture = try makeFixture(policyHookCommand: "cat")
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
            await waitForNotification(in: fixture.store)
        }

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        #expect(recorded.map(\.tabId) == [fixture.destination.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
    }

    @Test("Policy-delayed relay delivery stays in its authorized workspace")
    func policyDelayedRelayDeliveryDoesNotCrossWorkspaceBoundary() async throws {
        let fixture = try makeFixture(policyHookCommand: "cat")
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
            await waitForNotification(in: fixture.store)
        }

        let recorded = fixture.store.notifications.filter { $0.title == "Relay" }
        #expect(recorded.map(\.tabId) == [fixture.source.id])
        #expect(!recorded.contains { $0.tabId == fixture.destination.id })

        fixture.store.clearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        )
        #expect(fixture.store.notifications.isEmpty)
    }

    @Test("Immediate relay delivery stays in its authorized workspace after a move")
    func immediateRelayDeliveryDoesNotRebindAcrossWorkspaceBoundary() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        AppFocusState.overrideIsFocused = true

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
            title: "Relay immediate",
            subtitle: "Completed",
            body: "Must remain source-confined"
        )
        guard case .delivered = result else {
            Issue.record("Expected relay-target delivery, got \(result)")
            return
        }
        #expect(fixture.store.focusedReadIndicatorSurfaceId(forTabId: fixture.source.id) == fixture.panelId)

        try movePanel(fixture)

        let recorded = fixture.store.notifications.filter { $0.title == "Relay immediate" }
        #expect(recorded.map(\.tabId) == [fixture.source.id])
        #expect(!recorded.contains { $0.tabId == fixture.destination.id })
        #expect(fixture.store.focusedReadIndicatorSurfaceId(forTabId: fixture.destination.id) == nil)
    }

    @Test("Session persistence preserves source-confined notification provenance")
    func sessionPersistencePreservesSourceConfinement() throws {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            retargetsToLiveSurfaceOwner: false,
            title: "Relay persisted",
            subtitle: "Completed",
            body: "Must remain source-confined",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: false
        )

        let data = try JSONEncoder().encode(SessionNotificationSnapshot(notification: notification))
        let decoded = try JSONDecoder().decode(SessionNotificationSnapshot.self, from: data)
        let restored = decoded.terminalNotification(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            panelId: notification.panelId
        )

        #expect(!restored.retargetsToLiveSurfaceOwner)
    }

    @Test("Legacy session notifications retain trusted local move behavior")
    func legacySessionNotificationDefaultsToLiveRetargeting() throws {
        let legacySnapshot = SessionNotificationSnapshot(
            id: UUID(),
            title: "Legacy local",
            subtitle: "Completed",
            body: "Follows its pane",
            createdAt: 1_700_000_000,
            isRead: false
        )
        let data = try JSONEncoder().encode(legacySnapshot)
        let decoded = try JSONDecoder().decode(SessionNotificationSnapshot.self, from: data)
        let restored = decoded.terminalNotification(
            tabId: UUID(),
            surfaceId: UUID(),
            panelId: nil
        )

        #expect(restored.retargetsToLiveSurfaceOwner)
    }

    @Test("A destination clear preserves source-confined in-flight relay delivery")
    func destinationClearPreservesInFlightRelayDelivery() async throws {
        let completionURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-policy-relay-clear-finished-\(UUID().uuidString)"
        )
        let fixture = try makeFixture(policyHookCommand: "cat; touch '\(completionURL.path)'")
        defer { fixture.restore() }
        defer { try? FileManager.default.removeItem(at: completionURL) }

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
            body: "Must survive destination clear"
        )
        guard case .delivered = result else {
            Issue.record("Expected relay-target delivery, got \(result)")
            return
        }

        try movePanel(fixture)
        fixture.store.clearNotifications(forTabId: fixture.destination.id)

        #expect(await waitForFile(at: completionURL))
        for _ in 0..<100 { await Task.yield() }
        let recorded = fixture.store.notifications.filter { $0.title == "Relay" }
        #expect(recorded.map(\.tabId) == [fixture.source.id])
        #expect(!recorded.contains { $0.tabId == fixture.destination.id })
    }

    @Test("A stale source surface clear preserves destination-confined in-flight relay delivery")
    func staleSourceSurfaceClearPreservesDestinationConfinedInFlightRelayDelivery() async throws {
        let completionURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-policy-relay-source-clear-finished-\(UUID().uuidString)"
        )
        let fixture = try makeFixture(policyHookCommand: "cat; touch '\(completionURL.path)'")
        defer { fixture.restore() }
        defer { try? FileManager.default.removeItem(at: completionURL) }

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
            body: "Must stay cleared at its authorized source"
        )
        guard case .delivered = result else {
            Issue.record("Expected relay-target delivery, got \(result)")
            return
        }

        try movePanel(fixture)
        _ = TerminalController.shared.controlNotificationCreateForTarget(
            routing: routing, workspaceID: fixture.destination.id, surfaceID: fixture.panelId,
            title: "Relay live", subtitle: "Completed", body: "Must survive stale source clear"
        )
        fixture.store.clearNotifications(forTabId: fixture.source.id, surfaceId: fixture.panelId)

        #expect(await waitForFile(at: completionURL))
        for _ in 0..<100 { await Task.yield() }
        let recorded = fixture.store.notifications.filter { $0.title.hasPrefix("Relay") }
        #expect(recorded.map(\.tabId) == [fixture.destination.id])
        #expect(recorded.map(\.body) == ["Must survive stale source clear"])
    }

    @Test("A clear invalidates policy-delayed delivery that has not applied")
    func clearInvalidatesInFlightPolicyDelivery() async throws {
        let fixture = try makeFixture(policyHookCommand: "cat")
        defer { fixture.restore() }

        TerminalController.shared.deliverNotificationSynchronously(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Must stay cleared"
        )
        try movePanel(fixture)
        fixture.store.clearNotifications(
            forTabId: fixture.destination.id,
            surfaceId: fixture.panelId
        )

        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.store.notifications.isEmpty)
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
