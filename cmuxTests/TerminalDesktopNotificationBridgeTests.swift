import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TerminalDesktopNotificationBridgeTests: XCTestCase {
    func testActiveClaudeHookStillAllowsNonClaudeTerminalNotificationPayloads() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "Codex question",
            body: "Does this notification work?"
        )

        XCTAssertFalse(
            suppressed,
            "A Claude hook PID in the workspace should not swallow unrelated terminal OSC notifications such as Codex prompts."
        )
    }

    func testActiveClaudeHookSuppressesGenericClaudeAttentionNotification() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "Claude Code",
            body: "Claude Code needs your attention"
        )

        XCTAssertTrue(suppressed)
    }

    func testActiveClaudeHookSuppressesGenericClaudeAttentionNotificationTitle() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "Claude Code needs your attention",
            body: ""
        )

        XCTAssertTrue(suppressed)
    }

    func testActiveClaudeHookSuppressesGenericClaudeInputNotification() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "Claude Code",
            body: "Claude needs your input"
        )

        XCTAssertTrue(suppressed)
    }

    func testActiveClaudeHookSuppressesSplitGenericClaudeAttentionNotification() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "Claude Code",
            body: "needs your attention"
        )

        XCTAssertTrue(suppressed)
    }

    func testActiveClaudeHookSuppressesSplitGenericClaudeInputNotification() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "Claude",
            body: "needs your input"
        )

        XCTAssertTrue(suppressed)
    }

    func testNoClaudePIDAllowsMatchingClaudeAttentionNotification() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: [:],
            title: "Claude Code",
            body: "Claude needs your attention"
        )

        XCTAssertFalse(suppressed)
    }

    func testZeroClaudePIDAllowsMatchingClaudeAttentionNotification() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(0)],
            title: "Claude Code",
            body: "Claude needs your attention"
        )

        XCTAssertFalse(suppressed)
    }

    func testDisabledClaudeHooksAllowMatchingClaudeAttentionNotification() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: false,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "Claude Code",
            body: "Claude needs your attention"
        )

        XCTAssertFalse(suppressed)
    }

    func testActiveClaudeHookAllowsCrossPhraseNonClaudeNotification() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "claude.py review",
            body: "Codex needs your input on the diff"
        )

        XCTAssertFalse(suppressed)
    }

    func testActiveClaudeHookAllowsTitleBodyConcatenationFalsePositive() {
        let suppressed = TerminalDesktopNotificationBridge.shouldSuppressNotification(
            claudeHooksEnabled: true,
            workspaceAgentPIDs: ["claude_code": pid_t(123)],
            title: "From Claude",
            body: "needs your input on the review"
        )

        XCTAssertFalse(suppressed)
    }

    func testResolvedTitleFallsBackToTabTitle() {
        XCTAssertEqual(
            TerminalDesktopNotificationBridge.resolvedTitle(
                actionTitle: "",
                fallbackTabTitle: "workspace-1"
            ),
            "workspace-1"
        )
        XCTAssertEqual(
            TerminalDesktopNotificationBridge.resolvedTitle(
                actionTitle: "Plan mode question",
                fallbackTabTitle: "workspace-1"
            ),
            "Plan mode question"
        )
    }
}
