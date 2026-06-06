import Testing

@testable import cmux

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

    /// The core fix: a definitive `idle` must not be masked by an `unknown`
    /// source. Previously `unknown` outranked `idle`, so any agent that also
    /// reported an indeterminate status never hibernated.
    @Test func resolvedPrefersIdleOverUnknown() {
        #expect(Lifecycle.resolved(from: [.unknown, .idle], fallback: nil) == .idle)
        #expect(Lifecycle.resolved(from: [.idle, .unknown], fallback: nil) == .idle)
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

    // MARK: allowsHibernation invariant

    @Test func onlyIdleAllowsHibernation() {
        #expect(Lifecycle.idle.allowsHibernation)
        #expect(!Lifecycle.running.allowsHibernation)
        #expect(!Lifecycle.needsInput.allowsHibernation)
        #expect(!Lifecycle.unknown.allowsHibernation)
    }
}
