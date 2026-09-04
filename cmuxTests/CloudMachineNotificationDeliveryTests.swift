import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The store-side half of the cloud-machine notification boundary: once a machine's
/// notification is admitted and attributed, it may show, sound, badge, run the user's
/// global hooks and `notifications.command` (tagged with its origin), and reach the phone —
/// and it may never type into a pane, open a local path, borrow agent identity, or pull
/// project hooks out of a local directory.
@Suite("Cloud machine notification delivery", .serialized)
@MainActor
struct CloudMachineNotificationDeliveryTests {
    private struct Harness {
        let store: TerminalNotificationStore
        let workspace: Workspace
        let restore: @MainActor () -> Void
    }

    private func makeHarness() -> Harness {
        let store = TerminalNotificationStore.shared
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        if AppDelegate.shared == nil {
            AppDelegate.shared = appDelegate
        }
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        return Harness(store: store, workspace: workspace) {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppDelegate.shared = originalAppDelegate
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cloud-notify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForFile(_ url: URL, timeout: Duration = .seconds(10)) async throws -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test func remoteOriginIsClampedToDisplayOnly() throws {
        let harness = makeHarness()
        defer { harness.restore() }
        let surfaceId = try #require(harness.workspace.focusedPanelId)

        harness.store.addNotification(
            tabId: harness.workspace.id,
            surfaceId: surfaceId,
            title: "Build failed",
            subtitle: "vivid-newt",
            body: "api tests failed",
            replyShape: .text,
            clickAction: .revealInFinder(path: "/etc"),
            resolvedHooks: nil,
            origin: .cloudVM(machineID: "vivid-newt")
        )
        let remote = try #require(harness.store.notifications.first)
        #expect(remote.origin == .cloudVM(machineID: "vivid-newt"))
        #expect(remote.replyShape == .none, "no reply affordance that types into a pane")
        #expect(remote.clickAction == nil, "no click action that opens a local path")
        #expect(remote.subtitle == "vivid-newt")
        #expect(remote.title == "Build failed")
        #expect(remote.body == "api tests failed")
        #expect(remote.tabId == harness.workspace.id)
        #expect(remote.surfaceId == surfaceId)

        // The same call from a local origin keeps every affordance.
        harness.store.replaceNotificationsForTesting([])
        harness.store.addNotification(
            tabId: harness.workspace.id,
            surfaceId: surfaceId,
            title: "Local",
            subtitle: "",
            body: "reply allowed",
            replyShape: .text,
            clickAction: .revealInFinder(path: "/etc"),
            resolvedHooks: []
        )
        let local = try #require(harness.store.notifications.first)
        #expect(local.origin == .local)
        #expect(local.replyShape == .text)
        #expect(local.clickAction == .revealInFinder(path: "/etc"))
    }

    @Test func remoteOriginNeverConsultsProjectHooksInTheLocalDirectory() async throws {
        let harness = makeHarness()
        defer { harness.restore() }
        let surfaceId = try #require(harness.workspace.focusedPanelId)
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("project-hook-ran")
        let config = """
        {
          "notifications": {
            "hooks": [{ "id": "project-marker", "command": "touch '\(marker.path)'; cat" }]
          }
        }
        """
        try config.write(to: directory.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        // The directory really does carry a hook: a local emitter in this cwd would run it.
        let unusedGlobal = directory.appendingPathComponent("no-global.json").path
        let projectHooks = await harness.store.notificationHookCache.hooks(startingFrom: directory.path, globalConfigPath: unusedGlobal)
        #expect(projectHooks.map(\.id) == ["project-marker"])

        await harness.store.addDesktopNotificationResolvingHooks(
            tabId: harness.workspace.id,
            surfaceId: surfaceId,
            hookDirectory: directory.path,
            title: "from the machine",
            body: "hello",
            subtitle: "vivid-newt",
            origin: .cloudVM(machineID: "vivid-newt")
        )
        #expect(harness.store.notifications.map(\.title) == ["from the machine"])
        #expect(harness.store.notifications.first?.origin == .cloudVM(machineID: "vivid-newt"))
        #expect(harness.store.notifications.first?.subtitle == "vivid-newt")
        #expect(
            !FileManager.default.fileExists(atPath: marker.path),
            "a project cmux.json next to the local pane's cwd must never run for a machine's text"
        )
    }

    @Test func hookEnvironmentCarriesOriginAndHooksCannotPatchIt() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originFile = directory.appendingPathComponent("origin.txt")
        let envelopeFile = directory.appendingPathComponent("envelope.json")
        let capturingHook = CmuxResolvedNotificationHook(
            id: "origin-capture",
            command: "printf '%s' \"$CMUX_NOTIFICATION_ORIGIN\" > '\(originFile.path)'; "
                + "printf '%s' \"$CMUX_NOTIFICATION_POLICY_JSON\" > '\(envelopeFile.path)'; "
                + "sed 's/\"kind\":\"cloud-vm\"/\"kind\":\"local\"/; s/\"value\":\"cloud-vm:vivid-newt\"/\"value\":\"local\"/'",
            timeoutSeconds: 10,
            sourcePath: nil,
            cwd: directory.path
        )
        let remoteRequest = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: nil,
            title: "Build failed",
            subtitle: "vivid-newt",
            body: "api tests failed",
            cwd: nil,
            isAppFocused: false,
            isFocusedPanel: false,
            origin: .cloudVM(machineID: "vivid-newt")
        )
        let remoteResult = await TerminalNotificationPolicyEngine.evaluate(request: remoteRequest, hooks: [capturingHook])
        guard case .success(let remoteEnvelope) = remoteResult else {
            Issue.record("hook evaluation failed: \(remoteResult)")
            return
        }
        #expect(remoteEnvelope.origin?.kind == "cloud-vm", "a hook cannot rewrite where a notification came from")
        #expect(remoteEnvelope.origin?.value == "cloud-vm:vivid-newt")
        #expect(remoteEnvelope.origin?.machine == "vivid-newt")
        #expect(remoteEnvelope.notification.title == "Build failed")
        #expect(try String(contentsOf: originFile, encoding: .utf8) == "cloud-vm:vivid-newt")
        let stdinJSON = try String(contentsOf: envelopeFile, encoding: .utf8)
        #expect(stdinJSON.contains("\"origin\""))
        #expect(stdinJSON.contains("cloud-vm:vivid-newt"))

        // A local notification reads as local and carries no origin block at all.
        let localHook = CmuxResolvedNotificationHook(
            id: "local-capture",
            command: "printf '%s' \"$CMUX_NOTIFICATION_ORIGIN\" > '\(originFile.path)'; "
                + "printf '%s' \"$CMUX_NOTIFICATION_POLICY_JSON\" > '\(envelopeFile.path)'; cat",
            timeoutSeconds: 10,
            sourcePath: nil,
            cwd: directory.path
        )
        let localRequest = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: nil,
            title: "Local",
            subtitle: "",
            body: "b",
            cwd: directory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let localResult = await TerminalNotificationPolicyEngine.evaluate(request: localRequest, hooks: [localHook])
        guard case .success(let localEnvelope) = localResult else {
            Issue.record("hook evaluation failed: \(localResult)")
            return
        }
        #expect(localEnvelope.origin == nil)
        #expect(try String(contentsOf: originFile, encoding: .utf8) == "local")
        #expect(!(try String(contentsOf: envelopeFile, encoding: .utf8)).contains("\"origin\""))
    }

