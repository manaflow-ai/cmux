import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Ghostty terminal scroll view")
struct GhosttyScrollViewTests {
    @Test func terminalViewportOwnsItsContentInsets() {
        let scrollView = GhosttyScrollView(frame: .zero)

        #expect(
            !scrollView.automaticallyAdjustsContentInsets,
            "the terminal viewport must not inherit a second top inset from window chrome"
        )
        #expect(scrollView.contentInsets.top == 0)
        #expect(scrollView.contentInsets.left == 0)
        #expect(scrollView.contentInsets.bottom == 0)
        #expect(scrollView.contentInsets.right == 0)
    }
}
