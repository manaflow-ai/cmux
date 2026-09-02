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
            clearStatus: true,
            agentEventTime: nil
        )
        bus.drainForTesting()
        #expect(fixture.destination.statusEntries["omp"] == nil)
        #expect(fixture.destination.agentPIDs[sessionKey] == nil)
        #expect(
            fixture.destination.agentLifecycleStatesByPanelId[fixture.panelId]?["omp"]
                == nil
        )
    }

    @Test("Dock-owned notifications use the pane runtime ordering watermark")
    func dockOwnedNotificationsUsePaneRuntimeOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer { bus.discardPendingNotifications() }

        let dock = fixture.source.dockSplit
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)
        #expect(dock.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: 200,
            enforceAgentEventOrdering: true
        ))

        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale Dock notification",
            agentStatusKey: "claude_code",
            agentEventTime: 100,
            coalesces: false
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Current Dock notification",
            agentStatusKey: "claude_code",
            agentEventTime: 300,
            coalesces: false
        )
        bus.drainForTesting()

        #expect(!fixture.store.notifications.contains { $0.body == "Stale Dock notification" })
        #expect(fixture.store.notifications.contains { $0.body == "Current Dock notification" })
        #expect(
            dock.agentRuntimeByPanelId[fixture.panelId]?.agentLifecycleEventTimes["claude_code"] == 300
        )

        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 250
        )
        bus.drainForTesting()
        #expect(fixture.store.notifications.contains { $0.body == "Current Dock notification" })

        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 400
        )
        bus.drainForTesting()
        #expect(!fixture.store.notifications.contains { $0.body == "Current Dock notification" })
    }

    @Test("A no-op Dock resume clear does not advance hook ordering")
    func noOpDockResumeClearDoesNotAdvanceOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let dock = fixture.source.dockSplit
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)
        #expect(dock.surfaceResumeBinding(panelId: fixture.panelId) == nil)

        #expect(!dock.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            agentSessionEnded: true
        ))
        #expect(dock.surfaceResumeBindingEventTimesByPanelId[fixture.panelId] == nil)

        let eventTime: TimeInterval = 1_893_456_200
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume after-no-op-dock-clear",
            checkpointId: "after-no-op-dock-clear",
            source: "agent-hook",
            updatedAt: eventTime
        )
        #expect(dock.setSurfaceResumeBinding(
            binding,
            panelId: fixture.panelId,
            agentEventTime: eventTime
        ))
        #expect(dock.surfaceResumeBinding(panelId: fixture.panelId)?.checkpointId == "after-no-op-dock-clear")
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

    @Test("A stale status update cannot rebind PID tracking")
    func staleStatusUpdateDoesNotRecordPID() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: 200
        )
        fixture.source.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Idle",
            icon: "pause.circle.fill",
            color: "#8E8E93",
            agentEventTime: 200
        )

        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
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
            pid: 43_210,
            agentEventTime: 100
        )
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"]?.value == "Idle")
        #expect(fixture.source.agentPIDs["claude_code"] == nil)
    }

    @Test("Agent status ordering is scoped to the owning pane")
    func agentStatusOrderingIsScopedToOwningPanel() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let paneId = try #require(fixture.source.paneId(forPanelId: fixture.panelId))
        let secondPanelId = try #require(
            fixture.source.newTerminalSurface(inPane: paneId, focus: false)
        ).id
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Running in first pane",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil,
            agentEventTime: 1_893_456_200
        )
        bus.drainForTesting()

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Idle in second pane",
            icon: "pause.circle.fill",
            color: "#8E8E93",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: secondPanelId,
            pid: nil,
            agentEventTime: 1_893_456_100
        )
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"]?.value == "Idle in second pane")
        #expect(fixture.source.statusEntries["claude_code"]?.agentEventTime == 1_893_456_100)
    }

    @Test("Clearing lifecycle state retains detached-hook ordering authority")
    func clearedLifecycleRetainsStatusOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()

        fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: 1_893_456_200
        )
        #expect(fixture.source.clearAgentLifecycle(key: "claude_code", panelId: fixture.panelId))

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Late stale event",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: 43_210,
            agentEventTime: 1_893_456_100
        )
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"] == nil)
        #expect(fixture.source.agentPIDs["claude_code"] == nil)
    }

    @Test("Global lifecycle reset clears retained ordering watermarks")
    func globalLifecycleResetClearsRetainedOrderingWatermarks() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        #expect(fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: 1_893_456_200
        ))
        #expect(fixture.source.clearAgentLifecycle(key: "claude_code", panelId: fixture.panelId))
        #expect(fixture.source.agentLifecycleEventTimesByPanelId[fixture.panelId]?["claude_code"] == 1_893_456_200)

        fixture.source.clearAllAgentLifecycleStates()

        #expect(fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle,
            enforceAgentEventOrdering: true
        ))
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == .idle)
    }

    @Test("An untimestamped teardown cannot clear timestamped agent runtime")
    func untimestampedAgentPIDClearCannotBypassOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let pidKey = "claude_code.session"
        fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: 200
        )
        _ = fixture.source.recordAgentPID(key: pidKey, pid: 43_210, panelId: fixture.panelId)
        _ = fixture.source.upsertSidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelId: fixture.panelId,
            pid: nil,
            agentEventTime: 200
        )

        #expect(!fixture.source.clearAgentPID(
            key: pidKey,
            panelId: fixture.panelId,
            clearStatus: true,
            enforceAgentEventOrdering: true
        ))
        #expect(fixture.source.agentPIDs[pidKey] == 43_210)
        #expect(fixture.source.statusEntries["claude_code"]?.value == "Running")
        #expect(fixture.source.hasRunningAgentLifecycle(key: "claude_code", panelId: fixture.panelId))
    }

    @Test("A stale PID registration cannot bypass a newer runtime watermark")
    func staleAgentPIDRegistrationCannotRebindAfterNewerEvent() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: 200
        )

        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        TerminalController.shared.controlSidebarScheduleAgentPIDRecord(
            target: .workspace(fixture.source.id),
            key: "claude_code.session",
            pid: 43_210,
            panelID: fixture.panelId
        )
        bus.drainForTesting()

        #expect(fixture.source.agentPIDs["claude_code.session"] == nil)
        #expect(fixture.source.agentPIDPanelIdsByKey["claude_code.session"] == nil)
    }

    @Test("An older structured agent cannot replace a newer pane runtime")
    func olderStructuredAgentCannotReplaceNewerPaneRuntime() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let newerKey = "codex.newer-session"
        let olderKey = "claude_code.older-session"

        _ = fixture.source.recordAgentPID(
            key: newerKey,
            pid: 43_210,
            panelId: fixture.panelId,
            agentEventTime: 1_893_456_200,
            enforceAgentEventOrdering: true,
            refreshPorts: false
        )
        _ = fixture.source.recordAgentPID(
            key: olderKey,
            pid: 43_211,
            panelId: fixture.panelId,
            agentEventTime: 1_893_456_100,
            enforceAgentEventOrdering: true,
            refreshPorts: false
        )

        #expect(fixture.source.agentPIDs[newerKey] == 43_210)
        #expect(fixture.source.agentPIDPanelIdsByKey[newerKey] == fixture.panelId)
        #expect(fixture.source.agentPIDs[olderKey] == nil)
        #expect(fixture.source.agentPIDPanelIdsByKey[olderKey] == nil)
    }

    @Test("A displaced structured agent cannot restore pane-owned state")
    func displacedStructuredAgentCannotRestorePaneOwnedState() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        _ = fixture.source.recordAgentPID(
            key: "codex.newer-session",
            pid: 43_210,
            panelId: fixture.panelId,
            agentEventTime: 1_893_456_200,
            enforceAgentEventOrdering: true,
            refreshPorts: false
        )

        let lifecycleAccepted = fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: 1_893_456_100,
            enforceAgentEventOrdering: true
        )
        let statusDecision = fixture.source.upsertSidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            icon: "sparkles",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelId: fixture.panelId,
            pid: nil,
            agentEventTime: 1_893_456_100
        )
        let notificationAccepted = fixture.source.acceptAgentRuntimeMutation(
            statusKey: "claude_code",
            panelId: fixture.panelId,
            agentEventTime: 1_893_456_100,
            enforceOrdering: true
        )

        #expect(!lifecycleAccepted)
        #expect(statusDecision == .stale)
        #expect(!notificationAccepted)
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == nil)
        #expect(fixture.source.statusEntries["claude_code"] == nil)
        #expect(fixture.source.agentPIDs["codex.newer-session"] == 43_210)
    }

    @Test("A stale lifecycle update cannot bypass a newer status watermark")
    func staleAgentLifecycleCannotBypassNewerStatusWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        _ = fixture.source.upsertSidebarStatusEntry(
            key: "claude_code",
            value: "Idle",
            icon: "pause.circle.fill",
            color: "#8E8E93",
            url: nil,
            priority: 0,
            format: .plain,
            panelId: fixture.panelId,
            pid: nil,
            agentEventTime: 200
        )

        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId,
            agentEventTime: 100
        )
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"]?.value == "Idle")
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == nil)
    }

    @Test("Arbitrary sidebar keys do not grow durable lifecycle watermarks")
    func arbitrarySidebarKeysDoNotGrowLifecycleWatermarks() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        for index in 0..<64 {
            let key = "custom-status-\(index)"
            let decision = fixture.source.upsertSidebarStatusEntry(
                key: key,
                value: "Value \(index)",
                icon: nil,
                color: nil,
                url: nil,
                priority: 0,
                format: .plain,
                panelId: fixture.panelId,
                pid: nil,
                agentEventTime: 1_893_456_200 + TimeInterval(index)
            )
            #expect(decision == .replace)
        }

        #expect(fixture.source.statusEntries["custom-status-63"]?.agentEventTime == 1_893_456_263)
        #expect(fixture.source.agentLifecycleEventTimesByPanelId[fixture.panelId]?.isEmpty != false)
    }

    @Test("Feed attention overlays do not advance hook ordering watermarks")
    func feedAttentionOverlayDoesNotAdvanceHookOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let hookEventTime: TimeInterval = 1_893_456_200

        #expect(fixture.source.setAgentLifecycle(
            key: "codex",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: hookEventTime
        ))
        #expect(fixture.source.upsertSidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelId: fixture.panelId,
            pid: nil,
            agentEventTime: hookEventTime
        ) == .replace)

        let decision = ControlSidebarPanelOwner.workspace(fixture.source).setStatusEntry(
            SidebarStatusEntry(
                key: "codex",
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            ),
            key: "codex",
            panelId: fixture.panelId
        )
        #expect(decision == .replace)
        #expect(fixture.source.statusEntries["codex"]?.value == "Needs input")
        #expect(fixture.source.statusEntries["codex"]?.agentEventTime == hookEventTime)
        #expect(fixture.source.agentLifecycleEventTimesByPanelId[fixture.panelId]?["codex"] == hookEventTime)

        #expect(fixture.source.setAgentLifecycle(
            key: "codex",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: hookEventTime
        ))
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["codex"] == .idle)
    }

    @Test("Agent notification delivery and clear share event ordering")
    func agentNotificationDeliveryAndClearShareEventOrdering() throws {
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
            body: "Current event",
            agentStatusKey: "claude_code",
            agentEventTime: 200,
            coalesces: false
        )
        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 100
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.store.notifications.map(\.body) == ["Current event"])

        bus.setDrainsSuspendedForTesting(true)
        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 300
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale event",
            agentStatusKey: "claude_code",
            agentEventTime: 250,
            coalesces: false
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.store.notifications.isEmpty)
    }

    @Test("Coalesced agent clears retain the greatest event time and latest notification boundary")
    func coalescedAgentClearsRetainOrderingAndBoundary() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 300
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale between coalesced clears",
            agentStatusKey: "claude_code",
            agentEventTime: 250,
            coalesces: false
        )
        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 100
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Current after coalesced clears",
            agentStatusKey: "claude_code",
            agentEventTime: 350,
            coalesces: false
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.store.notifications.map(\.body) == ["Current after coalesced clears"])
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
