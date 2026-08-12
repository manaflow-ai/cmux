import AppKit
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Custom sidebar input focus ownership")
@MainActor
struct CustomSidebarInputFocusOwnershipTests {
    @Test("the main window focus controller recognizes the hosted sidebar web view")
    func webViewOwnsRightSidebarFocus() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: nil
        )
        let webView = CustomSidebarInputWebView(frame: .zero)

        #expect(controller.ownsRightSidebarFocus(webView))
    }
}
