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
        -> (
            name: String,
            actionable: Bool,
            notifiesNativeApprovalPrompt: Bool,
            clearsNativeApprovalPrompt: Bool
        )
    {
        let result = FeedEventClassifier.classify(source: source, event: event, toolName: tool)
        return (
            result.hookEventName,
            result.isActionable,
            result.notifiesNativeApprovalPrompt,
            result.clearsNativeApprovalPrompt
        )
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

    // MARK: Explicit approval-capable agents

    /// Gemini has a verified PreToolUse decision contract and explicitly
    /// opts in to escalating side-effecting tools.
    @Test func geminiPreToolUseEscalatesSideEffectingTools() {
        #expect(classify("gemini", "PreToolUse", tool: "Bash").name == "PermissionRequest")
        #expect(classify("gemini", "PreToolUse", tool: "Bash").actionable == true)
        #expect(classify("gemini", "PreToolUse", tool: "Read").actionable == false)
    }

    /// Even on the maybe-approval pre-tool path, the two dedicated
    /// approval tool names route to their own wire kinds — they are never
    /// collapsed into a generic `PermissionRequest`. Guards the shared
    /// `dedicatedApprovalEvent(for:)` branch inside `.toolStartMaybeApproval`.
    @Test func geminiPreToolUseRoutesDedicatedApprovalTools() {
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

    /// Codex blocks in its OWN approval reviewer when `PermissionRequest`
    /// fires, so the feed event must stay non-actionable telemetry — but the
    /// bridge must still raise the "Agent Needs Permission"-gated
    /// notification, or a blocked codex seat is silent indefinitely.
    /// https://github.com/manaflow-ai/cmux/issues/9592
    @Test func codexPermissionRequestRaisesPermissionPromptNotification() {
        for event in ["PermissionRequest", "permission_request"] {
            let classification = classify("codex", event, tool: "shell")
            #expect(classification.notifiesNativeApprovalPrompt == true)
            // The blocking contract is unchanged: telemetry wire event, no
            // cmux Feed approval card competing with Codex's own reviewer.
            #expect(classification.name == "PreToolUse")
            #expect(classification.actionable == false)
        }
    }

    /// The permission-prompt notification is exclusive to agents that block
    /// in their own approval UI. Blocking-capable agents (claude, gemini,
    /// kiro) notify through the app's actionable-approval path, ordinary
    /// telemetry never notifies, and unknown sources stay silent by default.
    @Test func permissionPromptNotificationStaysScopedToNativeApprovalAgents() {
        #expect(classify("claude", "PermissionRequest", tool: "Bash").notifiesNativeApprovalPrompt == false)
        #expect(classify("gemini", "PreToolUse", tool: "Bash").notifiesNativeApprovalPrompt == false)
        #expect(classify("kiro", "preToolUse", tool: "fs_write").notifiesNativeApprovalPrompt == false)
        #expect(classify("codex", "PreToolUse", tool: "shell").notifiesNativeApprovalPrompt == false)
        #expect(classify("codex", "PostToolUse", tool: "shell").notifiesNativeApprovalPrompt == false)
        #expect(classify("hermes-agent", "pre_approval_request").notifiesNativeApprovalPrompt == false)
        #expect(classify("totally-new-agent", "PermissionRequest", tool: "Bash").notifiesNativeApprovalPrompt == false)
    }

    /// A COMPLETED codex tool proves any pending native approval prompt
    /// resolved — execution strictly follows approval (by the user or by
    /// Codex's own auto-review) — so PostToolUse clears the pane's stale
    /// permission notification, mirroring the pane-wide clears Claude's
    /// lifecycle hooks and Hermes' approval-response hook already perform.
    @Test func codexToolCompletionClearsNativeApprovalPrompt() {
        #expect(classify("codex", "PostToolUse", tool: "shell").clearsNativeApprovalPrompt == true)
        #expect(classify("codex", "post_tool_use", tool: "shell").clearsNativeApprovalPrompt == true)
    }

    /// Pre-tool events must NOT clear: codex fires them when it INTENDS to
    /// run a tool, with no ordering guarantee against the PermissionRequest
    /// hook, so a start-time clear could erase the just-raised prompt while
    /// the agent is still blocked — reintroducing #9592's silence. The clear
    /// also stays scoped: the prompt event itself notifies rather than
    /// clears, and agents that never raise native approval prompts must not
    /// have their tool telemetry touch the notification queue.
    @Test func nativeApprovalPromptClearStaysScopedToCodexToolCompletion() {
        #expect(classify("codex", "PreToolUse", tool: "shell").clearsNativeApprovalPrompt == false)
        #expect(classify("codex", "pre_tool_use", tool: "shell").clearsNativeApprovalPrompt == false)
        #expect(classify("codex", "beforeShellExecution", tool: "shell").clearsNativeApprovalPrompt == false)
        #expect(classify("codex", "PermissionRequest", tool: "shell").clearsNativeApprovalPrompt == false)
        #expect(classify("codex", "Stop", tool: "").clearsNativeApprovalPrompt == false)
        #expect(classify("claude", "PreToolUse", tool: "Bash").clearsNativeApprovalPrompt == false)
        #expect(classify("claude", "PostToolUse", tool: "Bash").clearsNativeApprovalPrompt == false)
        #expect(classify("gemini", "PreToolUse", tool: "Read").clearsNativeApprovalPrompt == false)
        #expect(classify("totally-new-agent", "PostToolUse", tool: "Bash").clearsNativeApprovalPrompt == false)
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

    /// Unknown sources must stay non-blocking even when they emit a familiar
    /// pre-tool event for a side-effecting tool. A new integration must opt in
    /// to decision semantics explicitly before it can stall an agent process.
    @Test func unknownSourcePreToolUseIsSafeByDefault() {
        let preTool = classify("totally-new-agent", "PreToolUse", tool: "Bash")
        #expect(preTool.name == "PreToolUse")
        #expect(preTool.actionable == false)

        #expect(classify("totally-new-agent", "some_future_event", tool: "Bash").actionable == false)
    }

    /// Antigravity and Cursor tool-start hooks are telemetry, not approval
    /// requests. Neither integration has a safe blocking bridge contract.
    @Test func incompatibleToolLifecycleHooksStayTelemetry() {
        #expect(classify("antigravity", "PreToolUse", tool: "Bash").actionable == false)
        #expect(classify("cursor", "beforeShellExecution", tool: "Bash").actionable == false)
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

    // MARK: Attention command construction (the wire the feed hook sends)

    private static let workspaceUUID = "11111111-2222-3333-4444-555555555555"
    private static let surfaceUUID = "66666666-7777-8888-9999-AAAAAAAAAAAA"

    private func attentionCommand(
        _ source: String,
        _ event: String,
        tool: String,
        displayName: String = "Codex",
        workspaceId: String? = workspaceUUID,
        surfaceId: String? = surfaceUUID
    ) -> String? {
        FeedEventClassifier.nativeApprovalPromptAttentionCommand(
            classification: FeedEventClassifier.classify(source: source, event: event, toolName: tool),
            displayName: displayName,
            toolName: tool,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
    }

    /// The exact `notify_target_async` line for a codex PermissionRequest:
    /// UUID-addressed, tool-name-only body (never the tool input), and the
    /// `c=needs-permission;p=0` meta that gates the alert under the "Agent
    /// Needs Permission" setting. A malformed payload or dropped meta here
    /// is what silently regresses https://github.com/manaflow-ai/cmux/issues/9592.
    @Test func codexPermissionRequestBuildsGatedNotifyCommand() {
        #expect(
            attentionCommand("codex", "PermissionRequest", tool: "shell")
                == "notify_target_async \(Self.workspaceUUID) \(Self.surfaceUUID) Codex|Permission|shell needs approval|c=needs-permission;p=0"
        )
    }

    /// Without a tool name the body falls back to the shared "Approval
    /// needed" string rather than an empty interpolation.
    @Test func codexPermissionRequestWithoutToolNameFallsBackToApprovalNeeded() {
        #expect(
            attentionCommand("codex", "PermissionRequest", tool: "")
                == "notify_target_async \(Self.workspaceUUID) \(Self.surfaceUUID) Codex|Permission|Approval needed|c=needs-permission;p=0"
        )
    }

    /// Tool names are payload-controlled input: pipes are the payload
    /// delimiter and newlines would split the single socket command line,
    /// so both must be neutralized.
    @Test func attentionCommandSanitizesPipeAndNewlineInToolName() {
        #expect(
            attentionCommand("codex", "PermissionRequest", tool: "a|b")
                == "notify_target_async \(Self.workspaceUUID) \(Self.surfaceUUID) Codex|Permission|a¦b needs approval|c=needs-permission;p=0"
        )
        #expect(
            attentionCommand("codex", "PermissionRequest", tool: "a\nb")
                == "notify_target_async \(Self.workspaceUUID) \(Self.surfaceUUID) Codex|Permission|a b needs approval|c=needs-permission;p=0"
        )
    }

    /// Codex tool completion resolves the prompt: the exact pane-scoped
    /// `clear_notifications` line.
    @Test func codexToolCompletionBuildsPaneScopedClearCommand() {
        #expect(
            attentionCommand("codex", "PostToolUse", tool: "shell")
                == "clear_notifications --tab=\(Self.workspaceUUID) --panel=\(Self.surfaceUUID)"
        )
    }

    /// Lowercase UUIDs from the pane environment are normalized, not
    /// rejected.
    @Test func attentionCommandNormalizesLowercaseUUIDs() {
        let command = attentionCommand(
            "codex",
            "PermissionRequest",
            tool: "shell",
            workspaceId: Self.workspaceUUID.lowercased(),
            surfaceId: Self.surfaceUUID.lowercased()
        )
        #expect(command?.contains("notify_target_async \(Self.workspaceUUID) \(Self.surfaceUUID) ") == true)
    }

    /// The command is advisory: missing or non-UUID identities yield nil
    /// instead of a malformed socket command, and events without attention
    /// semantics never produce a command at all.
    @Test func attentionCommandRequiresUUIDTargetsAndAttentionSemantics() {
        #expect(attentionCommand("codex", "PermissionRequest", tool: "shell", workspaceId: nil) == nil)
        #expect(attentionCommand("codex", "PermissionRequest", tool: "shell", surfaceId: nil) == nil)
        #expect(attentionCommand("codex", "PermissionRequest", tool: "shell", surfaceId: "surface:1") == nil)
        #expect(attentionCommand("codex", "PermissionRequest", tool: "shell", workspaceId: "workspace:1") == nil)
        #expect(attentionCommand("codex", "PreToolUse", tool: "shell") == nil)
        #expect(attentionCommand("claude", "PermissionRequest", tool: "Bash") == nil)
        #expect(attentionCommand("totally-new-agent", "PermissionRequest", tool: "Bash") == nil)
    }

    // MARK: AtomCode (Claude-Code-compatible lifecycle hooks)

    /// AtomCode's hooks are telemetry only: it has no verified cmux-side
    /// approval bridge.  Its tool-failure event still maps to the completed
    /// tool wire name, while StopFailure remains a terminal response signal.
    @Test func atomcodeLifecycleAndToolHooksStayTelemetry() {
        let cases = [
            ("SessionStart", "SessionStart"),
            ("session_start", "SessionStart"),
            ("UserPromptSubmit", "UserPromptSubmit"),
            ("user_prompt_submit", "UserPromptSubmit"),
            ("PreToolUse", "PreToolUse"),
            ("pre_tool_use", "PreToolUse"),
            ("PostToolUse", "PostToolUse"),
            ("post_tool_use", "PostToolUse"),
            ("PostToolUseFailure", "PostToolUse"),
            ("post_tool_use_failure", "PostToolUse"),
            ("Stop", "Stop"),
            ("stop", "Stop"),
            ("StopFailure", "Stop"),
            ("stop_failure", "Stop"),
            ("SessionEnd", "SessionEnd"),
            ("session_end", "SessionEnd"),
        ]

        for (event, expectedName) in cases {
            let classification = classify("atomcode", event, tool: "shell")
            #expect(classification.name == expectedName)
            #expect(classification.actionable == false)
            #expect(classification.notifiesNativeApprovalPrompt == false)
        }
    }
}
