import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A pane keeps the page containers of its hidden tabs mounted at the shown
/// tab's rect. Only the shown tab's container may treat a click into a
/// Chromium page as choosing its page; otherwise a link click in the shown
/// tab switched the pane to an older tab.
@MainActor
@Suite
struct BrowserEnginePageContainerTests {
    private func mountedContainer(visible: Bool?) -> (NSWindow, BrowserEnginePageContainerView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let container = BrowserEnginePageContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(container)
        container.reportedVisible = visible
        return (window, container)
    }

    @Test
    func onlyTheShownTabsContainerOwnsPageClicks() {
        let (window, shown) = mountedContainer(visible: true)
        let hidden = BrowserEnginePageContainerView(frame: shown.frame)
        window.contentView?.addSubview(hidden)
        hidden.reportedVisible = false

        #expect(shown.showsPage)
        #expect(!hidden.isHiddenOrHasHiddenAncestor)
        #expect(!hidden.showsPage)
    }

    @Test
    func aContainerNotYetUpdatedDoesNotOwnPageClicks() {
        let (window, container) = mountedContainer(visible: nil)
        #expect(!container.showsPage)
        withExtendedLifetime(window) {}
    }

    @Test
    func aHiddenAncestorStillHidesTheShownPage() {
        let (window, container) = mountedContainer(visible: true)
        window.contentView?.isHidden = true
        #expect(!container.showsPage)
    }
}
