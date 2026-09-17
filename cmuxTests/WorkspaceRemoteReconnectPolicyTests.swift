import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5734:
// the SSH remote auto-reconnect loop must stop retrying once the host stays
// unreachable, instead of retrying indefinitely, so the user controls when
// reconnection happens.
@Suite("Workspace remote reconnect policy")
struct WorkspaceRemoteReconnectPolicyTests {
    private func evaluate(
        _ outcome: WorkspaceRemoteHostProbeOutcome,
        previous: Int
    ) -> WorkspaceRemoteReconnectPolicy.Evaluation {
        WorkspaceRemoteReconnectPolicy.evaluate(
            outcome: outcome,
            previousConsecutiveUnreachableProbes: previous
        )
    }

    @Test("Reachable host keeps the existing backoff retry loop")
    func reachableHostKeepsRetrying() {
        for previous in [0, 1, WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes] {
            let evaluation = evaluate(.reachable, previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == 0)
        }
    }

    @Test("Indeterminate probes keep retrying and reset the unreachable streak")
    func indeterminateProbeKeepsRetrying() {
        for previous in [0, 1, WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes] {
            let evaluation = evaluate(.indeterminate, previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == 0)
        }
    }

    @Test("Unreachable probes below the threshold keep retrying")
    func unreachableBelowThresholdKeepsRetrying() {
        for previous in 0..<(WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes - 1) {
            let evaluation = evaluate(.unreachable(reason: "connection refused"), previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == previous + 1)
        }
    }

    @Test("Reconnect loop suspends once the host stays unreachable")
    func suspendsAtUnreachableThreshold() {
        var streak = 0
        var decisions: [WorkspaceRemoteReconnectPolicy.Decision] = []
        for _ in 0..<WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes {
            let evaluation = evaluate(.unreachable(reason: "host timed out"), previous: streak)
            streak = evaluation.consecutiveUnreachableProbes
            decisions.append(evaluation.decision)
        }
        #expect(
            decisions.last == .suspend,
            "The auto-reconnect loop must suspend after \(WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes) consecutive unreachable probes instead of retrying indefinitely."
        )
        #expect(streak == WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes)
    }

    @Test("Suspension persists for further unreachable probes past the threshold")
    func staysSuspendedPastThreshold() {
        let evaluation = evaluate(
            .unreachable(reason: "no route to host"),
            previous: WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes
        )
        #expect(evaluation.decision == .suspend)
    }

    @Test("A reachable probe in between resets the unreachable streak")
    func reachableProbeResetsStreak() {
        var streak = 0
        var sawSuspend = false
        let outcomes: [WorkspaceRemoteHostProbeOutcome] = [
            .unreachable(reason: "timeout"),
            .unreachable(reason: "timeout"),
            .reachable,
            .unreachable(reason: "timeout"),
            .unreachable(reason: "timeout"),
        ]
        for outcome in outcomes {
            let evaluation = evaluate(outcome, previous: streak)
            streak = evaluation.consecutiveUnreachableProbes
            if evaluation.decision == .suspend {
                sawSuspend = true
            }
        }
        #expect(!sawSuspend, "Streaks interrupted by a reachable probe must not suspend the loop.")
        #expect(streak == 2)

        let third = evaluate(.unreachable(reason: "timeout"), previous: streak)
        #expect(
            third.decision == .suspend,
            "Once the streak reaches the threshold again the loop must suspend."
        )
    }
}

@Suite("Cloud terminal reconnect overlay policy")
struct CloudTerminalReconnectOverlayPolicyTests {
    @Test @MainActor
    func connectedLegacyCloudSurfaceSuppressesWorkspaceReconnectCard() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cloud VM",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_015,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            managedCloudVMID: "machine",
            terminalStartupCommand: "cmux vm ssh-attach --id machine"
        )
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        #expect(workspace.markRemoteTerminalSessionConnected(
            surfaceId: panel.id,
            relayPort: configuration.relayPort
        ))
        workspace.remoteConnectionState = .reconnecting

        #expect(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panel.id) == nil)
    }

    @Test @MainActor
    func nativeCloudAttachmentOwnsPresentationWhenCatalogProjectionIsMissing() throws {
        let workspace = Workspace()
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: "machine",
            isBase: false
        )
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelID] as? TerminalPanel)
        let status = CloudTerminalAttachmentStatus(machineID: "machine")
        panel.cloudAttachment = status
        workspace.remoteConnectionState = .reconnecting
        workspace.remoteConnectionDetail = nil
        #expect(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panelID) == nil)

        let nativePresentation = try #require(
            CloudTerminalReconnectOverlayPolicy.presentation(
                isManagedCloudWorkspace: true,
                isRemoteTerminalSurface: true,
                connectionState: .disconnected,
                detail: "the terminal attachment ended"
            )
        )
        status.update(
            .reconnecting(attempt: 2, reason: .transportClosed),
            presentation: nativePresentation
        )

        #expect(
            workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: panelID) == nativePresentation
        )
    }

    @Test("Cloud terminal surfaces show reconnect UI when disconnected")
    func cloudTerminalShowsReconnectWhenDisconnected() {
        let presentation = CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true,
            isRemoteTerminalSurface: true,
            connectionState: .disconnected,
            detail: nil
        )

        #expect(presentation?.showsReconnectButton == true)
        #expect(presentation?.showsProgress == false)
    }

    @Test("Cloud terminal surfaces stay quiet while reconnecting")
    func cloudTerminalStaysQuietWhileReconnecting() {
        let presentation = CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true,
            isRemoteTerminalSurface: true,
            connectionState: .reconnecting,
            detail: "Waiting"
        )

        #expect(presentation == nil)
    }

    @Test("Connected Cloud terminal surfaces hide the overlay")
    func connectedCloudTerminalHidesOverlay() {
        let presentation = CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true,
            isRemoteTerminalSurface: true,
            connectionState: .connected,
            detail: nil
        )

        #expect(presentation == nil)
    }

    @Test("SSH and non-terminal surfaces never show the Cloud overlay")
    func nonCloudSurfacesHideOverlay() {
        #expect(CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: false,
            isRemoteTerminalSurface: true,
            connectionState: .disconnected,
            detail: nil
        ) == nil)
        #expect(CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true,
            isRemoteTerminalSurface: false,
            connectionState: .disconnected,
            detail: nil
        ) == nil)
    }
}
