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
@Suite(.serialized)
struct BrowserWebContentProcessTests {
    private let recoveryURL = URL(string: "data:text/html,cmux-recovery")!

    @Test
    func browserPanelsShareDefaultWebsiteDataStore() {
        let first = BrowserPanel(workspaceId: UUID())
        let second = BrowserPanel(workspaceId: UUID())
        defer {
            first.close()
            second.close()
        }

        #expect(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
    }

    @Test
    func configureWebViewConfigurationAppliesWebsiteDataStore() {
        let configuration = WKWebViewConfiguration()
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: websiteDataStore
        )

        #expect(configuration.websiteDataStore === websiteDataStore)
    }

    @Test
    func configuredBrowserPageInstallsWebAuthnBridge() async throws {
        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .nonPersistent()
        )
        let webAuthnScript = try #require(
            configuration.userContentController.userScripts.first {
                $0.source == BrowserWebAuthnBridgeContract.standard.scriptSource
            }
        )
        #expect(webAuthnScript.injectionTime == .atDocumentStart)
        #expect(webAuthnScript.isForMainFrameOnly)
        #expect(configuration.userContentController.userScripts.filter {
            $0.source == BrowserWebAuthnBridgeContract.standard.scriptSource
        }.count == 1)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: configuration
        )
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey bridge probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        let installed = try await webView.evaluateJavaScript(
            "window.__cmuxWebAuthnBridgeInstalled === true"
        ) as? Bool
        #expect(installed == true)
    }

    @Test
    func browserPanelInstallsWebAuthnBridgeWithoutExposingNativeHandler() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let webView = panel.webView
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey native handler probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        let result = try await webView.evaluateJavaScript(
            """
            ({
              bridge: window.__cmuxWebAuthnBridgeInstalled === true,
              handler: !!(
                window.webkit &&
                window.webkit.messageHandlers &&
                window.webkit.messageHandlers.cmuxWebAuthn &&
                typeof window.webkit.messageHandlers.cmuxWebAuthn.postMessage === "function"
              )
            })
            """
        ) as? [String: Bool]
        #expect(result?["bridge"] == true)
        #expect(result?["handler"] == false)
    }

    @Test
    func webAuthnPageBridgeRelaysCredentialGetThroughContentWorldHandler() async throws {
        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .nonPersistent()
        )
        let probe = BrowserWebAuthnReplyProbe()
        configuration.userContentController.addScriptMessageHandler(
            probe,
            contentWorld: .page,
            name: BrowserWebAuthnBridgeContract.standard.handlerName
        )
        defer {
            configuration.userContentController.removeScriptMessageHandler(
                forName: BrowserWebAuthnBridgeContract.standard.handlerName,
                contentWorld: .page
            )
        }
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: configuration
        )
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey relay probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        let result = try await webView.evaluateJavaScript(
            """
            (async () => {
              const handlerVisible = !!(
                window.webkit &&
                window.webkit.messageHandlers &&
                window.webkit.messageHandlers.cmuxWebAuthn &&
                typeof window.webkit.messageHandlers.cmuxWebAuthn.postMessage === "function"
              );
              const credential = await navigator.credentials.get({
                publicKey: {
                  challenge: new Uint8Array([1, 2, 3, 4]).buffer,
                  rpId: "example.com",
                  userVerification: "preferred"
                }
              });
              return {
                handlerVisible,
                credentialId: credential && credential.id,
                rawIDLength: credential && credential.rawId && credential.rawId.byteLength,
                signatureLength:
                  credential &&
                  credential.response &&
                  credential.response.signature &&
                  credential.response.signature.byteLength
              };
            })()
            """
        ) as? [String: Any]

        #expect(result?["handlerVisible"] as? Bool == false)
        #expect(result?["credentialId"] as? String == "AQID")
        #expect((result?["rawIDLength"] as? NSNumber)?.intValue == 3)
        #expect((result?["signatureLength"] as? NSNumber)?.intValue == 2)
        #expect(probe.receivedKinds == ["getCredential"])
    }

    @Test
    func webAuthnNativeBridgeScopesParentDomainRelyingPartyIDs() throws {
        let googleOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://accounts.google.com")!)
        )
        #expect(googleOrigin.isWithinRelyingPartyScope("google.com"))
        #expect(googleOrigin.permits(relyingPartyIdentifier: "google.com"))

        let exampleOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://login.example.com")!)
        )
        #expect(exampleOrigin.isWithinRelyingPartyScope("example.com"))
        #expect(!exampleOrigin.permits(relyingPartyIdentifier: "example.com"))
        #expect(!exampleOrigin.permits(relyingPartyIdentifier: "com"))

        let githubPagesOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://tenant.github.io")!)
        )
        #expect(githubPagesOrigin.isWithinRelyingPartyScope("github.io"))
        #expect(githubPagesOrigin.permits(relyingPartyIdentifier: "tenant.github.io"))
        #expect(!githubPagesOrigin.permits(relyingPartyIdentifier: "github.io"))

        let appspotOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://foo.appspot.com")!)
        )
        #expect(appspotOrigin.isWithinRelyingPartyScope("appspot.com"))
        #expect(appspotOrigin.permits(relyingPartyIdentifier: "foo.appspot.com"))
        #expect(!appspotOrigin.permits(relyingPartyIdentifier: "appspot.com"))
    }

    @Test
    func webAuthnSecurityOriginSerializesIPv6LoopbackOrigins() throws {
        let origin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "http://[::1]:3000")!)
        )

        #expect(origin.serializedString == "http://[::1]:3000")
        #expect(origin.isPotentiallyTrustworthyWebAuthnOrigin)
    }

    @Test
    func webViewReplacementAfterProcessTerminationUpdatesInstanceIdentity() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        let oldInstanceID = panel.webViewInstanceID

        panel.debugSimulateWebContentProcessTermination()

        #expect(!(panel.webView === oldWebView))
        #expect(panel.webViewInstanceID != oldInstanceID)
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(panel.webView.navigationDelegate != nil)
        #expect(panel.webView.uiDelegate != nil)
    }

    @Test
    func remoteWorkspaceWebsiteDataStoreSurvivesWebViewReplacement() {
        let storeIdentifier = UUID()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: storeIdentifier
        )
        defer { panel.close() }
        let originalStore = panel.webView.configuration.websiteDataStore

        panel.debugSimulateWebContentProcessTermination()

        #expect(panel.webView.configuration.websiteDataStore === originalStore)
    }

    @Test
    func reloadRecoversTerminatedWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)

        panel.reload()

        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.shouldRenderWebView)
    }

    @Test
    func workspaceContextResetClearsTerminatedWebViewRecovery() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)

        panel.resetForWorkspaceContextChange(reason: "test")

        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
        #expect(panel.preferredURLStringForOmnibar() == nil)
    }

    @Test
    func profileSwitchClearsTerminatedWebViewRecovery() throws {
        let profile = try #require(
            BrowserProfileStore.shared.createProfile(
                named: "WebContent Recovery \(UUID().uuidString)"
            )
        )
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            initialURL: recoveryURL
        )
        defer { panel.close() }

        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)

        #expect(panel.switchToProfile(profile.id))

        #expect(!panel.hasRecoverableWebContentTermination)
    }

    @Test
    func webViewReplacementPreservesEmptyNewTabRenderState() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        #expect(!panel.shouldRenderWebView)

        panel.debugSimulateWebContentProcessTermination()

        #expect(!panel.shouldRenderWebView)
        #expect(!panel.hasRecoverableWebContentTermination)
    }

    @Test
    func floatingPopupInheritsOpenerWebsiteDataStore() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        #expect(popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore)
    }

    @Test
    func floatingPopupInheritsRemoteWorkspaceWebsiteDataStore() throws {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        #expect(popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore)
        #expect(!(popupWebView.configuration.websiteDataStore === WKWebsiteDataStore.default()))
    }

    @Test
    func floatingPopupClosesWhenWebContentProcessTerminates() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        let popupWindow = try #require(popupWebView.window)

        popupWebView.navigationDelegate?.webViewWebContentProcessDidTerminate?(popupWebView)

        #expect(popupWebView.navigationDelegate == nil)
        #expect(popupWebView.uiDelegate == nil)
        #expect(popupWebView.window == nil)
        #expect(!popupWindow.isVisible)
    }
}

private final class BrowserWebContentProcessLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = continuation
        self.continuation = nil
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private final class BrowserWebAuthnReplyProbe: NSObject, WKScriptMessageHandlerWithReply {
    private(set) var receivedKinds: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else {
            replyHandler(
                [
                    "ok": false,
                    "error": [
                        "name": "TypeError",
                        "message": "Malformed browser passkey request.",
                    ],
                ],
                nil
            )
            return
        }

        receivedKinds.append(kind)
        switch kind {
        case "getCredential":
            replyHandler(
                [
                    "ok": true,
                    "credential": [
                        "type": "public-key",
                        "id": "AQID",
                        "rawId": "AQID",
                        "authenticatorAttachment": "platform",
                        "responseKind": "assertion",
                        "response": [
                            "clientDataJSON": "BAU",
                            "authenticatorData": "Bgc",
                            "signature": "CAk",
                            "userHandle": "Cg",
                        ],
                        "clientExtensionResults": [:],
                    ],
                ],
                nil
            )
        default:
            replyHandler(
                [
                    "ok": false,
                    "error": [
                        "name": "NotSupportedError",
                        "message": "Native passkey support is unavailable.",
                    ],
                ],
                nil
            )
        }
    }
}
