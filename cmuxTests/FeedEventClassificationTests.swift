import Darwin
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
    private func classify(
        _ source: String,
        _ event: String,
        tool: String = ""
    )
        -> (name: String, actionable: Bool)
    {
        let result = FeedEventClassifier.classify(
            source: source,
            event: event,
            toolName: tool
        )
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

    /// Codex pre-tool telemetry stays non-blocking, but a dedicated
    /// `PermissionRequest` must never be swallowed. Once Codex says it is
    /// waiting for permission, Feed owns surfacing that wait consistently.
    @Test func codexDedicatedPermissionRequestIsActionable() {
        #expect(classify("codex", "PreToolUse", tool: "shell").actionable == false)
        #expect(classify("codex", "beforeShellExecution", tool: "shell").actionable == false)
        #expect(classify("codex", "beforeShellExecution", tool: "shell").name == "PreToolUse")
        #expect(classify("codex", "PermissionRequest", tool: "shell").name == "PermissionRequest")
        #expect(classify("codex", "PermissionRequest", tool: "shell").actionable == true)
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

    /// Antigravity has not migrated its native tool lifecycle yet, so its raw
    /// pre-tool signal stays telemetry. Cursor invokes both shell and
    /// structured tool-start hooks before its native permission evaluation,
    /// so both stay telemetry regardless of the sandbox execution policy.
    @Test func cursorShellStartStaysTelemetryUntilNativeApprovalDecision() {
        #expect(classify("antigravity", "PreToolUse", tool: "Bash").actionable == false)
        let shellStart = classify("cursor", "beforeShellExecution", tool: "Bash")
        #expect(shellStart.name == "PreToolUse")
        #expect(shellStart.actionable == false)
        let toolStart = classify("cursor", "preToolUse", tool: "Shell")
        #expect(toolStart.name == "PreToolUse")
        #expect(toolStart.actionable == false)
    }

    @Test func cursorNativeApprovalLogDistinguishesPromptFromAutoApproval() {
        let requested = CursorNativeApprovalLogClassifier.classify(
            line: """
            {"msg":"Shell permissions: requesting shell approval","toolCallId":"call-1"}
            """,
            expectedToolCallId: "call-1"
        )
        #expect(requested == .approvalRequested(toolCallId: "call-1"))

        let autoApproved = CursorNativeApprovalLogClassifier.classify(
            line: """
            {"msg":"Shell permissions: auto-approved shell command","toolCallId":"call-2"}
            """,
            expectedToolCallId: "call-2"
        )
        #expect(autoApproved == .autoApproved(toolCallId: "call-2"))
        #expect(
            CursorNativeApprovalLogClassifier.classify(
                line: """
                {"msg":"Shell permissions: requesting shell approval","toolCallId":"other-call"}
                """,
                expectedToolCallId: "call-1"
            ) == nil
        )
        #expect(
            CursorNativeApprovalLogClassifier.classify(
                line: """
                {"msg":"running command","command":"printf 'Shell permissions: requesting shell approval'","toolCallId":"call-3"}
                """
            ) == nil
        )
        #expect(
            CursorNativeApprovalLogClassifier.classify(
                line: """
                {"msg":"Shell permissions: requesting shell approval","command":"printf '\\\"toolCallId\\\":\\\"forged-call\\\"'","toolCallId":"real-call"}
                """,
                expectedToolCallId: "real-call"
            ) == .approvalRequested(toolCallId: "real-call")
        )
    }

    /// Every built-in integration must have an explicit approval contract.
    /// A familiar dedicated permission event from any built-in source is
    /// therefore actionable; only genuinely unknown third-party sources use
    /// the neutral telemetry fallback.
    @Test func everyBuiltInAgentHasMandatoryPermissionSemantics() {
        for integration in BuiltInAgentIntegration.allCases {
            let source = integration.feedSourceName
            let permission = classify(
                source,
                "PermissionRequest",
                tool: "Bash"
            )
            #expect(
                permission.name == "PermissionRequest",
                "Missing permission mapping for \(source)"
            )
            #expect(
                permission.actionable,
                "Permission wait was swallowed for \(source)"
            )
        }
    }

    @Test func preToolOnlyAgentsInferSideEffectingApproval() {
        let integrations = BuiltInAgentIntegration.allCases.filter {
            $0.approvalDetectionMechanism
                == .sideEffectingToolStartInference
        }
        #expect(
            !integrations.isEmpty,
            "The approval inference contract must cover at least one agent."
        )
        for integration in integrations {
            let source = integration.feedSourceName
            let sideEffecting = classify(
                source,
                "PreToolUse",
                tool: "Bash"
            )
            #expect(sideEffecting.name == "PermissionRequest")
            #expect(sideEffecting.actionable)
            #expect(
                classify(
                    source,
                    "PreToolUse",
                    tool: "Read"
                ).actionable == false
            )
        }
    }

    @Test func ampAndCursorRequireNativePostPolicyApprovalEvidence() {
        #expect(
            BuiltInAgentIntegration.amp.approvalDetectionMechanism
                == .nativePostPolicyObserver
        )
        #expect(
            BuiltInAgentIntegration.cursor.approvalDetectionMechanism
                == .nativePostPolicyObserver
        )
        #expect(classify("amp", "PreToolUse", tool: "Bash").actionable == false)
        #expect(
            classify("cursor", "PreToolUse", tool: "Bash").actionable
                == false
        )
    }

    /// `CMUXCLI.agentDefs` maps `genericHookIntegrations` directly, while the
    /// app lifecycle consumes `allowedStatusKeys`. Verify those shared catalog
    /// values cover every built-in exactly once.
    @Test func sharedIntegrationContractProvidesCompleteCatalogs() {
        let allIntegrations = Set(BuiltInAgentIntegration.allCases)
        let genericIntegrations = Set(
            BuiltInAgentIntegration.genericHookIntegrations
        )
        #expect(
            genericIntegrations
                == allIntegrations.subtracting([.claude])
        )
        let statusKeys = BuiltInAgentIntegration.allCases.map(\.statusKey)
        #expect(
            Set(statusKeys)
                == AgentHibernationLifecycleStatusKeys.allowedStatusKeys
        )
        #expect(
            statusKeys.count
                == AgentHibernationLifecycleStatusKeys.allowedStatusKeys.count,
            "Every built-in integration must have a unique lifecycle key."
        )
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
}

