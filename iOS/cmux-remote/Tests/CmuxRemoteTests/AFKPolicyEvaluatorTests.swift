import XCTest
@testable import CmuxKit

/// Tests live in the app-target test bundle for the bits that involve the
/// strict-concurrency app surface, but `AFKPolicyEvaluator` is pure
/// CmuxKit. We test through the framework here so any future
/// "auto-approve a destructive op" regression trips a test before it
/// ships.
final class AFKPolicyEvaluatorTests: XCTestCase {

    private func decision(
        toolName: String? = nil,
        command: String? = nil,
        isReadOnly: Bool = false,
        destructive: Bool = false
    ) -> AgentDecision {
        AgentDecision(
            id: "d-1",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "claude",
            kind: .toolCall,
            summary: "",
            detail: command,
            toolName: toolName,
            command: command,
            isReadOnly: isReadOnly,
            choices: destructive
                ? [
                    AgentDecision.Choice(id: "allow", label: "Allow", style: .affirmative, requiresAuth: false),
                    AgentDecision.Choice(id: "deny", label: "Deny", style: .destructive, requiresAuth: false)
                ]
                : [
                    AgentDecision.Choice(id: "allow", label: "Allow", style: .affirmative, requiresAuth: false),
                    AgentDecision.Choice(id: "deny", label: "Deny", style: .default, requiresAuth: false)
                ],
            expiresAt: nil
        )
    }

    func testReadOnlyFileInspectionAutoApproves() {
        let policy = AFKPolicy()
        let evaluator = AFKPolicyEvaluator(policy: policy)
        let outcome = evaluator.evaluate(
            decision(toolName: "cat", command: "/etc/hosts", isReadOnly: true)
        )
        if case .autoApprove(let id, _) = outcome {
            XCTAssertEqual(id, "allow")
        } else {
            XCTFail("expected autoApprove, got \(outcome)")
        }
    }

    func testReadOnlyToolWithoutReadOnlyFlagDoesNotAutoApprove() {
        // Regression: previously a `cat` tool would auto-approve even
        // when the agent did NOT flag the call as read-only — defeats the
        // `onlyReadOnly: true` constraint that's now actually enforced.
        let policy = AFKPolicy()
        let evaluator = AFKPolicyEvaluator(policy: policy)
        let outcome = evaluator.evaluate(
            decision(toolName: "cat", command: "/etc/hosts", isReadOnly: false)
        )
        XCTAssertEqual(outcome, .ask, "Read-only-only rule must NOT fire for non-read-only calls")
    }

    func testWriteToolNeverAutoApproves() {
        // `sed -i` is a write; previously the first-token-of-detail
        // matcher tripped the read-only rule. With the structured
        // tool_name match this should never auto-approve.
        let policy = AFKPolicy()
        let evaluator = AFKPolicyEvaluator(policy: policy)
        let outcome = evaluator.evaluate(
            decision(toolName: "sed", command: "sed -i 's/x/y/' f", isReadOnly: false)
        )
        XCTAssertEqual(outcome, .ask)
    }

    func testRmRfBlocksEvenIfEarlierRuleMatched() {
        let policy = AFKPolicy()
        let evaluator = AFKPolicyEvaluator(policy: policy)
        let outcome = evaluator.evaluate(
            decision(toolName: nil, command: "rm -rf node_modules")
        )
        XCTAssertEqual(outcome, .ask)
    }

    func testChainedCommandDoesNotAutoApproveGitRule() {
        // Regression: `git diff; rm -rf foo` previously slipped through
        // the read-only `git diff` regex because the pattern only used
        // `\b` after the verb. The fixed regex anchors `$` and rejects
        // shell metacharacters in the trailing args.
        let policy = AFKPolicy()
        let evaluator = AFKPolicyEvaluator(policy: policy)
        let outcome = evaluator.evaluate(
            decision(toolName: nil, command: "git diff; rm -rf node_modules", isReadOnly: true)
        )
        XCTAssertEqual(outcome, .ask)
    }

    func testPlainGitDiffStillAutoApproves() {
        let policy = AFKPolicy()
        let evaluator = AFKPolicyEvaluator(policy: policy)
        let outcome = evaluator.evaluate(
            decision(toolName: nil, command: "git diff", isReadOnly: true)
        )
        if case .autoApprove = outcome { return }
        XCTFail("expected autoApprove for plain `git diff`")
    }

    func testLegacyUSDBudgetsDecodeToIntegerCents() throws {
        let json = """
        {
          "autoApproveRules": [],
          "snoozeMinutes": 10,
          "watchdogStuckMinutes": 5,
          "notifyOnStuck": true,
          "requireBiometricForDestructive": true,
          "perWorkspaceCostBudgetUSD": {
            "workspace:1": 12.34,
            "workspace:2": 0.015
          },
          "afkSummaryHour": 8
        }
        """.data(using: .utf8)!

        let policy = try JSONDecoder().decode(AFKPolicy.self, from: json)

        XCTAssertEqual(policy.perWorkspaceCostBudgetCents["workspace:1"], 1234)
        XCTAssertEqual(policy.perWorkspaceCostBudgetCents["workspace:2"], 2)
    }

    func testBudgetsEncodeAsIntegerCentsOnly() throws {
        let policy = AFKPolicy(perWorkspaceCostBudgetCents: ["workspace:1": 1234])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any]
        let cents = object?["perWorkspaceCostBudgetCents"] as? [String: Any]

        XCTAssertEqual((cents?["workspace:1"] as? NSNumber)?.intValue, 1234)
        XCTAssertNil(object?["perWorkspaceCostBudgetUSD"])
    }
}
