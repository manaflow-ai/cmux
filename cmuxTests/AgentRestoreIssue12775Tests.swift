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
@Suite("Agent restore stale-owner admission", .serialized, .timeLimit(.minutes(1)))
struct AgentRestoreIssue12775Tests {
    @Test("A dead recorded PID does not block restore admission")
    func deadRecordedPIDDoesNotBlockAdmission() {
        let recordedIdentity = AgentPIDProcessIdentity(
            pid: 987_654_321,
            startSeconds: 1_800_000_000,
            startMicroseconds: 42
        )
        let owner = makeOwner(
            kind: .grok,
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
        let sessionID = "late-session-end-\(UUID().uuidString)"
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: "/tmp"
        )
        let workspace = Workspace(
            initialTerminalInput: " cmux restore claude \(sessionID)\n",
            initialTerminalStartupRestoreAgent: agent,
            initialTerminalStartupRestoreCommitOwner: .tabManagerTopology,
            agentSessionAutoResumeDefaults: defaults
        )
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.terminalPanel(for: panelID))
        #expect(terminal.surface.isAwaitingStartupRestoreAdmission)
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
        #expect(!terminal.surface.isAwaitingStartupRestoreAdmission)
        #expect(workspace.deferredAgentResumeRestoresByPanelId[panelID] == nil)
        #expect(!terminal.surface.debugInitialInputMetadata().hasInitialInput)
    }

    @Test("A recorded owner that exits after the scan is released by generation revalidation")
    func ownerExitAfterScanIsNotStillLive() async throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
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
            kind: .codex,
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
                processPresenceProvider: { PIDPresence.current(pid: pid_t($0)) }
            ) != nil
        )
        // Construction registers and resumes the sources synchronously. Hold
        // the child on stdin until registration, so no scheduling delay is
        // needed to establish that observation precedes exit.
        let observation = AgentRestoreEvidenceSubscription(
            process: identity, paths: [], deadline: .distantFuture
        )
        defer { observation.cancel() }
        var events = observation.events.makeAsyncIterator()
        try input.fileHandleForWriting.close()
        #expect(await events.next() != nil)
        process.waitUntilExit()
        #expect(
            index.owner(
                kind: owner.kind,
                sessionID: owner.sessionID,
                processPresenceProvider: { PIDPresence.current(pid: pid_t($0)) }
            ) == nil
        )
    }

    @Test("A live real owner still refuses duplicate admission")
    func liveOwnerRemainsAnAdmissionBlocker() throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
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
            kind: .codex,
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
                processPresenceProvider: { PIDPresence.current(pid: pid_t($0)) }
            )?.processID == processID
        )
    }

    private func makeOwner(
        kind: RestorableAgentKind,
        sessionID: String,
        processID: Int,
        processIdentity: AgentPIDProcessIdentity,
        hermesSessionValidation: CachedAgentProcessIdentityValidator.HermesSessionValidation
    ) -> LiveAgentSessionOwner {
        LiveAgentSessionOwner(
            kind: kind.rawValue,
            sessionID: sessionID,
            processID: processID,
            processIdentity: processIdentity,
            workspaceID: UUID(),
            surfaceID: UUID(),
            observedAt: 1_800_000_000,
            validationSnapshot: SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: sessionID,
                workingDirectory: "/tmp"
            ),
            hermesSessionValidation: hermesSessionValidation
        )
    }
}
