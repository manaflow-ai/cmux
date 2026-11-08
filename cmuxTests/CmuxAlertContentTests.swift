import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Bounded modal alert content")
struct CmuxAlertContentTests {
    @Test @MainActor func userSizedDetailsScrollWithinVisibleScreenBudget() throws {
        let details = (1...80).map { "• Workspace \($0)" }.joined(separator: "\n")
        let flattenedText = "This will close 80 workspaces and all of their panels:\n\(details)"
        let content = CmuxAlertContent(
            flattenedText: flattenedText,
            separatingScrollableDetails: details
        )
        let alert = NSAlert()
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        let visibleFrame = NSRect(x: 0, y: 0, width: 1280, height: 600)
        content.apply(to: alert, visibleFrame: visibleFrame)

        let scrollView = try #require(alert.accessoryView as? CmuxAlertScrollableDetailsView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(alert.informativeText == "This will close 80 workspaces and all of their panels:")
        #expect(textView.string == details)
        #expect(scrollView.isContentHeightCapped)
        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.frame.height <= visibleFrame.height * 0.4)
        #expect(alert.buttons.map(\.title) == ["Close", "Cancel"])
    }

    @Test @MainActor func unstructuredLongTextAlsoFallsBackToBoundedScrolling() throws {
        let text = String(repeating: "Long command text\n", count: 80)
        let content = CmuxAlertContent(informativeText: text)
        let alert = NSAlert()

        content.apply(to: alert, visibleFrame: NSRect(x: 0, y: 0, width: 1024, height: 500))

        let scrollView = try #require(alert.accessoryView as? CmuxAlertScrollableDetailsView)
        #expect(alert.informativeText.isEmpty)
        #expect(scrollView.isContentHeightCapped)
        #expect(scrollView.frame.height <= 200)
    }

    @Test @MainActor func explicitlyScrollableTextUsesBoundedContent() throws {
        let text = String(repeating: "1234, 5678, 9012\n", count: 80)
        let content = CmuxAlertContent.scrollingAll(text)
        let alert = NSAlert()

        content.apply(to: alert, visibleFrame: NSRect(x: 0, y: 0, width: 1024, height: 500))

        let scrollView = try #require(alert.accessoryView as? CmuxAlertScrollableDetailsView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(alert.informativeText.isEmpty)
        #expect(textView.string == text)
        #expect(scrollView.isContentHeightCapped)
        #expect(scrollView.frame.height <= 200)
    }

    @Test @MainActor func shortStructuredTextKeepsNativeAlertLayout() {
        let details = "• Workspace 1\n• Workspace 2"
        let flattenedText = "This will close 2 workspaces:\n\(details)"
        let content = CmuxAlertContent(
            flattenedText: flattenedText,
            separatingScrollableDetails: details
        )
        let alert = NSAlert()

        content.apply(to: alert, visibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 800))

        #expect(alert.informativeText == flattenedText)
        #expect(alert.accessoryView == nil)
    }

    @Test func repeatedDetailsTextSeparatesTrailingOccurrence() {
        let details = "bash"
        let summary = "Working directory: /home/user/bash"
        let flattenedText = "\(summary)\n\n\(details)"

        let content = CmuxAlertContent(
            flattenedText: flattenedText,
            separatingScrollableDetails: details
        )

        #expect(content.informativeText == summary)
        #expect(content.scrollableDetails == details)
        #expect(content.flattenedText == flattenedText)
    }
}
