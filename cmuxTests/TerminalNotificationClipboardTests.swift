import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationClipboardTests: XCTestCase {
    private func makeNotification(
        title: String = "Task finished",
        subtitle: String = "",
        body: String = "All 12 tests passed"
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )
    }

    func testClipboardTextIncludesWorkspaceTitleTitleAndBody() {
        let text = makeNotification().clipboardText(workspaceTitle: "cmux")
        XCTAssertEqual(text, "cmux\nTask finished\nAll 12 tests passed")
    }

    func testClipboardTextOmitsEmptyWorkspaceTitle() {
        XCTAssertEqual(makeNotification().clipboardText(workspaceTitle: "  "), "Task finished\nAll 12 tests passed")
        XCTAssertEqual(makeNotification().clipboardText(workspaceTitle: nil), "Task finished\nAll 12 tests passed")
    }

    func testClipboardTextFallsBackToSubtitleWhenBodyIsEmpty() {
        let text = makeNotification(subtitle: "Claude Code", body: "").clipboardText()
        XCTAssertEqual(text, "Task finished\nClaude Code")
    }

    func testClipboardTextDropsDetailThatRepeatsTitle() {
        let text = makeNotification(body: "Task finished").clipboardText()
        XCTAssertEqual(text, "Task finished")
    }

    func testCopyWritesPlainTextToPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.tests.notificationClipboard.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let written = TerminalNotificationClipboard.copy(makeNotification(), workspaceTitle: "cmux", pasteboard: pasteboard)

        XCTAssertEqual(written, "cmux\nTask finished\nAll 12 tests passed")
        XCTAssertEqual(pasteboard.string(forType: .string), written)
    }
}
