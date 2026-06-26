import Testing

// `FeedEventClassifier` lives in `CLI/FeedEventClassifier.swift`, which is
// compiled into both the `cmux-cli` target and this test target — so the pure
// classification decision can be unit-tested directly, without `@testable`
// importing the `cmux_cli` executable module (whose symbols the app-hosted
// test bundle cannot link).

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
        let result = FeedEventClassifier.classify(source: source, event: event, toolName: tool)
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

    @Test func claudeLifecycleFeedEventsStayTelemetryAndPreserveNames() {
        for event in ["PostToolUse", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop"] {
            let classification = classify("claude", event, tool: "Bash")
            #expect(classification.name == event)
            #expect(classification.actionable == false)
        }
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

    /// Even on the maybe-approval (generic pre-tool) path, the two dedicated
    /// approval tool names route to their own wire kinds — they are never
    /// collapsed into a generic `PermissionRequest`. Guards the shared
    /// `dedicatedApprovalEvent(for:)` branch inside `.toolStartMaybeApproval`.
    @Test func genericPreToolUseRoutesDedicatedApprovalTools() {
        #expect(classify("gemini", "PreToolUse", tool: "ExitPlanMode").name == "ExitPlanMode")
        #expect(classify("gemini", "PreToolUse", tool: "ExitPlanMode").actionable == true)
        #expect(classify("gemini", "PreToolUse", tool: "AskUserQuestion").name == "AskUserQuestion")
        #expect(classify("gemini", "PreToolUse", tool: "AskUserQuestion").actionable == true)
    }

    /// Codex runs `PermissionRequest` hooks before its own approval reviewer,
    /// so Feed must keep both pre-tool events and permission requests as
    /// telemetry. Otherwise "Approve for me" gets bypassed by cmux's Feed UI.
    @Test func codexPreToolUseIsTelemetry() {
        #expect(classify("codex", "PreToolUse", tool: "shell").actionable == false)
        #expect(classify("codex", "beforeShellExecution", tool: "shell").actionable == false)
        #expect(classify("codex", "beforeShellExecution", tool: "shell").name == "PreToolUse")
        #expect(classify("codex", "PermissionRequest", tool: "shell").name == "PreToolUse")
        #expect(classify("codex", "PermissionRequest", tool: "shell").actionable == false)
    }

    @Test func codexLifecycleFeedEventsStayTelemetryAndPreserveNames() {
        for event in ["PostToolUse", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop"] {
            let classification = classify("codex", event, tool: "shell")
            #expect(classification.name == event)
            #expect(classification.actionable == false)
        }
    }

    @Test func codexSnakeCaseLifecycleFeedEventsStayTelemetryAndPreserveNames() {
        let cases = [
            ("post_tool_use", "PostToolUse"),
            ("pre_compact", "PreCompact"),
            ("post_compact", "PostCompact"),
            ("subagent_start", "SubagentStart"),
            ("subagent_stop", "SubagentStop"),
        ]
        for (event, expectedName) in cases {
            let classification = classify("codex", event, tool: "shell")
            #expect(classification.name == expectedName)
            #expect(classification.actionable == false)
        }
    }

    /// Unknown source + unknown event is safe by default.
    @Test func unknownSourceUnknownEventIsSafe() {
        #expect(classify("totally-new-agent", "some_future_event", tool: "Bash").actionable == false)
    }

    // MARK: Kiro (camelCase events, no dedicated approval event)

    /// Kiro has no dedicated approval event, so its `preToolUse` escalates
    /// side-effecting tools to an approval — resolved against Kiro's internal
    /// tool names (`fs_write`, `execute_bash`, `use_aws`). Read-only `fs_read`
    /// stays telemetry. Registering kiro is required because its camelCase
    /// event names are absent from the generic table and would otherwise
    /// resolve to `.unknown` (non-actionable), silently dropping approvals.
    @Test func kiroPreToolUseEscalatesSideEffectingTools() {
        #expect(classify("kiro", "preToolUse", tool: "fs_write").name == "PermissionRequest")
        #expect(classify("kiro", "preToolUse", tool: "fs_write").actionable == true)
        #expect(classify("kiro", "preToolUse", tool: "execute_bash").actionable == true)
        #expect(classify("kiro", "preToolUse", tool: "use_aws").actionable == true)
        #expect(classify("kiro", "preToolUse", tool: "fs_read").actionable == false)
        #expect(classify("kiro", "preToolUse", tool: "fs_read").name == "PreToolUse")
    }

    /// Kiro lifecycle + post-tool events are telemetry only and map to the
    /// right wire names despite their camelCase spelling.
    @Test func kiroLifecycleEventsClassifyCorrectly() {
        #expect(classify("kiro", "postToolUse", tool: "fs_write").name == "PostToolUse")
        #expect(classify("kiro", "postToolUse", tool: "fs_write").actionable == false)
        #expect(classify("kiro", "agentSpawn").name == "SessionStart")
        #expect(classify("kiro", "userPromptSubmit").name == "UserPromptSubmit")
        #expect(classify("kiro", "stop").name == "Stop")
    }

    /// Kiro's case-insensitive tool aliases must stay scoped to kiro: another
    /// agent emitting a lowercase `fs_write` / `write` must NOT be escalated
    /// (guards the resolved "lowercase tools broaden Feed prompts" fix).
    @Test func kiroToolAliasesDoNotLeakToOtherAgents() {
        #expect(classify("gemini", "PreToolUse", tool: "fs_write").actionable == false)
        #expect(classify("gemini", "PreToolUse", tool: "write").actionable == false)
        #expect(classify("gemini", "PreToolUse", tool: "execute_bash").actionable == false)
    }

    // MARK: Grok (Cursor-style lowercase tool names, no dedicated approval event)

    /// Grok Build has no dedicated approval event, so its `PreToolUse`
    /// escalates side-effecting tools to an approval. The Cursor-style
    /// capitalized `Write`/`Bash` already matched via the shared
    /// `sideEffectingTools` set; the bug behind
    /// https://github.com/manaflow-ai/cmux/issues/6303 is that Grok-native
    /// lowercase / snake_case names (`write`, `run_terminal_cmd`,
    /// `search_replace`, `edit_file`, `delete_file`) silently slipped past the
    /// Feed gate. With the grok alias set they escalate consistently.
    @Test func grokPreToolUseEscalatesGrokNativeSideEffectingTools() {
        for tool in [
            "write", "write_file", "search_replace", "edit_file", "delete_file",
            "run_terminal_cmd", "run_command", "apply_patch", "multi_edit",
        ] {
            #expect(
                classify("grok", "PreToolUse", tool: tool).name == "PermissionRequest",
                "grok \(tool) should escalate to PermissionRequest"
            )
            #expect(
                classify("grok", "PreToolUse", tool: tool).actionable == true,
                "grok \(tool) should be actionable"
            )
        }
    }

    /// The Cursor-style capitalized Grok tool names keep escalating (shared
    /// `sideEffectingTools` set) — the alias addition must not regress them.
    @Test func grokPreToolUseStillEscalatesCursorStyleNames() {
        #expect(classify("grok", "PreToolUse", tool: "Write").actionable == true)
        #expect(classify("grok", "PreToolUse", tool: "Bash").actionable == true)
        #expect(classify("grok", "PreToolUse", tool: "Edit").actionable == true)
    }

    /// Read-only Grok tools stay non-actionable telemetry so the Feed
    /// actionable view is not flooded.
    @Test func grokPreToolUseReadOnlyToolsStayTelemetry() {
        for tool in ["read_file", "list_dir", "codebase_search", "grep", "file_search", "web_search"] {
            #expect(
                classify("grok", "PreToolUse", tool: tool).actionable == false,
                "grok \(tool) should stay telemetry"
            )
            #expect(classify("grok", "PreToolUse", tool: tool).name == "PreToolUse")
        }
    }

    /// Grok lifecycle events classify to the right wire names and stay
    /// telemetry (resolved via the generic table — grok is not registered).
    @Test func grokLifecycleEventsClassifyCorrectly() {
        #expect(classify("grok", "PostToolUse", tool: "write").name == "PostToolUse")
        #expect(classify("grok", "PostToolUse", tool: "write").actionable == false)
        #expect(classify("grok", "UserPromptSubmit").name == "UserPromptSubmit")
        #expect(classify("grok", "Stop").name == "Stop")
        #expect(classify("grok", "SessionStart").name == "SessionStart")
    }

    /// Grok's case-insensitive tool aliases must stay scoped to grok: another
    /// agent emitting lowercase `search_replace` / `run_terminal_cmd` must NOT
    /// be escalated (mirrors the kiro scoping guard).
    @Test func grokToolAliasesDoNotLeakToOtherAgents() {
        #expect(classify("gemini", "PreToolUse", tool: "search_replace").actionable == false)
        #expect(classify("gemini", "PreToolUse", tool: "run_terminal_cmd").actionable == false)
        #expect(classify("kiro", "preToolUse", tool: "search_replace").actionable == false)
    }
}
