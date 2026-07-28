import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserUserAgentPolicyTests {
    private let policy = BrowserUserAgentPolicy(safariVersion: "26.4")

    @Test func remoteSitesReceiveCurrentSafariCompatibleIdentity() {
        let workspaceURL = URL(string: "https://workspace.google.com/")!
        let enterpriseSSOURL = URL(string: "https://sso.example.com/duo/")!

        #expect(policy.customUserAgent(for: workspaceURL) == policy.safariCompatibleUserAgent)
        #expect(policy.customUserAgent(for: enterpriseSSOURL) == policy.safariCompatibleUserAgent)
        #expect(policy.safariCompatibleUserAgent.contains("Version/26.4 Safari/605.1.15"))
    }

    @Test func googleSheetsKeepsEmbeddedWebKitIdentity() {
        let sheetURL = URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        let sheetsRedirectURL = URL(string: "https://sheets.google.com/")!

        #expect(policy.customUserAgent(for: sheetURL) == nil)
        #expect(policy.customUserAgent(for: sheetsRedirectURL) == nil)
    }

    @Test func otherGoogleWorkspaceEditorsRemainSafariCompatible() {
        let documentURL = URL(string: "https://docs.google.com/document/d/example/edit")!
        let presentationURL = URL(string: "https://docs.google.com/presentation/d/example/edit")!

        #expect(policy.customUserAgent(for: documentURL) == policy.safariCompatibleUserAgent)
        #expect(policy.customUserAgent(for: presentationURL) == policy.safariCompatibleUserAgent)
    }

    @Test func localDocumentsKeepEmbeddedWebKitIdentity() {
        #expect(policy.customUserAgent(for: URL(string: "about:blank")!) == nil)
        #expect(policy.customUserAgent(for: URL(fileURLWithPath: "/tmp/example.html")) == nil)
    }

    @MainActor
    @Test func applyingPolicySwitchesIdentityAcrossDestinations() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        policy.apply(to: webView, for: URL(string: "https://workspace.google.com/")!)
        #expect(webView.customUserAgent == policy.safariCompatibleUserAgent)

        policy.apply(to: webView, for: URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!)
        #expect(webView.customUserAgent == nil)
    }
}
