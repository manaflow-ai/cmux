import CmuxControlSocket
import CmuxCore
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    // Generous for loaded CI runners: subprocess spawn, signal propagation,
    // and marker writes can take multiple seconds there. A long timeout only
    // slows the failure path.
    func waitForMarker(at url: URL, timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @Test("PID routing bypasses a stale negative telemetry cache after exec")
    func pidResolutionBypassesStaleNegativeTelemetryCacheAfterExec() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-live-pid-exec-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let initialScript = root.appendingPathComponent("initial.sh")
        let scopedScript = root.appendingPathComponent("scoped.sh")
        let readyMarker = root.appendingPathComponent("ready")
        let execMarker = root.appendingPathComponent("execed")
        try """
        touch '\(readyMarker.path)'
        trap 'exec /bin/sh "\(scopedScript.path)"' USR1
        while :; do sleep 1; done
        """.write(to: initialScript, atomically: true, encoding: .utf8)
        try """
        export CMUX_SURFACE_ID='\(fixture.panelId.uuidString)'
        exec /bin/sh -c 'touch "\(execMarker.path)"; exec sleep 30'
        """.write(to: scopedScript, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [initialScript.path]
        var environment = ProcessInfo.processInfo.environment
        ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID"].forEach {
            environment.removeValue(forKey: $0)
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: root)
        }
        #expect(await waitForMarker(at: readyMarker))

        let identity = try #require(agentLiveProcessIdentity(pid: process.processIdentifier))
        let cachedMiss = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: Int(process.processIdentifier),
            cacheKey: identity.scopeCacheKey,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        #expect(cachedMiss == nil)
        #expect(Darwin.kill(process.processIdentifier, SIGUSR1) == 0)
        #expect(await waitForMarker(at: execMarker))

        #expect(
            fixture.appDelegate.liveAgentDeliveryTarget(forAgentPID: process.processIdentifier)
                == AgentDeliveryTargetCandidate(
                    workspaceId: fixture.source.id,
                    surfaceId: fixture.panelId
                )
        )
    }

    @Test("Local PID routing excludes remote TTY device namespaces")
    func localTTYBindingsExcludeRemoteDeviceNamespaces() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.surfaceTTYNames[panelId] = "/dev/null"
        #expect(workspace.localAgentDeliveryTTYDevices.map(\.surfaceId) == [panelId])

        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        #expect(workspace.localAgentDeliveryTTYDevices.isEmpty)
    }

    @Test("A stale source clear preserves a destination-confined stored notification")
    func staleSourceClearPreservesDestinationConfinedStoredNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        try movePanel(fixture)

        fixture.store.addNotification(
            tabId: fixture.destination.id,
            surfaceId: fixture.panelId,
            title: "Relay",
            subtitle: "Completed",
            body: "Authorized only for destination",
            retargetsToLiveSurfaceOwner: false
        )

        fixture.store.clearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        )

        let recorded = fixture.store.notifications.filter {
            $0.body == "Authorized only for destination"
        }
        #expect(recorded.map(\.tabId) == [fixture.destination.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
        #expect(recorded.first?.retargetsToLiveSurfaceOwner == false)
    }

    @Test("A queued workspace clear lets a moved surface notification drain first")
    func queuedWorkspaceClearPreservesNotificationMovedToAnotherWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Queued before move and clear"
        )
        try movePanel(fixture)
        bus.enqueueClearNotifications(forTabId: fixture.source.id)

        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        let recorded = fixture.store.notifications.filter {
            $0.body == "Queued before move and clear"
        }
        #expect(recorded.map(\.tabId) == [fixture.destination.id])
        #expect(recorded.first?.surfaceId == fixture.panelId)
    }

    @Test("A queued clear preserves policy work registered after its barrier")
    func queuedClearPreservesNewerInFlightPolicyDelivery() async throws {
        let fixture = try makeFixture(policyHookCommand: "cat")
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        bus.enqueueClearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        )
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Registered after clear"
        )

        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()
        await waitForNotification(in: fixture.store)

        #expect(fixture.store.notifications.map(\.body) == ["Registered after clear"])
    }

    @Test("Clearing policy work immediately releases its cooldown reservation")
    func clearReleasesInFlightPolicyCooldownForReplacement() async throws {
        let fixture = try makeFixture(policyHookCommand: "sleep 1; cat")
        defer { fixture.restore() }
        let cooldownKey = "replace-after-clear-\(UUID().uuidString)"

        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Discarded in flight",
            cooldownKey: cooldownKey,
            cooldownInterval: 60
        )
        fixture.store.clearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        )
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Replacement after clear",
            cooldownKey: cooldownKey,
            cooldownInterval: 60
        )

        await waitForNotification(in: fixture.store)
        #expect(fixture.store.notifications.map(\.body) == ["Replacement after clear"])
    }

    @Test("Clearing policy work discards a hook result that completes afterwards")
    func clearTerminatesInFlightPolicyHookProcess() async throws {
        // Subprocess termination on cancellation is best-effort and is NOT
        // asserted: signal delivery through the xctest harness is not
        // reliable on CI runners. The guaranteed, user-visible contract is
        // that a cleared in-flight request's result is discarded — the hook
        // here is gated on a marker so it completes strictly AFTER the clear,
        // and its late result must not record a notification or unread ring.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-policy-cancel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidURL = root.appendingPathComponent("pid")
        let proceedURL = root.appendingPathComponent("proceed")
        let command = "printf '%s' $$ > '\(pidURL.path)'; while [ ! -e '\(proceedURL.path)' ]; do sleep 0.1; done; cat"
        let fixture = try makeFixture(
            policyHookCommand: command,
            policyHookTimeoutSeconds: 60
        )
        defer {
            fixture.restore()
            if let rawPID = try? String(contentsOf: pidURL, encoding: .utf8),
               let pid = pid_t(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                _ = Darwin.kill(-pid, SIGKILL)
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }

        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Cancel this hook"
        )
        #expect(await waitForMarker(at: pidURL))

        fixture.store.clearNotifications(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        )
        FileManager.default.createFile(atPath: proceedURL.path, contents: nil)

        // Wait for the hook subprocess to finish (it exits promptly once the
        // proceed marker exists, or immediately if cancellation did
        // terminate it), then give the completion path time to run.
        if let rawPID = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = pid_t(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let deadline = ContinuousClock.now + .seconds(15)
            while Darwin.kill(pid, 0) == 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<100 { await Task.yield() }

        #expect(
            fixture.store.notifications.isEmpty,
            "A cleared in-flight request's late hook result must be discarded"
        )
        #expect(
            !fixture.store.hasUnreadNotification(forTabId: fixture.source.id, surfaceId: fixture.panelId)
        )
    }

    @Test("Agent runtime mutations follow a pane that moves before queue drain")
    func queuedAgentRuntimeMutationsResolveLivePanelOwner() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: 43_210
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId
        )

        try movePanel(fixture)
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"] == nil)
        #expect(fixture.destination.statusEntries["claude_code"]?.value == "Running")
        #expect(fixture.destination.agentPIDs["claude_code"] == 43_210)
        #expect(
            fixture.destination.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == .running
        )
    }

    @Test("An authorized-workspace clear cancels a confined in-flight relay delivery")
    func authorizedWorkspaceClearCancelsConfinedInFlightRelayDelivery() async throws {
        let fixture = try makeFixture(policyHookCommand: "cat")
        defer { fixture.restore() }

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
            body: "Must be cancelled by its authorized workspace clear"
        )
        guard case .delivered = result else {
            Issue.record("Expected relay-target delivery, got \(result)")
            return
        }

        try movePanel(fixture)
        // A confined request does not follow its surface — its delivery
        // identity stays the authorized workspace — so clearing that
        // workspace tab-wide must cancel it even though the request carries
        // a surfaceId.
        fixture.store.clearNotifications(forTabId: fixture.source.id)

        for _ in 0..<200 { await Task.yield() }
        let recorded = fixture.store.notifications.filter { $0.title == "Relay" }
        #expect(
            recorded.isEmpty,
            "A confined in-flight delivery must be cancelled by clearing its authorized workspace; saw \(recorded.map(\.tabId))"
        )
    }
}
