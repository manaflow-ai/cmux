import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for stale and late owner evidence during restore.
@MainActor
@Suite("Agent restore stale-owner admission", .serialized)
struct AgentRestoreIssue12775Tests {
    @Test("A dead recorded PID does not block restore admission")
    func deadRecordedPIDDoesNotBlockAdmission() {
        let recordedIdentity = AgentPIDProcessIdentity(
            pid: 987_654_321,
            startSeconds: 1_800_000_000,
            startMicroseconds: 42
        )
        let owner = makeOwner(
            kind: "grok",
            sessionID: "dead-recorded-owner",
            processID: Int(recordedIdentity.pid),
            processIdentity: recordedIdentity,
            hermesSessionValidation: .cachedSnapshot
        )
        let index = LiveAgentSessionOwnerIndex(
            observations: [LiveAgentSessionOwnerObservation(owner: owner)]
        )

        #expect(
            index.owner(
                kind: owner.kind,
                sessionID: owner.sessionID,
                processPresenceProvider: { _ in .absent },
                processIdentityProvider: { _ in nil }
            ) == nil
        )
    }

    @Test("A same-session binding retired by a late SessionEnd stays resumable")
    func lateSessionEndRetirementKeepsDeferredRestore() throws {
        let defaultsName = "cmux-issue-12775-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "late-session-end-\(UUID().uuidString)"
        let binding = SurfaceResumeBindingSnapshot(
            name: "Claude",
            kind: "claude",
            command: "claude --resume \(sessionID)",
            cwd: "/tmp",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_800_000_000
        )
        let restore = DeferredAgentResumeRestore(
            stablePanelID: panelID,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            workingDirectory: "/tmp",
            resumeWorkingDirectory: "/tmp"
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        workspace.deferredAgentResumeRestoresByPanelId[panelID] = restore

        // SessionEnd from the previous cmux instance can arrive after the new
        // instance staged this restore and retire the binding in place.
        var retiredBinding = binding
        retiredBinding.autoResume = false
        workspace.surfaceResumeBindingsByPanelId[panelID] = retiredBinding

        workspace.resolveDeferredAgentResumeRestores(using: .empty)
        #expect(
            workspace.restoredAgentResumeStatesByPanelId[panelID] == .awaitingAutoResumeCommand,
            "A late owner-exit hook for the same session must not turn a staged restore into a silent shell."
        )
    }

    @Test("A recorded owner that exits after the scan is released by generation revalidation")
    func ownerExitAfterScanIsNotStillLive() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["2"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let processID = Int(process.processIdentifier)
        let identity = try #require(AgentPIDProcessIdentity(pid: pid_t(processID)))
        let owner = makeOwner(
            kind: "codex",
            sessionID: "exiting-owner",
            processID: processID,
            processIdentity: identity,
            hermesSessionValidation: .currentHookRecord
        )
        let index = LiveAgentSessionOwnerIndex(
            observations: [LiveAgentSessionOwnerObservation(owner: owner)]
        )

        #expect(
            index.owner(
                kind: owner.kind,
                sessionID: owner.sessionID,
                processPresenceProvider: { _ in .present },
                processIdentityProvider: { _ in identity }
            ) != nil
        )
        let exitObservation = Task {
            await AgentRestoreEvidenceObservation().wait(
                process: identity,
                paths: []
            )
        }
        try await Task.sleep(for: .milliseconds(500))
        process.terminate()
        process.waitUntilExit()
        await exitObservation.value
        #expect(
            index.owner(
                kind: owner.kind,
                sessionID: owner.sessionID,
                processPresenceProvider: { _ in .absent },
                processIdentityProvider: { _ in nil }
            ) == nil
        )
    }

    @Test("A live real owner still refuses duplicate admission")
    func liveOwnerRemainsAnAdmissionBlocker() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["2"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let processID = Int(process.processIdentifier)
        let identity = try #require(AgentPIDProcessIdentity(pid: pid_t(processID)))
        let owner = makeOwner(
            kind: "codex",
            sessionID: "live-owner",
            processID: processID,
            processIdentity: identity,
            hermesSessionValidation: .currentHookRecord
        )
        let index = LiveAgentSessionOwnerIndex(
            observations: [LiveAgentSessionOwnerObservation(owner: owner)]
        )

        #expect(
            index.owner(
                kind: owner.kind,
                sessionID: owner.sessionID,
                processPresenceProvider: { _ in .present },
                processIdentityProvider: { _ in identity }
            )?.processID == processID
        )
    }

    private func makeOwner(
        kind: String,
        sessionID: String,
        processID: Int,
        processIdentity: AgentPIDProcessIdentity,
        hermesSessionValidation: CachedAgentProcessIdentityValidator.HermesSessionValidation
    ) -> LiveAgentSessionOwner {
        LiveAgentSessionOwner(
            kind: kind,
            sessionID: sessionID,
            processID: processID,
            processIdentity: processIdentity,
            workspaceID: UUID(),
            surfaceID: UUID(),
            observedAt: 1_800_000_000,
            validationSnapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionID,
                workingDirectory: "/tmp"
            ),
            hermesSessionValidation: hermesSessionValidation
        )
    }
}
