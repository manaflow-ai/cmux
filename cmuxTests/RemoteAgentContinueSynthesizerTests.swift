import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit coverage for the Tier-1 hookless remote resume binding synthesis
/// (issue #7989): `RemoteAgentContinueSynthesizer`, the
/// `isRemoteSynthesized` source predicate, the approval-store trust tier,
/// the session-restore reconcile pass-through, and Codable persistence of
/// synthesized bindings.
@Suite struct RemoteAgentContinueSynthesizerTests {
    private static func remoteContext(
        persistentPTYSessionID: String = "pty-session-1"
    ) -> SurfaceResumeRemoteContext {
        SurfaceResumeRemoteContext(
            workspaceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            surfaceID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            persistentPTYSessionID: persistentPTYSessionID
        )
    }

    // MARK: - Command synthesis

    @Test func claudeBindingUsesCdGuardedDirectoryScopedContinueWithFreshSessionFallback() throws {
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .claude,
            remoteWorkingDirectory: "/home/user/proj",
            remoteContext: Self.remoteContext(),
            updatedAt: 123
        ))

        #expect(
            binding.command
                == "cd -- '/home/user/proj' 2>/dev/null || [ ! -d '/home/user/proj' ] && claude --continue || claude"
        )
        #expect(binding.name == "Claude Code continue")
        #expect(binding.kind == "claude")
        #expect(binding.cwd == "/home/user/proj")
        #expect(binding.source == "remote-synthesized")
        #expect(binding.isRemoteSynthesized)
        #expect(binding.autoResume == true)
        #expect(binding.allowsAutomaticResume)
        #expect(binding.updatedAt == 123)
        // A synthesized binding carries no checkpoint, hook environment, or
        // launch capture: `cmux surface resume show` must map it to `.direct`
        // (not `.resumeAgent`) and the command must replay verbatim.
        #expect(binding.checkpointId == nil)
        #expect(binding.environment == nil)
        #expect(binding.launchCommand == nil)
        #expect(!binding.isAgentHookBinding)
    }

    @Test func codexBindingUsesResumeLastWithFreshSessionFallback() throws {
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .codex,
            remoteWorkingDirectory: "/srv/app",
            remoteContext: Self.remoteContext()
        ))

        #expect(
            binding.command
                == "cd -- '/srv/app' 2>/dev/null || [ ! -d '/srv/app' ] && codex resume --last || codex"
        )
        #expect(binding.name == "Codex continue")
        #expect(binding.kind == "codex")
        #expect(binding.source == "remote-synthesized")
        #expect(binding.autoResume == true)
    }

    @Test func bindingIsScopedToThePersistentSSHSessionThatOwnsIt() throws {
        let context = Self.remoteContext(persistentPTYSessionID: "pty-abc")
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .claude,
            remoteWorkingDirectory: "/home/user/proj",
            remoteContext: context
        ))

        #expect(binding.launchFlavor == .persistentSSH(context))
        #expect(binding.launchFlavor.remoteContext == context)
        #expect(binding.launchFlavor.executionLocationRawValue == "remote_ssh")
        #expect(!binding.usesLocalRestoreVerb)
    }

    @Test(arguments: [
        RestorableAgentKind.grok, .pi, .amp, .cursor, .gemini, .kiro,
        .antigravity, .opencode, .rovodev, .hermesAgent, .copilot,
        .codebuddy, .factory, .qoder, .kimi, .ollama, .custom("acme-agent"),
    ])
    func kindsWithoutASessionlessContinueInvocationSynthesizeNothing(
        kind: RestorableAgentKind
    ) {
        #expect(RemoteAgentContinueSynthesizer.binding(
            kind: kind,
            remoteWorkingDirectory: "/home/user/proj",
            remoteContext: Self.remoteContext()
        ) == nil)
    }

    @Test(arguments: [String?.none, "", "   ", "\n\t"])
    func missingOrBlankRemoteWorkingDirectorySynthesizesNothing(cwd: String?) {
        #expect(RemoteAgentContinueSynthesizer.binding(
            kind: .claude,
            remoteWorkingDirectory: cwd,
            remoteContext: Self.remoteContext()
        ) == nil)
    }

    @Test func workingDirectoryIsTrimmedBeforeSynthesis() throws {
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .claude,
            remoteWorkingDirectory: "  /home/user/proj \n",
            remoteContext: Self.remoteContext()
        ))

        #expect(binding.cwd == "/home/user/proj")
        #expect(binding.command.hasPrefix("cd -- '/home/user/proj' 2>/dev/null"))
    }

    // MARK: - Quoting safety

    @Test func workingDirectoryWithSpacesIsSingleQuoted() throws {
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .claude,
            remoteWorkingDirectory: "/tmp/my project",
            remoteContext: Self.remoteContext()
        ))

        #expect(
            binding.command
                == "cd -- '/tmp/my project' 2>/dev/null || [ ! -d '/tmp/my project' ] && claude --continue || claude"
        )
    }

    @Test func workingDirectoryWithSingleQuoteCannotEscapeTheQuoting() throws {
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .codex,
            remoteWorkingDirectory: "/tmp/it's here",
            remoteContext: Self.remoteContext()
        ))

        let quoted = #"'/tmp/it'\''s here'"#
        #expect(
            binding.command
                == "cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ] && codex resume --last || codex"
        )
    }

    @Test func nonASCIIWorkingDirectoryUsesASCIIPrintfSubstitution() throws {
        let cwd = "/tmp/项目"
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .claude,
            remoteWorkingDirectory: cwd,
            remoteContext: Self.remoteContext()
        ))

        // The shared quoter renders non-ASCII paths as an ASCII-only
        // `"$(printf '\ooo…')"` substitution so the command survives any
        // remote locale; the raw bytes must not appear in the command.
        let quoted = TerminalStartupShellQuoting.singleQuoted(cwd)
        #expect(quoted.hasPrefix(#""$(printf '"#))
        #expect(
            binding.command
                == "cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ] && claude --continue || claude"
        )
        #expect(!binding.command.contains("项目"))
        #expect(binding.cwd == cwd, "cwd stores the raw path; only the command is quoted")
    }

    // MARK: - Source predicate

    @Test func isRemoteSynthesizedMatchesTheSynthesizerSourceExactly() {
        #expect(RemoteAgentContinueSynthesizer.source == "remote-synthesized")

        func snapshot(source: String?) -> SurfaceResumeBindingSnapshot {
            SurfaceResumeBindingSnapshot(command: "claude --continue || claude", source: source)
        }

        #expect(snapshot(source: "remote-synthesized").isRemoteSynthesized)
        // Snapshot init trims the source before storing it.
        #expect(snapshot(source: " remote-synthesized \n").isRemoteSynthesized)
        #expect(!snapshot(source: "Remote-Synthesized").isRemoteSynthesized)
        #expect(!snapshot(source: "remote-synthesized-2").isRemoteSynthesized)
        #expect(!snapshot(source: nil).isRemoteSynthesized)
    }

    @Test(arguments: ["agent-hook", "process-detected", "cli", "remote-synthesized"])
    func sourcePredicatesAreMutuallyExclusive(source: String) {
        let binding = SurfaceResumeBindingSnapshot(
            command: "claude --continue || claude",
            source: source
        )

        let predicates = [
            binding.isAgentHookBinding,
            binding.isProcessDetected,
            binding.isCLIBinding,
            binding.isRemoteSynthesized,
        ]
        #expect(predicates.filter { $0 }.count == 1, "exactly one predicate matches \(source)")
        #expect(binding.isRemoteSynthesized == (source == "remote-synthesized"))
    }

    // MARK: - Approval trust tier

    @Test func remoteSynthesizedBindingResolvesTrustWithoutSigningSecret() throws {
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .claude,
            remoteWorkingDirectory: "/home/user/proj",
            remoteContext: Self.remoteContext()
        ))

        // Same tier as process-detected: cmux's own observation, never a
        // proposal from an arbitrary process, so approval must resolve
        // even while the Keychain signing secret is still pending.
        let result = SurfaceResumeApprovalStore.approvalProposalContext(
            for: binding,
            signingSecretResolution: .pending
        )
        guard case let .resolved(context) = result else {
            Issue.record("remote-synthesized must not depend on the signing secret")
            return
        }
        #expect(context.effectiveBinding.allowsAutomaticResume)
        #expect(context.effectiveBinding.approvalPolicy == .auto)
        #expect(context.effectiveBinding.approvalRecordId == nil)
        #expect(context.existingRecord == nil)
        #expect(context.effectiveBinding.command == binding.command)
    }

    @Test func remoteSynthesizedTrustForcesAutoResumeEvenWhenUnsetOnTheBinding() {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --continue || claude",
            cwd: "/home/user/proj",
            source: "remote-synthesized",
            autoResume: nil,
            launchFlavor: .persistentSSH(Self.remoteContext())
        )

        let effective = SurfaceResumeApprovalStore.bindingWithoutStoredApproval(to: binding)
        #expect(effective.allowsAutomaticResume)
        #expect(effective.approvalPolicy == .auto)
        #expect(effective.approvalRecordId == nil)
    }

    @Test func untrustedSourcesStillRequireStoredApproval() {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --continue || claude",
            cwd: "/home/user/proj",
            source: "cli",
            autoResume: true,
            approvalRecordId: "unverified-record",
            launchFlavor: .persistentSSH(Self.remoteContext())
        )

        // Widening the trust tier to remote-synthesized must not loosen the
        // gate for any other source: without a verified record, a cli
        // proposal is demoted to manual.
        let effective = SurfaceResumeApprovalStore.bindingWithoutStoredApproval(to: binding)
        #expect(!effective.allowsAutomaticResume)
        #expect(effective.approvalPolicy == .manual)
        #expect(effective.approvalRecordId == nil)
    }

    // MARK: - Session-restore reconcile

    @Test func sessionRestoreReconcilePassesSynthesizedBindingsThroughUntouched() throws {
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .claude,
            remoteWorkingDirectory: "/home/user/proj",
            remoteContext: Self.remoteContext()
        ))
        let restorableAgent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "a22293b7-bcef-4707-8439-2f538c8517a4",
            workingDirectory: "/somewhere/else",
            launchCommand: nil
        )

        // The checkpoint-based cwd retargeting in resumeBindingForSessionRestore
        // is agent-hook-only; a synthesized binding has no checkpoint to
        // reconcile against and must keep its own directory and command.
        let reconciled = Workspace.resumeBindingForSessionRestore(
            binding,
            restorableAgent: restorableAgent
        )
        #expect(reconciled == binding)
    }

    @Test func sessionRestoreReconcileDoesNotInventABindingFromAgentEvidenceAlone() {
        let restorableAgent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "a22293b7-bcef-4707-8439-2f538c8517a4",
            workingDirectory: "/home/user/proj",
            launchCommand: nil
        )

        // Synthesis happens upstream (createPanel) and only when no binding
        // was located; the reconcile helper itself must stay nil-preserving.
        #expect(Workspace.resumeBindingForSessionRestore(
            nil,
            restorableAgent: restorableAgent
        ) == nil)
    }

    // MARK: - Remote startup input

    @Test func remoteStartupInputReplaysTheSynthesizedCommandVerbatim() throws {
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .codex,
            remoteWorkingDirectory: "/srv/app",
            remoteContext: Self.remoteContext()
        ))

        // The command runs on the remote host: no local restore-CLI verb, no
        // wrapper-shim environment, no /usr/bin/env prefix — the stored
        // command plus a trailing newline is the whole PTY input.
        #expect(binding.remoteStartupInput() == binding.command + "\n")
    }

    // MARK: - Codable persistence

    @Test func synthesizedBindingRoundTripsThroughPersistence() throws {
        let context = Self.remoteContext(persistentPTYSessionID: "pty-roundtrip")
        let binding = try #require(RemoteAgentContinueSynthesizer.binding(
            kind: .codex,
            remoteWorkingDirectory: "/srv/app with 'quotes'",
            remoteContext: context,
            updatedAt: 42
        ))

        let decoded = try JSONDecoder().decode(
            SurfaceResumeBindingSnapshot.self,
            from: JSONEncoder().encode(binding)
        )

        #expect(decoded == binding)
        #expect(decoded.isRemoteSynthesized)
        #expect(decoded.launchFlavor == .persistentSSH(context))
        #expect(decoded.launchFlavor.remoteContext?.persistentPTYSessionID == "pty-roundtrip")
        #expect(!decoded.wasDecodedWithoutLaunchFlavor)
        #expect(decoded.command == binding.command)
        #expect(decoded.autoResume == true)
        #expect(decoded.updatedAt == 42)
    }
}
