import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The hibernation lifecycle correctness for every coding-agent type funnels through
/// one shared decision: `agentNotificationIsBlockingPrompt`. Both the dedicated Claude
/// hook lane and the generic agent-hook lane (codex, grok, gemini, opencode, cursor,
/// kiro, antigravity, rovodev, copilot, codebuddy, factory, qoder, hermes-agent, pi,
/// amp, and custom vault agents) use it to decide whether a Notification may flip the
/// lifecycle to `.needsInput`. A routine "waiting for input" reminder must NOT be
/// blocking, or it clobbers the Stop hook's `.idle` and the pane never hibernates
/// (the "only codex hibernates" class of bug). This suite pins that contract.
final class AgentNotificationBlockingClassifierTests: XCTestCase {
    func testGenuinelyBlockingNotificationsAreBlocking() {
        // Permission / approval prompts and errors are the only notifications a user
        // must act on; they keep the pane live across every agent type.
        let blocking = [
            "permission",
            "approve",
            "approval",
            "permission_prompt",
            "Claude needs your permission to use Bash",
            "Approval needed",
            "Codex requested approval to run a command",
            "error",
            "failed",
            "failure",
            "exception",
            "grok reported an error",
            "command failed with exit code 1",
            "uncaught exception in tool call",
        ]
        for message in blocking {
            XCTAssertTrue(
                agentNotificationIsBlockingPrompt(signal: "", message: message),
                "Expected blocking for message \(message.debugDescription)"
            )
        }
    }

    func testRoutineNotificationsAreNotBlocking() {
        // Routine waiting/idle reminders, completions, and generic attention must NOT
        // be blocking: they leave the Stop hook's `.idle` intact so the agent hibernates.
        let nonBlocking = [
            "Claude is waiting for your input",
            "waiting for input",
            "Claude is waiting for your response",
            "Turn complete in 1.0s.",
            "Task completed",
            "done",
            "Claude needs your input",
            "needs your attention",
            "Please confirm to continue",
            "ready",
            "idle",
            "",
        ]
        for message in nonBlocking {
            XCTAssertFalse(
                agentNotificationIsBlockingPrompt(signal: "", message: message),
                "Expected NOT blocking for message \(message.debugDescription)"
            )
        }
    }

    func testSignalFieldAlsoDrivesBlocking() {
        // The blocking decision considers the structured signal (event/reason), not just
        // the free-text message — a `reason: permission_prompt` with an empty message is
        // still blocking.
        XCTAssertTrue(agentNotificationIsBlockingPrompt(signal: "permission_prompt", message: ""))
        XCTAssertTrue(agentNotificationIsBlockingPrompt(signal: "error", message: "something happened"))
        XCTAssertFalse(agentNotificationIsBlockingPrompt(signal: "notification", message: "waiting"))
    }
}

/// Routing guard for agents whose `Notification` event is a permission/attention channel
/// (turn-end is carried separately by `Stop`). Routing such a Notification to the `stop`
/// subcommand forces the pane `.idle` and lets it hibernate while a permission prompt is
/// live. These must route through the `notification` lane so the blocking classifier above
/// decides correctly. This pins the agent-definition wiring so the regression can't silently
/// return.
final class AgentNotificationRoutingTests: XCTestCase {
    private func subcommand(for agentName: String, agentEvent: String) -> String? {
        guard let def = CMUXCLI.agentDef(named: agentName) else { return nil }
        return def.events.first { $0.agentEvent == agentEvent }?.cmuxSubcommand
    }

    func testNotificationRoutesToNotificationLaneNotStop() {
        // Agents that have BOTH a Stop turn-boundary and a Notification attention channel.
        for agent in ["copilot", "codebuddy", "factory"] {
            XCTAssertEqual(
                subcommand(for: agent, agentEvent: "Stop"), "stop",
                "\(agent) Stop should remain the turn boundary"
            )
            XCTAssertEqual(
                subcommand(for: agent, agentEvent: "Notification"), "notification",
                "\(agent) Notification must route through the notification lane, not stop, "
                    + "so a live permission prompt cannot be forced idle and hibernated"
            )
        }
    }
}
