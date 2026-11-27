import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for https://github.com/manaflow-ai/cmux/issues/62857:
/// a nested headless `claude -p` child launched with the wrapper's
/// visible-mutation suppress environment
/// (`CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS=1`) does not own the
/// terminal. Its SessionStart must leave the pane's active hook owner —
/// session id, process generation, and resume binding — with the
/// interactive owner, so the owner's own hooks stay current and a normal
/// same-pane resume reclaims ownership without first having to clear out
/// the dead child's stale pointer.
@Suite(.serialized)
struct ClaudeNestedHeadlessOwnershipTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let liveWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let liveSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let liveSurfaceUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private static func activeSurfaceSessionId(
        in storeURL: URL,
        surfaceId: String
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        let activeBySurface = saved?["activeSessionsBySurface"] as? [String: Any]
        let active = activeBySurface?[surfaceId] as? [String: Any]
        return active?["sessionId"] as? String
    }

    private func assertSuccessfulHook(_ result: ClaudeHookLiveDeliveryHarness.ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }

    /// Interactive owner → suppressed nested headless child on the same
    /// pane → the child exits abnormally before any terminal hook → the
    /// owner's next turn must not be stale-gated by the child's leftover
    /// state, and the owner's resume must reclaim the pointer. The child
    /// still gets its own record so a normal child SessionEnd consumes the
    /// child alone instead of falling back to the owner.
    @Test func suppressedNestedChildDoesNotDisplaceInteractiveOwner() throws {
        let context = try Harness.makeContext(name: "nested-headless-owner")
        defer { context.cleanup() }
        let ownerSessionId = "interactive-owner-session"
        let childSessionId = "nested-headless-child-session"

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId]],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43210"

        // 1. The interactive owner starts up and owns the pane.
        assertSuccessfulHook(Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(ownerSessionId)","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        ))
        #expect(
            try Self.activeSurfaceSessionId(in: context.storeURL, surfaceId: Self.liveSurfaceId) == ownerSessionId
        )

        // 2. A nested headless child announces itself with the wrapper's
        //    suppress environment; it does not own the terminal.
        environment["CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS"] = "1"
        environment["CMUX_CLAUDE_PID"] = "43211"
        assertSuccessfulHook(Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(childSessionId)","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        ))

        // The pointer must still name the interactive owner, with the
        // owner's process generation intact.
        #expect(
            try Self.activeSurfaceSessionId(in: context.storeURL, surfaceId: Self.liveSurfaceId) == ownerSessionId,
            "A suppressed nested headless child must not advance the pane's active owner"
        )
        let ownerRecord = try Harness.sessionRecord(in: context.storeURL, sessionId: ownerSessionId)
        #expect(
            ownerRecord?["pid"] as? Int == 43210,
            "The interactive owner's process generation must stay intact; saw \(String(describing: ownerRecord?["pid"]))"
        )
        // The child still gets its own record, so its own SessionEnd
        // consumes the child alone instead of falling back to the owner.
        let childRecord = try Harness.sessionRecord(in: context.storeURL, sessionId: childSessionId)
        #expect(childRecord?["pid"] as? Int == 43211)

        // The pane's resume binding stays with the interactive owner too: a
        // headless child must not rewrite what this pane resumes.
        let resumeBindingSessionIds = Harness.resumeBindingParams(in: context).compactMap {
            $0["checkpoint_id"] as? String
        }
        #expect(
            !resumeBindingSessionIds.contains(childSessionId),
            "A nested headless child must not claim the pane's resume binding; saw \(resumeBindingSessionIds)"
        )

        // 3. The child dies abnormally: no Stop, no SessionEnd hook. The
        //    owner's next interactive turn must still be current, not
        //    stale-gated by the child's leftover pointer.
        environment.removeValue(forKey: "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS")
        environment["CMUX_CLAUDE_PID"] = "43210"
        assertSuccessfulHook(Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(ownerSessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","last_assistant_message":"All done"}"#
        ))
        let commands = context.state.snapshot()
        #expect(
            commands.contains { $0.hasPrefix("notify_target_async \(Self.liveWorkspaceId) \(Self.liveSurfaceId) ") },
            "The interactive owner's turn must stay current after the suppressed child's abnormal exit; saw \(commands)"
        )

        // 4. A normal same-pane resume reclaims ownership cleanly.
        environment["CMUX_CLAUDE_PID"] = "43212"
        assertSuccessfulHook(Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(ownerSessionId)","source":"resume","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        ))
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(
            try Self.activeSurfaceSessionId(in: context.storeURL, surfaceId: Self.liveSurfaceId) == ownerSessionId,
            "A normal same-pane resume must keep or reclaim the pane's active owner"
        )
    }

    // MARK: - Pane input reconciliation from the authoritative registry

    /// The pane input classifier must answer from the authoritative hook
    /// registry when the journal projection has no live entry for an
    /// accepted, still-live owner (#62857), and must stay silent — leaving
    /// the journal answer untouched — for dead generations, foreign panes,
    /// and non-owners.
    @Test func inputLifecycleReconciliationFollowsRegistryOwnerRecord() {
        let panelId = Self.liveSurfaceUUID
        let ownerBinding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude",
            checkpointId: "resume-owner-session",
            source: "agent-hook"
        )
        func record(sessionId: String, surfaceId: UUID, lifecycle: AgentHibernationLifecycleState?) -> RestorableAgentHookSessionRecord {
            RestorableAgentHookSessionRecord(
                sessionId: sessionId,
                workspaceId: Self.liveWorkspaceId,
                surfaceId: surfaceId.uuidString,
                cwd: nil,
                transcriptPath: nil,
                pid: nil,
                pidStartSeconds: nil,
                pidStartMicroseconds: nil,
                launchCommand: nil,
                lastPermissionMode: nil,
                isRestorable: true,
                agentLifecycle: lifecycle,
                hadSessionCronsAtStop: nil,
                updatedAt: 0,
                activePromptDepth: nil,
                activePromptTurnIds: nil
            )
        }

        // An accepted owner whose registry record and registered process
        // generation agree projects the registry's own lifecycle.
        #expect(Workspace.reconciledAgentHookInputLifecycle(
            binding: ownerBinding,
            recordedAgentPID: 43210,
            recordedAgentPIDMatchesGeneration: true,
            registryRecords: [
                record(sessionId: "resume-owner-session", surfaceId: panelId, lifecycle: .idle),
                record(sessionId: "other-pane-session", surfaceId: UUID(), lifecycle: .idle),
            ],
            panelId: panelId
        ) == .idle)

        // A registry record without a lifecycle still proves the live owner:
        // the registry's idle baseline applies instead of `unknown`.
        #expect(Workspace.reconciledAgentHookInputLifecycle(
            binding: ownerBinding,
            recordedAgentPID: 43210,
            recordedAgentPIDMatchesGeneration: true,
            registryRecords: [record(sessionId: "resume-owner-session", surfaceId: panelId, lifecycle: nil)],
            panelId: panelId
        ) == .idle)

        // A dead process generation must never project a phantom agent.
        #expect(Workspace.reconciledAgentHookInputLifecycle(
            binding: ownerBinding,
            recordedAgentPID: 43210,
            recordedAgentPIDMatchesGeneration: false,
            registryRecords: [record(sessionId: "resume-owner-session", surfaceId: panelId, lifecycle: .idle)],
            panelId: panelId
        ) == nil)
        #expect(Workspace.reconciledAgentHookInputLifecycle(
            binding: ownerBinding,
            recordedAgentPID: nil,
            recordedAgentPIDMatchesGeneration: false,
            registryRecords: [record(sessionId: "resume-owner-session", surfaceId: panelId, lifecycle: .idle)],
            panelId: panelId
        ) == nil)

        // A registry record naming another pane must not answer here.
        #expect(Workspace.reconciledAgentHookInputLifecycle(
            binding: ownerBinding,
            recordedAgentPID: 43210,
            recordedAgentPIDMatchesGeneration: true,
            registryRecords: [record(sessionId: "resume-owner-session", surfaceId: UUID(), lifecycle: .idle)],
            panelId: panelId
        ) == nil)

        // Non-owners stay out: untrusted imports, other agents, and missing
        // checkpoint identity all leave the journal answer untouched.
        let untrustedImport = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude",
            checkpointId: "resume-owner-session",
            source: "session-import"
        )
        #expect(Workspace.reconciledAgentHookInputLifecycle(
            binding: untrustedImport,
            recordedAgentPID: 43210,
            recordedAgentPIDMatchesGeneration: true,
            registryRecords: [record(sessionId: "resume-owner-session", surfaceId: panelId, lifecycle: .idle)],
            panelId: panelId
        ) == nil)
        let codexBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex",
            checkpointId: "resume-owner-session",
            source: "agent-hook"
        )
        #expect(Workspace.reconciledAgentHookInputLifecycle(
            binding: codexBinding,
            recordedAgentPID: 43210,
            recordedAgentPIDMatchesGeneration: true,
            registryRecords: [record(sessionId: "resume-owner-session", surfaceId: panelId, lifecycle: .idle)],
            panelId: panelId
        ) == nil)
        #expect(Workspace.reconciledAgentHookInputLifecycle(
            binding: SurfaceResumeBindingSnapshot(
                kind: "claude",
                command: "claude",
                checkpointId: "  ",
                source: "agent-hook"
            ),
            recordedAgentPID: 43210,
            recordedAgentPIDMatchesGeneration: true,
            registryRecords: [record(sessionId: "resume-owner-session", surfaceId: panelId, lifecycle: .idle)],
            panelId: panelId
        ) == nil)
    }
}
