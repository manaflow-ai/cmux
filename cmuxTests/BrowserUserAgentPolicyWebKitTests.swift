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

    @Test func restartRequestCanRestoreEmbeddedIdentityForSheets() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = BrowserUserAgentPolicy.system.safariCompatibleUserAgent
        let request = URLRequest(
            url: URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        )

        let restartRequest = try #require(
            webView.browserUserAgentPolicyRestartRequest(for: request)
        )

        #expect(webView.customUserAgent?.isEmpty != false)
        #expect(webView.browserUserAgentPolicyRestartRequest(for: restartRequest) == nil)
    }

    @Test func emptyCustomUserAgentIsAlreadyEmbeddedIdentityForSheets() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = ""
        let request = URLRequest(
            url: URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        )

        #expect(webView.browserUserAgentPolicyRestartRequest(for: request) == nil)
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

    @Test func sheetsDestinationTreatsEmptyReportedIdentityAsWebKitDefault() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Some macOS versions report the native identity as "" instead of nil
        // after a restart clears the custom identity; both must satisfy the
        // webKitDefault resolution or Sheets restarts forever (issue #9462).
        webView.customUserAgent = ""
        let request = URLRequest(
            url: URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        )

        #expect(BrowserUserAgentPolicy.system.resolution(for: request.url) == .webKitDefault)
        #expect(webView.browserUserAgentPolicyRestartRequest(for: request) == nil)
    }

    @Test func sheetsDestinationRestartsAtMostOnceWhenIdentityNeverConverges() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let request = URLRequest(
            url: URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        )
        var decisions: [WKNavigationActionPolicy] = []
        var replacementRequests: [URLRequest] = []

        webView.customUserAgent = BrowserUserAgentPolicy.system.safariCompatibleUserAgent
        #expect(webView.restartNavigationForBrowserUserAgentPolicyIfNeeded(
            for: request,
            targetFrameIsMainFrame: true,
            decisionHandler: { decisions.append($0) },
            startReplacement: { replacementRequests.append($0) }
        ))
        #expect(decisions == [.cancel])
        #expect((webView.customUserAgent ?? "").isEmpty)
        let replacementRequest = try #require(replacementRequests.first)

        // Simulate a WebKit whose reported identity never matches the resolved
        // policy: the replacement pass must proceed instead of restarting again.
        webView.customUserAgent = BrowserUserAgentPolicy.system.safariCompatibleUserAgent
        #expect(!webView.restartNavigationForBrowserUserAgentPolicyIfNeeded(
            for: replacementRequest,
            targetFrameIsMainFrame: true,
            decisionHandler: { decisions.append($0) },
            startReplacement: { replacementRequests.append($0) }
        ))
        #expect(decisions == [.cancel])
        #expect(replacementRequests.count == 1)

        // A later navigation to the same destination may restart once again.
        webView.customUserAgent = BrowserUserAgentPolicy.system.safariCompatibleUserAgent
        #expect(webView.restartNavigationForBrowserUserAgentPolicyIfNeeded(
            for: request,
            targetFrameIsMainFrame: true,
            decisionHandler: { decisions.append($0) },
            startReplacement: { replacementRequests.append($0) }
        ))
        #expect(decisions == [.cancel, .cancel])
        #expect(replacementRequests.count == 2)
    }
}
