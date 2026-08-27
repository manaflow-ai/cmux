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

    @Test func restartPolicyCancelsOnceBeforeStartingReplacement() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let request = URLRequest(url: URL(string: "https://workspace.google.com/")!)
        var policies: [WKNavigationActionPolicy] = []
        var replacementRequests: [URLRequest] = []
        var willRestartCount = 0

        let restarted = webView.restartNavigationForBrowserUserAgentPolicyIfNeeded(
            request: request,
            targetFrameIsMainFrame: true,
            decisionHandler: { policies.append($0) },
            willRestart: { willRestartCount += 1 },
            startReplacement: { replacementRequests.append($0) }
        )

        #expect(restarted)
        #expect(policies.count == 1)
        #expect(policies.first == .cancel)
        #expect(willRestartCount == 1)
        #expect(replacementRequests.count == 1)
        #expect(replacementRequests.first?.value(forHTTPHeaderField: "User-Agent") == nil)

        let replacementRequest = try #require(replacementRequests.first)
        let restartedAgain = webView.restartNavigationForBrowserUserAgentPolicyIfNeeded(
            request: replacementRequest,
            targetFrameIsMainFrame: true,
            decisionHandler: { policies.append($0) },
            startReplacement: { replacementRequests.append($0) }
        )

        #expect(!restartedAgain)
        #expect(policies.count == 1)
        #expect(replacementRequests.count == 1)
    }
}

@MainActor
@Suite
struct BrowserNavigationDecisionHandlerTests {
    @Test
    func navigationDecisionHandlerInvokesUnderlyingHandlerAtMostOnce() {
        var policies: [WKNavigationActionPolicy] = []
        let decisionHandler = BrowserNavigationActionDecisionHandler(
            { policies.append($0) },
            fallbackPolicy: WKNavigationActionPolicy.cancel,
            label: "test.double-call"
        )

        decisionHandler(.allow)
        decisionHandler(.download)

        #expect(policies.count == 1)
        #expect(policies.first == .allow)
    }

    @Test
    func navigationDecisionHandlerCancelsWhenConsumedPathDropsHandler() {
        var policies: [WKNavigationActionPolicy] = []
        var droppedHandler: ((WKNavigationActionPolicy) -> Void)? =
            BrowserNavigationActionDecisionHandler(
                { policies.append($0) },
                fallbackPolicy: .cancel,
                label: "test.dropped-consumed-path"
            ).closure

        withExtendedLifetime(droppedHandler) {}
        droppedHandler = nil

        #expect(policies.count == 1)
        #expect(policies.first == .cancel)
    }

    @Test
    func navigationResponseDecisionHandlerUsesCancelFallback() {
        var policies: [WKNavigationResponsePolicy] = []
        var droppedHandler: ((WKNavigationResponsePolicy) -> Void)? =
            BrowserNavigationResponseDecisionHandler(
                { policies.append($0) },
                fallbackPolicy: .cancel,
                label: "test.dropped-response-path"
            ).closure

        withExtendedLifetime(droppedHandler) {}
        droppedHandler = nil

        #expect(policies.count == 1)
        #expect(policies.first == .cancel)
    }
}