@Suite("Shared agent turn settlement")
struct AgentTurnSettlementTests {
    @Test func prematureAmpEndWithBackgroundWorkStaysRunning() {
        let decision = AgentTurnSettlementReconciler.resolve(
            integration: .amp,
            evidence: AgentTurnSettlementEvidence(
                boundary: .turnEnd,
                activeBackgroundWorkCount: 1,
                processLiveness: .live
            )
        )

        #expect(decision == .keepRunning)
    }

    @Test func settledAmpTurnWithNoBackgroundWorkCompletes() {
        let decision = AgentTurnSettlementReconciler.resolve(
            integration: .amp,
            evidence: AgentTurnSettlementEvidence(
                boundary: .settled,
                activeBackgroundWorkCount: 0,
                processLiveness: .live
            )
        )

        #expect(decision == .settle)
    }

    @Test func ampTurnEndStillRequiresExplicitSettlementAfterWorkDrains() {
        let decision = AgentTurnSettlementReconciler.resolve(
            integration: .amp,
            evidence: AgentTurnSettlementEvidence(
                boundary: .turnEnd,
                activeBackgroundWorkCount: 0,
                processLiveness: .live
            )
        )

        #expect(decision == .keepRunning)
    }

    @Test func codexStopWithStructuredActiveSubagentStaysRunning() {
        let decision = AgentTurnSettlementReconciler.resolve(
            integration: .codex,
            evidence: AgentTurnSettlementEvidence(
                boundary: .turnEnd,
                activeBackgroundWorkCount: 1,
                processLiveness: .live
            )
        )

        #expect(decision == .keepRunning)
    }

    @Test func exitedProcessTerminatesWithoutFalseCompletion() {
        let decision = AgentTurnSettlementReconciler.resolve(
            integration: .cursor,
            evidence: AgentTurnSettlementEvidence(
                boundary: .turnEnd,
                activeBackgroundWorkCount: 0,
                processLiveness: .exited
            )
        )

        #expect(decision == .terminateWithoutCompletion)
    }

    @Test func reusedPIDGenerationIsNotTreatedAsLive() {
        let liveness = AgentTurnProcessLiveness.observe(
            pid: Int(getpid()),
            expectedStartSeconds: Int64.min,
            expectedStartMicroseconds: Int64.min
        )

        #expect(liveness == .exited)
    }

    @Test func supersededEndCannotClearOrTerminateNewerTurn() {
        let freshness = AgentTurnSettlementReconciler.classifyTurnFreshness(
            incomingTurnId: "turn-old",
            activeTurnIds: ["turn-new"],
            latestTurnId: "turn-new",
            terminalTurnIds: []
        )
        let decision = AgentTurnSettlementReconciler.resolve(
            integration: .amp,
            evidence: AgentTurnSettlementEvidence(
                boundary: .settled,
                activeBackgroundWorkCount: 0,
                processLiveness: .exited,
                turnFreshness: freshness
            )
        )

        #expect(freshness == .superseded)
        #expect(decision == .keepRunning)
    }

    @Test func anonymousActiveDepthDoesNotMakeParentStopStale() {
        let freshness = AgentTurnSettlementReconciler.classifyTurnFreshness(
            incomingTurnId: "parent-turn",
            activeTurnIds: [],
            activeTurnDepth: 1,
            latestTurnId: "completed-child-turn",
            terminalTurnIds: ["completed-child-turn"]
        )

        #expect(freshness == .unknown)
    }
}
