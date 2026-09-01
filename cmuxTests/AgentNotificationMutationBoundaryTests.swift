import CmuxControlSocket
import CmuxCore
import CmuxSidebar
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
        workspace.registerReportedSurfaceTTYName("/dev/null", panelId: panelId)
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

    @Test("Restored TTY metadata requires a fresh runtime registration")
    func restoredTTYMetadataRequiresFreshRuntimeRegistration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionPanelSnapshot(
            id: panelId,
            type: .terminal,
            title: "Restored terminal",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: "/dev/null",
            terminal: SessionTerminalPanelSnapshot(),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )

        workspace.applySessionPanelMetadata(snapshot, toPanelId: panelId)

        #expect(workspace.surfaceTTYNames[panelId] == "/dev/null")
        #expect(
            workspace.localAgentDeliveryTTYDevices.isEmpty,
            "Persisted TTY metadata is not evidence from the current terminal runtime"
        )

        workspace.pruneSurfaceMetadata(validSurfaceIds: [panelId])
        #expect(
            workspace.localAgentDeliveryTTYDevices.isEmpty,
            "Metadata pruning must not promote a persisted TTY into live evidence"
        )

        workspace.registerReportedSurfaceTTYName("/dev/null", panelId: panelId)
        #expect(workspace.localAgentDeliveryTTYDevices.map(\.surfaceId) == [panelId])
    }

    @Test("Live PID routing and runtime mutations include a Dock-owned terminal")
    func liveTTYBindingsAndRuntimeMutationsIncludeDockOwnedTerminal() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.drainForTesting()
        }
        let dockOwnerId = UUID()
        let dock = DockSplitStore(workspaceId: dockOwnerId, baseDirectoryProvider: { nil })
        fixture.source.registerReportedSurfaceTTYName("/dev/null", panelId: fixture.panelId)
        fixture.source.setAgentLifecycle(
            key: "manual:workspace-loader",
            panelId: fixture.panelId,
            lifecycle: .running
        )

        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)
        #expect(fixture.source.localAgentDeliveryTTYDevices.allSatisfy { $0.surfaceId != fixture.panelId })

        let binding = try #require(
            fixture.appDelegate.liveAgentDeliveryTTYBindings().first {
                $0.workspaceId == dockOwnerId && $0.surfaceId == fixture.panelId
            }
        )
        #expect(binding.ttyDevice > 0)

        let sessionKey = "omp.dock-session"
        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(dockOwnerId),
            key: "omp",
            value: "Running",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil
        )
        TerminalController.shared.controlSidebarScheduleAgentPIDRecord(
            target: .workspace(dockOwnerId),
            key: sessionKey,
            pid: getpid(),
            panelID: fixture.panelId
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(dockOwnerId),
            key: "omp",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId
        )
        bus.drainForTesting()

        let runtime = try #require(dock.agentRuntimeByPanelId[fixture.panelId])
        #expect(runtime.statusEntries["omp"]?.value == "Running")
        #expect(runtime.agentPIDs[sessionKey] == getpid())
        #expect(runtime.agentLifecycleStates["omp"] == .running)
        #expect(runtime.agentLifecycleStates["manual:workspace-loader"] == nil)

        #expect(
            !dock.clearAgentPID(
                key: "omp.superseded",
                panelId: fixture.panelId,
                clearStatus: true,
                requireOwnedKey: true
            )
        )
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.statusEntries["omp"]?.value == "Running")
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentLifecycleStates["omp"] == .running)

        TerminalController.shared.controlSidebarScheduleStatusClear(
            target: .workspace(dockOwnerId),
            key: "omp",
            panelID: fixture.panelId
        )
        bus.drainForTesting()
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.statusEntries["omp"] == nil)
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentLifecycleStates["omp"] == nil)

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(dockOwnerId),
            key: "omp",
            value: "Running",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(dockOwnerId),
            key: "omp",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId
        )
        bus.drainForTesting()
        #expect(dock.agentRuntimeByPanelId[fixture.panelId]?.agentLifecycleStates["omp"] == .running)

        let workspaceTransfer = try #require(dock.detachSurface(panelId: fixture.panelId))
        #expect(dock.agentRuntimeByPanelId[fixture.panelId] == nil)
        let destinationPane = try #require(fixture.destination.bonsplitController.allPaneIds.first)
        #expect(
            fixture.destination.attachDetachedSurface(
                workspaceTransfer,
                inPane: destinationPane,
                focus: false
            ) == fixture.panelId
        )
        #expect(fixture.destination.statusEntries["omp"]?.value == "Running")
        #expect(fixture.destination.agentPIDs[sessionKey] == getpid())
        #expect(
            fixture.destination.agentLifecycleStatesByPanelId[fixture.panelId]?["omp"]
                == .running
        )

        // The socket target still names the old Dock owner. Panel ownership is
        // resolved when the queued mutation drains, so the clear follows the
        // panel into its destination workspace.
        TerminalController.shared.controlSidebarScheduleAgentPIDClear(
            target: .workspace(dockOwnerId),
            key: sessionKey,
            panelID: fixture.panelId,
            clearStatus: true
        )
        bus.drainForTesting()
        #expect(fixture.destination.statusEntries["omp"] == nil)
        #expect(fixture.destination.agentPIDs[sessionKey] == nil)
        #expect(
            fixture.destination.agentLifecycleStatesByPanelId[fixture.panelId]?["omp"]
                == nil
        )
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

    @Test("Correlation clear cancels only matching in-flight policy work")
    func correlationClearCancelsMatchingInFlightPolicyWork() async throws {
        let fixture = try makeFixture(policyHookCommand: "sleep 1; cat")
        defer { fixture.restore() }
        let correlationKey = "remote-host:\(UUID().uuidString)"

        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: nil,
            title: "Remote Proxy Unavailable",
            subtitle: "host",
            body: "Transient proxy failure",
            cooldownKey: correlationKey,
            cooldownInterval: 60
        )
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: nil,
            title: "Unrelated",
            subtitle: "",
            body: "Keep this notification"
        )

        fixture.store.clearNotifications(forTabId: fixture.source.id, correlationKey: correlationKey)
        await waitForNotification(in: fixture.store)

        #expect(fixture.store.notifications.map(\.body) == ["Keep this notification"])
    }

    @Test("Correlation clear preserves another workspace's same-host alert")
    func correlationClearIsScopedToWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let sourceCorrelationKey = "remote-host:\(UUID().uuidString)"
        let correlationKey = "remote-host:\(UUID().uuidString)"

        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: nil,
            title: "Remote Proxy Unavailable",
            subtitle: "source",
            body: "Recovered source alert",
            cooldownKey: sourceCorrelationKey,
            cooldownInterval: 60
        )
        fixture.store.clearNotifications(
            forTabId: fixture.source.id,
            correlationKey: sourceCorrelationKey
        )
        #expect(fixture.store.notifications.isEmpty)

        fixture.store.addNotification(
            tabId: fixture.destination.id,
            surfaceId: nil,
            title: "Remote Proxy Unavailable",
            subtitle: "host",
            body: "Same host in another workspace",
            cooldownKey: correlationKey,
            cooldownInterval: 60
        )
        fixture.store.clearNotifications(forTabId: fixture.source.id, correlationKey: correlationKey)

        #expect(fixture.store.notifications.map(\.body) == ["Same host in another workspace"])
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
            panelID: fixture.panelId,
            sessionID: "session-1",
            startsNewOccupant: false,
            expectedPIDKey: nil,
            expectedPID: nil
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
        #expect(
            fixture.destination.agentLifecycleRecordsByPanelId[fixture.panelId]?["claude_code"]?.sessionID
                == "session-1"
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

    @Test("Queued agent mutations revalidate the process generation at apply time")
    func staleProcessGenerationCannotMutateReplacementOccupantAfterQueueing() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        let olderProcess = Process()
        olderProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        olderProcess.arguments = ["30"]
        let newerProcess = Process()
        newerProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        newerProcess.arguments = ["30"]
        try olderProcess.run()
        try newerProcess.run()
        defer {
            for process in [olderProcess, newerProcess] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let olderIdentity = try #require(
            AgentPIDProcessIdentity(pid: olderProcess.processIdentifier)
        )
        let newerIdentity = try #require(
            AgentPIDProcessIdentity(pid: newerProcess.processIdentifier)
        )
        try #require(olderIdentity.startedBefore(newerIdentity))
        let olderPIDKey = "kiro.older"
        let newerPIDKey = "kiro.newer"

        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .running,
            expectedPIDKey: olderPIDKey,
            expectedPID: olderProcess.processIdentifier,
            expectedPIDStartSeconds: olderIdentity.startSeconds,
            expectedPIDStartMicroseconds: olderIdentity.startMicroseconds
        )
        let staleGuard = ControlSidebarAgentMutationGuard.process(
            statusKey: "kiro",
            pidKey: olderPIDKey,
            pid: olderProcess.processIdentifier,
            startSeconds: olderIdentity.startSeconds,
            startMicroseconds: olderIdentity.startMicroseconds
        )
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Kiro",
            subtitle: "Current",
            body: "Keep replacement notification"
        )

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "kiro",
            value: "Stale status",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil,
            agentMutationGuard: staleGuard
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Kiro",
            subtitle: "Stale",
            body: "Drop stale queued notification",
            coalesces: false,
            agentMutationGuard: staleGuard
        )
        TerminalController.shared.controlSidebarScheduleGuardedNotificationClear(
            target: .workspace(fixture.source.id),
            panelID: fixture.panelId,
            guardValue: staleGuard
        )

        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .idle,
            expectedPIDKey: newerPIDKey,
            expectedPID: newerProcess.processIdentifier,
            expectedPIDStartSeconds: newerIdentity.startSeconds,
            expectedPIDStartMicroseconds: newerIdentity.startMicroseconds
        )
        fixture.source.statusEntries["kiro"] = SidebarStatusEntry(
            key: "kiro",
            value: "Replacement status"
        )

        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["kiro"]?.value == "Replacement status")
        #expect(fixture.store.notifications.map(\.body) == ["Keep replacement notification"])
    }

    @Test("Recorded process ownership remains valid after the agent exits")
    func recordedProcessGenerationAuthorizesDeferredMutationsAfterExit() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let identity = try #require(AgentPIDProcessIdentity(pid: process.processIdentifier))
        let pidKey = "kiro.current"
        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .running,
            expectedPIDKey: pidKey,
            expectedPID: process.processIdentifier,
            expectedPIDStartSeconds: identity.startSeconds,
            expectedPIDStartMicroseconds: identity.startMicroseconds
        )
        let guardValue = ControlSidebarAgentMutationGuard.process(
            statusKey: "kiro",
            pidKey: pidKey,
            pid: process.processIdentifier,
            startSeconds: identity.startSeconds,
            startMicroseconds: identity.startMicroseconds
        )

        process.terminate()
        process.waitUntilExit()
        _ = fixture.source.clearAgentLifecycle(key: "kiro", panelId: fixture.panelId)
        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .idle,
            expectedPIDKey: pidKey,
            expectedPID: process.processIdentifier,
            expectedPIDStartSeconds: identity.startSeconds,
            expectedPIDStartMicroseconds: identity.startMicroseconds
        )
        #expect(
            fixture.source.agentLifecycleRecordsByPanelId[fixture.panelId]?["kiro"]?.state
                == .idle
        )

        bus.setDrainsSuspendedForTesting(true)
        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "kiro",
            value: "Completed",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil,
            agentMutationGuard: guardValue
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Kiro",
            subtitle: "Completed",
            body: "Deliver after process exit",
            coalesces: false,
            agentMutationGuard: guardValue
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["kiro"]?.value == "Completed")
        #expect(fixture.store.notifications.map(\.body) == ["Deliver after process exit"])

        bus.setDrainsSuspendedForTesting(true)
        TerminalController.shared.controlSidebarScheduleGuardedNotificationClear(
            target: .workspace(fixture.source.id),
            panelID: fixture.panelId,
            guardValue: guardValue
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()
        #expect(fixture.store.notifications.isEmpty)
    }

    @Test("Agent guards use structured metadata without consuming legacy payload text")
    func agentNotificationGuardFramingPreservesLegacyPayloadText() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer { bus.discardPendingNotifications() }

        let response = TerminalController.debugNotifyTargetQueuedResponseForTesting(
            "\(fixture.source.id.uuidString) \(fixture.panelId.uuidString) "
                + "Legacy|Payload|Body --agent-guard --expected-agent-key=kiro remains payload text"
        )
        #expect(response == "OK")
        bus.drainForTesting()

        #expect(fixture.store.notifications.map(\.body) == [
            "Body --agent-guard --expected-agent-key=kiro remains payload text",
        ])

        let pid = getpid()
        let identity = try #require(AgentPIDProcessIdentity(pid: pid))
        let pidKey = "kiro.current"
        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .running,
            expectedPIDKey: pidKey,
            expectedPID: pid,
            expectedPIDStartSeconds: identity.startSeconds,
            expectedPIDStartMicroseconds: identity.startMicroseconds
        )
        let guardValue = ControlSidebarAgentMutationGuard.process(
            statusKey: "kiro",
            pidKey: pidKey,
            pid: pid,
            startSeconds: identity.startSeconds,
            startMicroseconds: identity.startMicroseconds
        )
        let guardedResponse = TerminalController.debugNotifyTargetQueuedResponseForTesting(
            "\(fixture.source.id.uuidString) \(fixture.panelId.uuidString) "
                + "Kiro|Current|Guarded delivery|g=\(guardValue.socketEnvelope)"
        )
        #expect(guardedResponse == "OK")
        let legacyOptionTextResponse = TerminalController.debugNotifyTargetQueuedResponseForTesting(
            "\(fixture.source.id.uuidString) \(fixture.panelId.uuidString) "
                + "Kiro|Legacy|Keep partial --agent-guard --expected-agent-key=kiro"
        )
        #expect(legacyOptionTextResponse == "OK")
        bus.drainForTesting()

        #expect(Set(fixture.store.notifications.map(\.body)) == Set([
            "Body --agent-guard --expected-agent-key=kiro remains payload text",
            "Guarded delivery",
            "Keep partial --agent-guard --expected-agent-key=kiro",
        ]))
    }

    @Test("Guarded clear command forwards a complete session guard and rejects a partial one")
    func clearNotificationsParsesAgentMutationGuard() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer { bus.discardPendingNotifications() }
        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .running,
            sessionID: "session-1",
            startsNewOccupant: true
        )
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Kiro",
            subtitle: "Current",
            body: "Clear with complete guard"
        )

        let response = TerminalController.shared.handleSocketLine(
            "clear_notifications --tab=\(fixture.source.id.uuidString) "
                + "--panel=\(fixture.panelId.uuidString) --expected-agent-key=kiro "
                + "--expected-agent-session-id=session-1"
        )
        #expect(response == "OK")
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Kiro",
            subtitle: "Current",
            body: "Queued after guarded clear",
            coalesces: false
        )
        bus.drainForTesting()
        #expect(fixture.store.notifications.map(\.body) == ["Queued after guarded clear"])

        fixture.store.replaceNotificationsForTesting([])
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Kiro",
            subtitle: "Current",
            body: "Keep after partial guard"
        )
        let partialResponse = TerminalController.shared.handleSocketLine(
            "clear_notifications --tab=\(fixture.source.id.uuidString) "
                + "--panel=\(fixture.panelId.uuidString) --expected-agent-key=kiro"
        )
        #expect(partialResponse.hasPrefix("ERROR: Usage:"))
        bus.drainForTesting()
        #expect(fixture.store.notifications.map(\.body) == ["Keep after partial guard"])
    }

    @Test("Policy-delayed notifications revalidate agent ownership before final apply")
    func policyDelayedNotificationCannotApplyToReplacementOccupant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-agent-guard-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ready = root.appendingPathComponent("ready")
        let proceed = root.appendingPathComponent("proceed")
        let finished = root.appendingPathComponent("finished")
        let command = "touch '\(ready.path)'; while [ ! -e '\(proceed.path)' ]; do sleep 0.05; done; cat; touch '\(finished.path)'"
        let fixture = try makeFixture(
            policyHookCommand: command,
            policyHookTimeoutSeconds: 60
        )
        defer {
            fixture.restore()
            try? FileManager.default.removeItem(at: root)
        }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer { bus.discardPendingNotifications() }

        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .running,
            sessionID: "session-old",
            startsNewOccupant: true
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Kiro",
            subtitle: "Waiting",
            body: "Drop after occupant replacement",
            coalesces: false,
            agentMutationGuard: .session(
                statusKey: "kiro",
                sessionID: "session-old"
            )
        )
        bus.drainForTesting()
        #expect(await waitForMarker(at: ready))

        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .running,
            sessionID: "session-new",
            startsNewOccupant: true
        )
        _ = FileManager.default.createFile(atPath: proceed.path, contents: nil)
        #expect(await waitForMarker(at: finished))

        let deadline = ContinuousClock.now + .seconds(15)
        while fixture.store.hasPendingNotification(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        ), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(
            !fixture.store.hasPendingNotification(
                forTabId: fixture.source.id,
                surfaceId: fixture.panelId
            )
        )
        #expect(fixture.store.notifications.isEmpty)
    }

    @Test("A guarded Dock mutation follows its authoritative session back into a Workspace")
    func guardedDockMutationSurvivesMoveBackToWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        let sessionID = "session-dock"
        let pidKey = "kiro.\(sessionID)"
        fixture.source.recordAgentPID(
            key: pidKey,
            pid: getpid(),
            panelId: fixture.panelId,
            refreshPorts: false
        )
        fixture.source.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .running,
            sessionID: sessionID,
            startsNewOccupant: true
        )
        let intoDock = try #require(
            fixture.source.detachSurface(panelId: fixture.panelId)
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPaneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(
            dock.attachDetachedSurface(intoDock, inPane: dockPaneID, focus: false)
        )
        dock.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.panelId,
            lifecycle: .idle,
            sessionID: sessionID
        )

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(dock.workspaceId),
            key: "kiro",
            value: "Completed in Dock",
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil,
            agentMutationGuard: .session(
                statusKey: "kiro",
                sessionID: sessionID
            )
        )

        let outOfDock = try #require(
            dock.detachSurface(panelId: fixture.panelId)
        )
        let destinationPaneID = try #require(
            fixture.destination.bonsplitController.allPaneIds.first
        )
        try #require(
            fixture.destination.attachDetachedSurface(
                outOfDock,
                inPane: destinationPaneID,
                focus: false
            )
        )

        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(
            fixture.destination.agentLifecycleRecordsByPanelId[fixture.panelId]?["kiro"]?
                .sessionID == sessionID
        )
        #expect(
            fixture.destination.agentLifecycleRecordsByPanelId[fixture.panelId]?["kiro"]?
                .state == .idle
        )
        #expect(fixture.destination.statusEntries["kiro"]?.value == "Completed in Dock")
    }
}
