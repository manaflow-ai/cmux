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

    @Test func linkHoverIndicatorIsCreatedLazily() {
        let hostedView = makeHostedView()

        #expect(linkHoverIndicators(in: hostedView).isEmpty)
    }

    @Test func firstNonemptyLinkHoverURLCreatesAndShowsIndicator() throws {
        let hostedView = makeHostedView()

        hostedView.setLinkHoverURL(nil)
        hostedView.setLinkHoverURL("")
        #expect(linkHoverIndicators(in: hostedView).isEmpty)

        hostedView.setLinkHoverURL("https://example.com/first")

        let indicator = try #require(linkHoverIndicators(in: hostedView).only)
        #expect(!indicator.isHidden)
    }

    @Test func subsequentLinkHoverURLsReuseIndicator() throws {
        let hostedView = makeHostedView()
        hostedView.setLinkHoverURL("https://example.com/first")
        let firstIndicator = try #require(linkHoverIndicators(in: hostedView).only)

        hostedView.setLinkHoverURL("https://example.com/second")

        let secondIndicator = try #require(linkHoverIndicators(in: hostedView).only)
        #expect(secondIndicator === firstIndicator)
        #expect(!secondIndicator.isHidden)
    }

    @Test func clearingLinkHoverURLHidesReusableIndicator() throws {
        let hostedView = makeHostedView()
        hostedView.setLinkHoverURL("https://example.com")
        let indicator = try #require(linkHoverIndicators(in: hostedView).only)

        hostedView.setLinkHoverURL(nil)

        #expect(indicator.isHidden)
        #expect(linkHoverIndicators(in: hostedView).only === indicator)
    }

    @Test func releasingHostedViewReleasesLinkHoverIndicator() {
        weak var releasedIndicator: TerminalLinkHoverIndicatorView?

        autoreleasepool {
            let hostedView = makeHostedView()
            hostedView.setLinkHoverURL("https://example.com")
            releasedIndicator = linkHoverIndicators(in: hostedView).only
            #expect(releasedIndicator != nil)
        }

        #expect(releasedIndicator == nil)
    }

    private func makeHostedView() -> GhosttySurfaceScrollView {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: frame))
        hostedView.frame = frame
        hostedView.layoutSubtreeIfNeeded()
        return hostedView
    }

    private func linkHoverIndicators(in hostedView: GhosttySurfaceScrollView) -> [TerminalLinkHoverIndicatorView] {
        hostedView.subviews.compactMap { $0 as? TerminalLinkHoverIndicatorView }
    }
}
