import AppKit
import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Native input is WebKit's path: a panel that shows another engine's page
/// must refuse it rather than send AppKit events to its hidden WKWebView.
@MainActor
@Suite(.serialized) struct BrowserPanelNativeInputEngineTests {
    @Test func aChromiumPanelRefusesNativeInput() async {
        let provider = BrowserPanelEngineTests.FakeChromiumProvider()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            engineChoice: BrowserEngineChoice(engine: .chromium, source: .explicit),
            engineRuntime: BrowserEngineRuntime(
                registry: BrowserEngineRegistry(providers: [provider]),
                environment: [:],
                defaults: UserDefaults(suiteName: "BrowserPanelNativeInputEngineTests.\(UUID().uuidString)")!
            )
        )
        defer { panel.close() }
        #expect(panel.automationEnginePage != nil)

        await #expect(throws: BrowserRawInputFailure.notWebKit) {
            _ = try await panel.deliverNativeInput([.insertText("a")], to: panel.webView)
        }
        await #expect(throws: BrowserRawInputFailure.notWebKit) {
            _ = try await panel.deliverNativeInput(
                [.mouseMoved(.point(CGPoint(x: 1, y: 1)), modifiers: [])],
                to: panel.webView
            )
        }
    }
}
