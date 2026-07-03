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
                $0.source == BrowserWebAuthnBridgeContract.scriptSource
            }
        )
        let webAuthnRelayScript = try #require(
            configuration.userContentController.userScripts.first {
                $0.source == BrowserWebAuthnBridgeContract.relayScriptSource
            }
        )
        #expect(webAuthnScript.injectionTime == .atDocumentStart)
        #expect(webAuthnScript.isForMainFrameOnly)
        #expect(webAuthnRelayScript.injectionTime == .atDocumentStart)
        #expect(webAuthnRelayScript.isForMainFrameOnly)
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
            contentWorld: BrowserWebAuthnBridgeContract.contentWorld,
            name: BrowserWebAuthnBridgeContract.handlerName
        )
        defer {
            configuration.userContentController.removeScriptMessageHandler(
                forName: BrowserWebAuthnBridgeContract.handlerName,
                contentWorld: BrowserWebAuthnBridgeContract.contentWorld
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
    func webContentProcessTerminationDefersReplacementUntilExplicitRecovery() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        let oldInstanceID = panel.webViewInstanceID

        simulateWebContentProcessTermination(for: panel)

        #expect(panel.webView === oldWebView)
        #expect(panel.webViewInstanceID == oldInstanceID)
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldAttachWebViewInUI)
        #expect(oldWebView.navigationDelegate == nil)
        #expect(oldWebView.uiDelegate == nil)

        #expect(panel.recoverTerminatedWebContent(reason: "test"))

        #expect(!(panel.webView === oldWebView))
        #expect(panel.webViewInstanceID != oldInstanceID)
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.shouldAttachWebViewInUI)
        #expect(panel.webView.navigationDelegate != nil)
        #expect(panel.webView.uiDelegate != nil)
    }

    @Test
    func systemMemoryPressureDiscardsRecoverableTerminatedHiddenWebView() {
        let committedURL = URL(string: "https://example.com/committed")!
        let provisionalURL = URL(string: "https://example.com/provisional")!
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: committedURL
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        let oldInstanceID = panel.webViewInstanceID
        let now = Date(timeIntervalSince1970: 3_000)
        panel.applyMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: true)
        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio)
        panel.navigate(to: provisionalURL)
        panel.webView.navigationDelegate?.webView?(panel.webView, didStartProvisionalNavigation: nil)

        simulateWebContentProcessTermination(for: panel)
        panel.noteWebViewVisibility(false, reason: "test.hidden", now: now)

        #expect(panel.webView === oldWebView)
        #expect(panel.webViewInstanceID == oldInstanceID)
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldAttachWebViewInUI)
        #expect(!panel.isPlayingMedia)
        #expect(!panel.isPlayingAudio)

        #expect(panel.discardHiddenWebViewForSystemMemoryPressure(now: now.addingTimeInterval(1)))

        #expect(!(panel.webView === oldWebView))
        #expect(panel.webViewInstanceID != oldInstanceID)
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
        #expect(!panel.shouldAttachWebViewInUI)
        #expect(panel.currentURL == provisionalURL)

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.visible"))
        #expect(panel.shouldAttachWebViewInUI)
        #expect(panel.currentURL == provisionalURL)
    }

    @Test
    func webContentProcessTerminationDisablesHistoryTraversalUntilRecovery() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: ["https://example.com/a"],
            forwardHistoryURLStrings: ["https://example.com/d"],
            currentURLString: "https://example.com/c"
        )
        #expect(panel.canGoBack)
        #expect(panel.canGoForward)

        simulateWebContentProcessTermination(for: panel)

        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.canGoBack)
        #expect(!panel.canGoForward)

        panel.goBack()
        panel.goForward()

        #expect(panel.webView === oldWebView)
        #expect(panel.hasRecoverableWebContentTermination)
    }

    @Test
    func visibleRecoverableTerminatedWebViewDoesNotMemoryDiscard() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }
        panel.noteWebViewVisibility(true, reason: "test.visible")

        simulateWebContentProcessTermination(for: panel)

        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldAttachWebViewInUI)
        #expect(!panel.discardHiddenWebViewForSystemMemoryPressure(now: Date(timeIntervalSince1970: 4_000)))
        #expect(panel.hasRecoverableWebContentTermination)
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

        simulateWebContentProcessTermination(for: panel)
        #expect(panel.webView.configuration.websiteDataStore === originalStore)

        #expect(panel.recoverTerminatedWebContent(reason: "test"))

        #expect(panel.webView.configuration.websiteDataStore === originalStore)
    }

    @Test
    func reloadRecoversTerminatedWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        simulateWebContentProcessTermination(for: panel)
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

        simulateWebContentProcessTermination(for: panel)
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

        simulateWebContentProcessTermination(for: panel)
        #expect(panel.hasRecoverableWebContentTermination)

        #expect(panel.switchToProfile(profile.id))

        #expect(!panel.hasRecoverableWebContentTermination)
    }

    @Test
    func webViewReplacementPreservesEmptyNewTabRenderState() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        #expect(!panel.shouldRenderWebView)

        simulateWebContentProcessTermination(for: panel)

        #expect(!panel.shouldRenderWebView)
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldAttachWebViewInUI)
    }

    @Test
    func nonRecoverableWebContentTerminationKeepsNavigationCallbacksActive() {
        let failedURL = URL(string: "https://example.invalid/nonrecoverable")!
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        simulateWebContentProcessTermination(for: panel)
        #expect(!panel.hasRecoverableWebContentTermination)

        panel.navigate(to: failedURL)
        panel.webView.navigationDelegate?.webView?(
            panel.webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotFindHost,
                userInfo: [NSURLErrorFailingURLStringErrorKey: failedURL.absoluteString]
            )
        )

        #expect(panel.currentURL == failedURL)
        #expect(panel.pageTitle == failedURL.absoluteString)
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

@MainActor private func simulateWebContentProcessTermination(for panel: BrowserPanel) { panel.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(panel.webView) }

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
