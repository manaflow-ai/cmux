import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the feed-event → user-attention classification.
///
/// The "Terminal needs approval" notification (see `FeedCoordinator`) fires
/// only for events that `classifyFeedEvent` marks actionable and whose wire
/// `hook_event_name` is `PermissionRequest` / `ExitPlanMode` /
/// `AskUserQuestion`. The class of bug this guards against is broad
/// pattern-matching that maps a *tool-starting* lifecycle event to an
/// approval, over-triggering the notification.
///
/// https://github.com/manaflow-ai/cmux/issues/4985
@Suite("Feed event classification")
struct FeedEventClassificationTests {
    private func classify(_ source: String, _ event: String, tool: String = "")
        -> (name: String, actionable: Bool)
    {
        let result = CMUXCLI.classifyFeedEvent(source: source, event: event, toolName: tool)
        return (result.0, result.1)
    }

    // MARK: Hermes Agent (the reported bug)

    /// Hermes emits `pre_tool_call` when a tool *starts* — no approval is
    /// pending. It has a distinct `pre_approval_request` event for real
    /// approvals. `pre_tool_call` must never be actionable, even for a
    /// side-effecting tool like `terminal`, or the user sees a spurious
    /// "Terminal needs approval" banner with nothing pending in the TUI.
    @Test func hermesPreToolCallIsTelemetryEvenForSideEffectingTools() {
        #expect(classify("hermes-agent", "pre_tool_call", tool: "terminal").actionable == false)
        #expect(classify("hermes-agent", "pre_tool_call", tool: "Bash").actionable == false)
        #expect(classify("hermes-agent", "pre_tool_call", tool: "Write").actionable == false)
        #expect(classify("hermes-agent", "pre_tool_call", tool: "Read").actionable == false)
        #expect(classify("hermes-agent", "pre_tool_call", tool: "terminal").name == "PreToolUse")
    }

    /// Lifecycle bookends are telemetry only.
    @Test func hermesLifecycleEventsAreNotActionable() {
        #expect(classify("hermes-agent", "post_tool_call").actionable == false)
        #expect(classify("hermes-agent", "pre_llm_call").actionable == false)
        #expect(classify("hermes-agent", "post_llm_call").actionable == false)
        #expect(classify("hermes-agent", "on_session_start").actionable == false)
        #expect(classify("hermes-agent", "on_session_end").actionable == false)
    }

    /// `pre_approval_request` carries the real approval semantic. The
    /// "needs approval" notification fires for it via the dedicated
    /// `notification` hook subcommand, so on the feed path it stays a
    /// non-blocking `Notification` (avoids a double banner).
    @Test func hermesApprovalRequestStaysNonBlockingOnFeedPath() {
        let approval = classify("hermes-agent", "pre_approval_request")
        #expect(approval.name == "Notification")
        #expect(approval.actionable == false)
    }

    /// Future Hermes event names must be safe by default: unknown → no
    /// notification (non-actionable telemetry).
    @Test func hermesUnknownEventIsSafeByDefault() {
        let unknown = classify("hermes-agent", "some_future_event", tool: "terminal")
        #expect(unknown.actionable == false)
    }

    // MARK: Claude (dedicated-approval agent — must not regress)

    /// Claude owns approvals through its `PermissionRequest` hook; its
    /// `PreToolUse` is telemetry and must not escalate side-effecting tools.
    @Test func claudePreToolUseDoesNotEscalate() {
        #expect(classify("claude", "PreToolUse", tool: "Bash").actionable == false)
        #expect(classify("claude", "PreToolUse", tool: "Write").actionable == false)
    }

    @Test func claudePermissionRequestIsActionable() {
        #expect(classify("claude", "PermissionRequest", tool: "Bash").name == "PermissionRequest")
        #expect(classify("claude", "PermissionRequest", tool: "Bash").actionable == true)
        #expect(classify("claude", "PermissionRequest", tool: "ExitPlanMode").name == "ExitPlanMode")
        #expect(classify("claude", "PermissionRequest", tool: "AskUserQuestion").name == "AskUserQuestion")
    }

    // MARK: Generic agents without a dedicated approval event

    /// Agents whose only signal is `PreToolUse` (gemini, copilot, …) still
    /// escalate side-effecting tools to an approval — that path is correct
    /// and must be preserved.
    @Test func genericPreToolUseEscalatesSideEffectingTools() {
        #expect(classify("gemini", "PreToolUse", tool: "Bash").name == "PermissionRequest")
        #expect(classify("gemini", "PreToolUse", tool: "Bash").actionable == true)
        #expect(classify("gemini", "PreToolUse", tool: "Read").actionable == false)
    }

    /// Codex has a dedicated `PermissionRequest` feed event, so its
    /// `PreToolUse` is telemetry only.
    @Test func codexPreToolUseIsTelemetry() {
        #expect(classify("codex", "PreToolUse", tool: "shell").actionable == false)
        #expect(classify("codex", "PermissionRequest", tool: "shell").actionable == true)
    }

    /// Unknown source + unknown event is safe by default.
    @Test func unknownSourceUnknownEventIsSafe() {
        #expect(classify("totally-new-agent", "some_future_event", tool: "Bash").actionable == false)
    }
}
