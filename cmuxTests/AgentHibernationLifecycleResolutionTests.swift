import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the hibernation lifecycle decision functions that make every
/// agent (not just codex) become hibernation-eligible when it is genuinely idle.
@Suite struct AgentHibernationLifecycleResolutionTests {
    typealias Lifecycle = AgentHibernationLifecycleState

    // MARK: resolved(from:fallback:) — the live per-panel priority

    @Test func resolvedReturnsFallbackWhenNoLiveStates() {
        #expect(Lifecycle.resolved(from: [Lifecycle](), fallback: nil) == .unknown)
        #expect(Lifecycle.resolved(from: [Lifecycle](), fallback: .idle) == .idle)
        #expect(Lifecycle.resolved(from: [Lifecycle](), fallback: .needsInput) == .needsInput)
    }

    /// `unknown` from any source blocks `idle` — a stale `.idle` key on the same
    /// panel must not make it hibernation-eligible while another key is in an
    /// indeterminate state. In practice each panel has one agent key at a time
    /// (the other is cleared at session end), so `preservingDefinitive` in
    /// `setAgentLifecycle` already prevents a `.unknown` SessionStart from
    /// overwriting a legitimate `.idle` for the same key.
    @Test func resolvedUnknownBlocksIdle() {
        #expect(Lifecycle.resolved(from: [.unknown, .idle], fallback: nil) == .unknown)
        #expect(Lifecycle.resolved(from: [.idle, .unknown], fallback: nil) == .unknown)
    }

    @Test func resolvedKeepsBusyAndBlockedAboveIdle() {
        #expect(Lifecycle.resolved(from: [.running, .idle], fallback: nil) == .running)
        #expect(Lifecycle.resolved(from: [.needsInput, .idle], fallback: nil) == .needsInput)
        #expect(Lifecycle.resolved(from: [.running, .needsInput, .idle, .unknown], fallback: nil) == .running)
    }

    @Test func resolvedSingleStates() {
        #expect(Lifecycle.resolved(from: [.idle], fallback: nil) == .idle)
        #expect(Lifecycle.resolved(from: [.unknown], fallback: .idle) == .unknown)
    }

    // MARK: effective(agentLifecycle:lastNotificationStatus:) — index/persisted fallback

    @Test func effectivePrefersDefinitiveLifecycle() {
        #expect(Lifecycle.effective(agentLifecycle: .idle, lastNotificationStatus: nil) == .idle)
        #expect(Lifecycle.effective(agentLifecycle: .running, lastNotificationStatus: "idle") == .running)
        #expect(Lifecycle.effective(agentLifecycle: .needsInput, lastNotificationStatus: "idle") == .needsInput)
    }

    /// Plugin/no-emit agents (e.g. opencode) never emit a live lifecycle but do
    /// record a completion notification; treat that as idle so they hibernate.
    @Test func effectiveDerivesIdleFromCompletionNotification() {
        #expect(Lifecycle.effective(agentLifecycle: .unknown, lastNotificationStatus: "idle") == .idle)
        #expect(Lifecycle.effective(agentLifecycle: nil, lastNotificationStatus: "idle") == .idle)
        #expect(Lifecycle.effective(agentLifecycle: nil, lastNotificationStatus: "Idle") == .idle)
    }

    @Test func effectiveStaysIndeterminateWithoutCompletionSignal() {
        #expect(Lifecycle.effective(agentLifecycle: .unknown, lastNotificationStatus: nil) == .unknown)
        #expect(Lifecycle.effective(agentLifecycle: nil, lastNotificationStatus: "needsInput") == nil)
        #expect(Lifecycle.effective(agentLifecycle: .unknown, lastNotificationStatus: "needsInput") == .unknown)
    }

    // MARK: notificationIndicatesBlocked — the Claude clobber fix

    @Test func notificationBlockedDetectsPermissionPrompts() {
        #expect(Lifecycle.notificationIndicatesBlocked(subtitle: "Permission", body: "Use Bash?"))
        #expect(Lifecycle.notificationIndicatesBlocked(subtitle: "", body: "Claude needs your permission to run a command"))
        #expect(Lifecycle.notificationIndicatesBlocked(subtitle: "", body: "Approve this action?"))
        #expect(Lifecycle.notificationIndicatesBlocked(subtitle: "Approval required", body: ""))
    }

    /// The normal post-turn "waiting for your input" notification is NOT blocked,
    /// so it resolves to idle and lets Claude hibernate instead of being clobbered
    /// to needsInput on every turn.
    @Test func notificationNotBlockedForReadyWaiting() {
        #expect(!Lifecycle.notificationIndicatesBlocked(subtitle: "Waiting", body: "Claude is waiting for your input"))
        #expect(!Lifecycle.notificationIndicatesBlocked(subtitle: "Completed", body: "Task finished"))
        #expect(!Lifecycle.notificationIndicatesBlocked(subtitle: "", body: ""))
    }

    // MARK: preservingDefinitive — the non-destructive SessionStart merge

    /// A SessionStart on resume/relaunch reports `.unknown`; it must never erase a
    /// previously-proven definitive lifecycle, or a quiescent resumed agent gets
    /// stuck at `.unknown` forever and never re-hibernates. Only a definitive ->
    /// `.unknown` downgrade is suppressed; everything else passes through.
    @Test func preservingDefinitiveKeepsProvenStateAgainstUnknown() {
        #expect(Lifecycle.preservingDefinitive(existing: nil, incoming: .unknown) == .unknown)
        #expect(Lifecycle.preservingDefinitive(existing: .unknown, incoming: .unknown) == .unknown)
        #expect(Lifecycle.preservingDefinitive(existing: .idle, incoming: .unknown) == .idle)
        #expect(Lifecycle.preservingDefinitive(existing: .running, incoming: .unknown) == .running)
        #expect(Lifecycle.preservingDefinitive(existing: .needsInput, incoming: .unknown) == .needsInput)
    }

    /// Any definitive incoming state overwrites any existing state, so a genuine
    /// new-turn `.running`, a blocking `.needsInput`, or a turn-end `.idle` still
    /// wins. This keeps the claude `/clear` promote-to-running boundary intact.
    @Test func preservingDefinitiveLetsDefinitiveIncomingWin() {
        for existing in [nil, .unknown, .idle, .running, .needsInput] as [Lifecycle?] {
            #expect(Lifecycle.preservingDefinitive(existing: existing, incoming: .idle) == .idle)
            #expect(Lifecycle.preservingDefinitive(existing: existing, incoming: .running) == .running)
            #expect(Lifecycle.preservingDefinitive(existing: existing, incoming: .needsInput) == .needsInput)
        }
    }

    // MARK: allowsHibernation invariant

    @Test func onlyIdleAllowsHibernation() {
        #expect(Lifecycle.idle.allowsHibernation)
        #expect(!Lifecycle.running.allowsHibernation)
        #expect(!Lifecycle.needsInput.allowsHibernation)
        #expect(!Lifecycle.unknown.allowsHibernation)
    }
}
