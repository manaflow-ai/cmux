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
    @Test func duoNavigationUsesUserAgentOverrideFromCmuxConfig() throws {
        let defaults = UserDefaults.standard
        let userAgentDefaultsKey = "browserUserAgent"
        let backupsDefaultsKey = "cmux.settingsFile.backups.v1"
        let importedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
        let previousUserAgent = defaults.object(forKey: userAgentDefaultsKey)
        let previousBackups = defaults.object(forKey: backupsDefaultsKey)
        let previousImportedDefaults = defaults.object(forKey: importedDefaultsKey)
        defer {
            if let previousUserAgent {
                defaults.set(previousUserAgent, forKey: userAgentDefaultsKey)
            } else {
                defaults.removeObject(forKey: userAgentDefaultsKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: backupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: backupsDefaultsKey)
            }
            if let previousImportedDefaults {
                defaults.set(previousImportedDefaults, forKey: importedDefaultsKey)
            } else {
                defaults.removeObject(forKey: importedDefaultsKey)
            }
        }
        defaults.removeObject(forKey: userAgentDefaultsKey)
        defaults.removeObject(forKey: backupsDefaultsKey)
        defaults.removeObject(forKey: importedDefaultsKey)

        let configuredUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/126.0.0.0 Safari/537.36"
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsURL = directoryURL.appendingPathComponent("cmux.json")
        try """
        {
          "browser": {
            "userAgent": "\(configuredUserAgent)"
          }
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        _ = CmuxSettingsFileStore(
            primaryPath: settingsURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let duoRequest = URLRequest(
            url: URL(string: "https://api-example.duosecurity.com/frame/v4/auth")!
        )

        #expect(defaults.string(forKey: userAgentDefaultsKey) == configuredUserAgent)
        _ = webView.browserUserAgentPolicyRestartRequest(for: duoRequest)
        #expect(webView.customUserAgent == configuredUserAgent)
    }

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

    @Test func sheetsDestinationNeverAllowsStaleSafariIdentity() throws {
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

        // If another load phase exposes the stale Safari identity again, the
        // replacement must correct it instead of silently allowing a downgrade.
        webView.customUserAgent = BrowserUserAgentPolicy.system.safariCompatibleUserAgent
        #expect(webView.restartNavigationForBrowserUserAgentPolicyIfNeeded(
            for: replacementRequest,
            targetFrameIsMainFrame: true,
            decisionHandler: { decisions.append($0) },
            startReplacement: { replacementRequests.append($0) }
        ))
        #expect(decisions == [.cancel, .cancel])
        #expect(replacementRequests.count == 2)
        #expect((webView.customUserAgent ?? "").isEmpty)
    }
}
