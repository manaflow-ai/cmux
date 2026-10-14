import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Browser mobile stream teardown")
struct BrowserMobileStreamTeardownTests {
    @Test("replacing a web view removes the mobile dirty beacon handler")
    func replacingWebViewRemovesMobileDirtyBeaconHandler() {
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: URL(string: "about:blank")!)
        defer { panel.close() }
        let handlerID = UUID()
        panel.addMobileBrowserStreamSignalHandler(id: handlerID) { _ in }
        #expect(panel.mobileBrowserStreamMessageHandler != nil)

        panel.tearDownWebViewBeforeReplacement(panel.webView, reason: "test")

        #expect(panel.mobileBrowserStreamMessageHandler == nil)
        panel.removeMobileBrowserStreamSignalHandler(id: handlerID)
    }
}
