import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserPanelSessionRestoreTests {
    @Test
    func sessionRestoreDefersWebKitLoadUntilPanelIsVisible() throws {
        let url = try #require(URL(string: "https://example.com/restored"))
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        let originalWebView = panel.webView
        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: ["https://example.com/back"],
            forwardHistoryURLStrings: ["https://example.com/forward"]
        ))

        #expect(panel.webView === originalWebView)
        #expect(panel.currentURL == url)
        #expect(!panel.shouldRenderWebView)
        #expect(panel.webViewLifecycleState == .discarded)
        #expect(panel.shouldRenderWebViewForSessionSnapshot())
        #expect(panel.canGoBack)
        #expect(panel.canGoForward)

        panel.noteWebViewVisibility(true, reason: "test.visible")

        #expect(panel.shouldRenderWebView)
        #expect(panel.webViewLifecycleState == .liveVisible)
        #expect(panel.currentURL == url)
        #expect(panel.canGoBack)
        #expect(panel.canGoForward)

        let history = panel.sessionNavigationHistorySnapshot()
        #expect(history.backHistoryURLStrings == ["https://example.com/back"])
        #expect(history.forwardHistoryURLStrings == ["https://example.com/forward"])
    }

    @Test
    func linkActivatedCommandShiftClickBypassesCmuxNewTabForDefaultBrowser() {
        #expect(BrowserNavigationModifierBypassPolicy().shouldOpenInDefaultBrowser(
            navigationType: .linkActivated,
            modifierFlags: [.command, .shift],
            buttonNumber: 0
        ))
    }

    @Test
    func commandClickWithoutShiftDoesNotBypassToDefaultBrowser() {
        #expect(!BrowserNavigationModifierBypassPolicy().shouldOpenInDefaultBrowser(
            navigationType: .linkActivated,
            modifierFlags: [.command],
            buttonNumber: 0
        ))
    }

    @Test
    func middleClickDoesNotBypassToDefaultBrowser() {
        #expect(!BrowserNavigationModifierBypassPolicy().shouldOpenInDefaultBrowser(
            navigationType: .linkActivated,
            modifierFlags: [],
            buttonNumber: 2
        ))
    }

    @Test
    func commandShiftNonLinkNavigationDoesNotBypassToDefaultBrowser() {
        #expect(!BrowserNavigationModifierBypassPolicy().shouldOpenInDefaultBrowser(
            navigationType: .reload,
            modifierFlags: [.command, .shift],
            buttonNumber: 0
        ))
    }

    @Test
    func browserOpenRoutingPolicyBypassesCmuxBrowserOnlyForCommandShift() {
        let policy = BrowserOpenRoutingPolicy()
        #expect(policy.shouldOpenInCmuxBrowser(settingEnabled: true, modifierFlags: [.command]))
        #expect(!policy.shouldOpenInCmuxBrowser(settingEnabled: true, modifierFlags: [.command, .shift]))
        #expect(policy.shouldOpenInCmuxBrowser(settingEnabled: true, modifierFlags: [.command, .shift, .option]))
        #expect(!policy.shouldOpenInCmuxBrowser(settingEnabled: false, modifierFlags: [.command]))
        #expect(!policy.shouldOpenInCmuxBrowser(settingEnabled: false, modifierFlags: [.command, .shift]))
    }
}
