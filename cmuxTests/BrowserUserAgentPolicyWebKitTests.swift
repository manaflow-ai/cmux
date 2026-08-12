import Foundation
import Testing
import WebKit
import CmuxBrowser

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct BrowserUserAgentPolicyWebKitTests {
    @Test func restartRequestChangesIdentityOnceAndStripsStaleHeader() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var request = URLRequest(url: URL(string: "https://workspace.google.com/")!)
        request.setValue("stale-agent", forHTTPHeaderField: "User-Agent")

        let restartRequest = try #require(
            webView.browserUserAgentPolicyRestartRequest(for: request)
        )

        #expect(restartRequest.value(forHTTPHeaderField: "User-Agent") == nil)
        #expect(webView.customUserAgent == BrowserUserAgentPolicy.system.safariCompatibleUserAgent)
        #expect(webView.browserUserAgentPolicyRestartRequest(for: restartRequest) == nil)
    }

    @Test func restartRequestReplacesStaleSheetsIdentity() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = "stale-agent"
        var request = URLRequest(
            url: URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        )
        request.setValue("stale-agent", forHTTPHeaderField: "User-Agent")

        let restartRequest = try #require(
            webView.browserUserAgentPolicyRestartRequest(for: request)
        )

        #expect(restartRequest.value(forHTTPHeaderField: "User-Agent") == nil)
        #expect(webView.customUserAgent == BrowserUserAgentPolicy.system.safariCompatibleUserAgent)
        #expect(webView.browserUserAgentPolicyRestartRequest(for: restartRequest) == nil)
    }

    @Test func sheetsRequestUsesCurrentSafariForNetworkAndNavigatorIdentity() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let request = URLRequest(
            url: URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        )

        let restartRequest = try #require(
            webView.browserUserAgentPolicyRestartRequest(for: request)
        )

        #expect(restartRequest.value(forHTTPHeaderField: "User-Agent") == nil)
        #expect(webView.customUserAgent == BrowserUserAgentPolicy.system.safariCompatibleUserAgent)
        #expect(webView.browserUserAgentPolicyRestartRequest(for: restartRequest) == nil)
    }

    @Test func emptyCustomUserAgentIsNotAcceptedAsSheetsIdentity() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = ""
        let request = URLRequest(
            url: URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        )

        let restartRequest = try #require(
            webView.browserUserAgentPolicyRestartRequest(for: request)
        )

        #expect(restartRequest.value(forHTTPHeaderField: "User-Agent") == nil)
        #expect(webView.customUserAgent == BrowserUserAgentPolicy.system.safariCompatibleUserAgent)
        #expect(webView.browserUserAgentPolicyRestartRequest(for: restartRequest) == nil)
    }

    @Test func restartRequestIgnoresSubframesAndNewWindowTargets() throws {
        let request = URLRequest(url: URL(string: "https://workspace.google.com/")!)

        for targetFrameIsMainFrame: Bool? in [false, nil] {
            let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

            #expect(webView.browserUserAgentPolicyRestartRequest(
                for: request,
                targetFrameIsMainFrame: targetFrameIsMainFrame
            ) == nil)
            #expect(webView.customUserAgent?.isEmpty != false)
        }
    }

    @Test func nonWebDestinationClearsCustomIdentityWithoutRestarting() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = BrowserUserAgentPolicy.system.safariCompatibleUserAgent
        let request = URLRequest(url: URL(fileURLWithPath: "/tmp/example.html"))

        #expect(webView.browserUserAgentPolicyRestartRequest(for: request) == nil)
        #expect(webView.customUserAgent?.isEmpty != false)
    }
}