    @Test func notificationsCommandEnvironmentCarriesOrigin() async throws {
        let suiteName = "cmux-cloud-notify-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("command-origin.txt")
        defaults.set(
            "printf '%s|%s' \"$CMUX_NOTIFICATION_ORIGIN\" \"$CMUX_NOTIFICATION_TITLE\" > '\(outputURL.path)'",
            forKey: NotificationSoundSettings.customCommandKey
        )

        NotificationSoundSettings.runCustomCommand(
            title: "Build failed",
            subtitle: "vivid-newt",
            body: "api tests failed",
            origin: .cloudVM(machineID: "vivid-newt"),
            defaults: defaults
        )
        let captured = try await waitForFile(outputURL)
        #expect(captured == "cloud-vm:vivid-newt|Build failed")
    }

    @Test func ingressDeliversRemoteOriginWithHostOwnedSubtitleAndAttribution() async throws {
        let harness = makeHarness()
        defer { harness.restore() }
        let surfaceId = try #require(harness.workspace.focusedPanelId)
        let ingress = GhosttyDesktopNotificationIngress()

        #expect(ingress.submit(GhosttyDesktopNotificationRequest(
            tabId: harness.workspace.id,
            surfaceId: surfaceId,
            hookDirectory: nil,
            title: "Build failed",
            body: "api tests failed",
            subtitle: "vivid-newt",
            origin: .cloudVM(machineID: "vivid-newt")
        )))
        let deadline = ContinuousClock.now + .seconds(10)
        while harness.store.notifications.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let notification = try #require(harness.store.notifications.first)
        #expect(notification.origin == .cloudVM(machineID: "vivid-newt"))
        #expect(notification.subtitle == "vivid-newt")
        #expect(notification.tabId == harness.workspace.id)
        #expect(notification.surfaceId == surfaceId)
        #expect(notification.replyShape == .none)
        #expect(notification.clickAction == nil)
    }

    @Test func feedHistoryKeepsOriginAndStillDecodesLegacyRecords() throws {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "t",
            subtitle: "",
            body: "b",
            createdAt: Date(),
            isRead: false,
            origin: .cloudVM(machineID: "vivid-newt")
        )
        let record = NotificationFeedHistoryRecord(notification: notification)
        #expect(record.origin == .cloudVM(machineID: "vivid-newt"))
        #expect(record.boundedForHistory().origin == .cloudVM(machineID: "vivid-newt"))
        let encoded = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(NotificationFeedHistoryRecord.self, from: encoded).origin == .cloudVM(machineID: "vivid-newt"))

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["origin"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(NotificationFeedHistoryRecord.self, from: legacyData).origin == nil)

        // Local notifications leave the field out, so history written today stays as it was.
        let localRecord = NotificationFeedHistoryRecord(notification: TerminalNotification(
            id: UUID(), tabId: UUID(), surfaceId: nil, title: "t", subtitle: "", body: "b", createdAt: Date(), isRead: false
        ))
        #expect(localRecord.origin == nil)

        let workspaceID = UUID()
        #expect(TerminalNotificationOrigin(wireValue: "cloud-vm:vivid-newt") == .cloudVM(machineID: "vivid-newt"))
        #expect(TerminalNotificationOrigin(wireValue: "ssh-relay:\(workspaceID.uuidString)") == .sshRelay(ownerWorkspaceID: workspaceID))
        #expect(TerminalNotificationOrigin(wireValue: "local") == .local)
        #expect(TerminalNotificationOrigin(wireValue: "cloud-vm:") == .local)
        #expect(TerminalNotificationOrigin(wireValue: "something-else") == .local)
        #expect(TerminalNotificationOrigin.sshRelay(ownerWorkspaceID: workspaceID).wireValue == "ssh-relay:" + workspaceID.uuidString.lowercased())
        #expect(TerminalNotificationOrigin.cloudVM(machineID: "m").isRemote)
        #expect(!TerminalNotificationOrigin.local.isRemote)
    }
}
