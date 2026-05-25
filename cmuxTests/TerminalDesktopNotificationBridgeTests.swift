import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TerminalDesktopNotificationBridgeTests: XCTestCase {
    func testActiveClaudeHookStillAllowsNonClaudeTerminalNotificationPayloads() {
        assertDelivered(
            title: "Codex question",
            body: "Does this notification work?",
            expectedTitle: "Codex question",
            expectedBody: "Does this notification work?",
            """
            A Claude hook PID in the workspace should not swallow unrelated terminal OSC \
            notifications such as Codex prompts.
            """
        )
    }

    func testActiveClaudeHookSuppressesGenericClaudeAttentionNotification() {
        assertSuppressed(title: "Claude Code", body: "Claude Code needs your attention")
    }

    func testActiveClaudeHookSuppressesGenericClaudeAttentionNotificationTitle() {
        assertSuppressed(title: "Claude Code needs your attention", body: "")
    }

    func testActiveClaudeHookSuppressesGenericClaudeInputNotificationTitle() {
        assertSuppressed(title: "Claude Code needs your input", body: "")
    }

    func testActiveClaudeHookSuppressesGenericClaudeInputNotificationTitleWithWhitespaceAndCase() {
        assertSuppressed(title: "  Claude   CODE  needs your INPUT \n", body: "")
    }

    func testActiveClaudeHookSuppressesGenericClaudeInputNotification() {
        assertSuppressed(title: "Claude Code", body: "Claude needs your input")
    }

    func testActiveClaudeHookSuppressesSplitGenericClaudeAttentionNotification() {
        assertSuppressed(title: "Claude Code", body: "needs your attention")
    }

    func testActiveClaudeHookSuppressesSplitGenericClaudeAttentionNotificationWithShortTitle() {
        assertSuppressed(title: "Claude", body: "needs your attention")
    }

    func testActiveClaudeHookSuppressesSplitGenericClaudeInputNotification() {
        assertSuppressed(title: "Claude", body: "needs your input")
    }

    func testNoClaudePIDAllowsMatchingClaudeAttentionNotification() {
        assertDelivered(
            workspaceAgentPIDs: [:],
            title: "Claude Code",
            body: "Claude needs your attention",
            expectedTitle: "Claude Code",
            expectedBody: "Claude needs your attention"
        )
    }

    func testZeroClaudePIDAllowsMatchingClaudeAttentionNotification() {
        assertDelivered(
            workspaceAgentPIDs: ["claude_code": pid_t(0)],
            title: "Claude Code",
            body: "Claude needs your attention",
            expectedTitle: "Claude Code",
            expectedBody: "Claude needs your attention"
        )
    }

    func testDisabledClaudeHooksAllowMatchingClaudeAttentionNotification() {
        assertDelivered(
            claudeHooksEnabled: false,
            title: "Claude Code",
            body: "Claude needs your attention",
            expectedTitle: "Claude Code",
            expectedBody: "Claude needs your attention"
        )
    }

    func testActiveClaudeHookAllowsCrossPhraseNonClaudeNotification() {
        assertDelivered(
            title: "claude.py review",
            body: "Codex needs your input on the diff",
            expectedTitle: "claude.py review",
            expectedBody: "Codex needs your input on the diff"
        )
    }

    func testActiveClaudeHookAllowsTitleBodyConcatenationFalsePositive() {
        assertDelivered(
            title: "From Claude",
            body: "needs your input on the review",
            expectedTitle: "From Claude",
            expectedBody: "needs your input on the review"
        )
    }

    func testActiveClaudeHookAllowsLongerTitleContainingGenericBannerText() {
        assertDelivered(
            title: "Claude needs your input on the review",
            body: "",
            expectedTitle: "Claude needs your input on the review",
            expectedBody: ""
        )
    }

    func testRouteFallsBackToTabTitle() {
        assertDelivered(
            title: "",
            body: "Body",
            fallbackTabTitle: "workspace-1",
            expectedTitle: "workspace-1",
            expectedBody: "Body"
        )
        assertDelivered(
            title: "Plan mode question",
            body: "Body",
            fallbackTabTitle: "workspace-1",
            expectedTitle: "Plan mode question",
            expectedBody: "Body"
        )
    }

    func testRouteFallsBackToTabTitleForWhitespaceOnlyTitle() {
        assertDelivered(
            title: " \n\t ",
            body: "Body",
            fallbackTabTitle: "workspace-1",
            expectedTitle: "workspace-1",
            expectedBody: "Body"
        )
    }

    func testRouteTrimsTitleWhitespace() {
        assertDelivered(
            title: "  Plan mode question\n",
            body: "Body",
            fallbackTabTitle: "workspace-1",
            expectedTitle: "Plan mode question",
            expectedBody: "Body"
        )
    }

    private func assertSuppressed(
        claudeHooksEnabled: Bool = true,
        workspaceAgentPIDs: [String: pid_t] = ["claude_code": pid_t(123)],
        title: String,
        body: String,
        fallbackTabTitle: String = "workspace-1",
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch makeRoute(
            claudeHooksEnabled: claudeHooksEnabled,
            workspaceAgentPIDs: workspaceAgentPIDs,
            title: title,
            body: body,
            fallbackTabTitle: fallbackTabTitle
        ) {
        case .suppressDuplicate:
            break
        case .deliver(let notification):
            XCTFail(
                message.isEmpty ? "Expected suppression, delivered \(notification)." : message,
                file: file,
                line: line
            )
        }
    }

    private func assertDelivered(
        claudeHooksEnabled: Bool = true,
        workspaceAgentPIDs: [String: pid_t] = ["claude_code": pid_t(123)],
        title: String,
        body: String,
        fallbackTabTitle: String = "workspace-1",
        expectedTitle: String,
        expectedBody: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch makeRoute(
            claudeHooksEnabled: claudeHooksEnabled,
            workspaceAgentPIDs: workspaceAgentPIDs,
            title: title,
            body: body,
            fallbackTabTitle: fallbackTabTitle
        ) {
        case .deliver(let notification):
            XCTAssertEqual(notification.title, expectedTitle, file: file, line: line)
            XCTAssertEqual(notification.body, expectedBody, file: file, line: line)
        case .suppressDuplicate:
            XCTFail(
                message.isEmpty ? "Expected delivery, suppressed duplicate." : message,
                file: file,
                line: line
            )
        }
    }

    private func makeRoute(
        claudeHooksEnabled: Bool,
        workspaceAgentPIDs: [String: pid_t],
        title: String,
        body: String,
        fallbackTabTitle: String
    ) -> TerminalDesktopNotificationBridge.Route {
        TerminalDesktopNotificationBridge.route(
            claudeHooksEnabled: claudeHooksEnabled,
            workspaceAgentPIDs: workspaceAgentPIDs,
            actionTitle: title,
            actionBody: body,
            fallbackTabTitle: fallbackTabTitle
        )
    }
}
