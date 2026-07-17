import AppKit
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import Foundation
import Testing
import UserNotifications
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class BrowserWebNotificationContractProbe: NSObject, WKScriptMessageHandlerWithReply {
    private(set) var bodies: [[String: String]] = []
    var statusReply = "default"

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: String] else {
            replyHandler(nil, "invalid_message")
            return
        }
        if body["type"] == "status" {
            replyHandler(statusReply, nil)
            return
        }
        if body["type"] == "permission" {
            replyHandler("granted", nil)
            return
        }
        bodies.append(body)
        replyHandler("ok", nil)
    }
}

private final class BrowserPersistentNotificationProbe: NSObject {
    @objc dynamic let title: String
    @objc dynamic let body: String
    @objc dynamic let origin: String
    @objc dynamic let dictionaryRepresentation: NSDictionary = ["notification": "probe"]

    init(title: String, body: String, origin: URL) {
        self.title = title
        self.body = body
        self.origin = origin.absoluteString
    }
}

@MainActor
private final class BrowserWebNotificationLoadProbe: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
@Suite("Browser web notifications", .serialized)
struct BrowserWebNotificationTests {
    private let token = "test-web-notification-token"

    @Test func validatesAndBoundsPayloads() throws {
        let payload = try #require(BrowserWebNotificationPayload.validated(
            body: ["token": token, "title": "Build complete", "body": "Ready"],
            expectedToken: token,
            originScheme: "HTTPS",
            originHost: "Example.COM",
            isMainFrame: true,
            isCurrentWebView: true,
            isCurrentGeneration: true
        ))
        #expect(payload == BrowserWebNotificationPayload(
            title: "Build complete",
            body: "Ready",
            hostname: "example.com"
        ))

        let oversized = try #require(BrowserWebNotificationPayload.validated(
            body: [
                "token": token,
                "title": String(repeating: "t", count: 300),
                "body": String(repeating: "b", count: 5_000),
            ],
            expectedToken: token,
            originScheme: "https",
            originHost: "example.com",
            isMainFrame: true,
            isCurrentWebView: true,
            isCurrentGeneration: true
        ))
        #expect(oversized.title.count == BrowserWebNotificationPayload.maximumTitleLength)
        #expect(oversized.body.count == BrowserWebNotificationPayload.maximumBodyLength)
    }

    @Test func rejectsMalformedUnauthorizedAndStalePayloads() {
        func validated(
            _ body: Any,
            scheme: String = "https",
            host: String = "example.com",
            mainFrame: Bool = true,
            currentWebView: Bool = true,
            currentGeneration: Bool = true
        ) -> BrowserWebNotificationPayload? {
            BrowserWebNotificationPayload.validated(
                body: body,
                expectedToken: token,
                originScheme: scheme,
                originHost: host,
                isMainFrame: mainFrame,
                isCurrentWebView: currentWebView,
                isCurrentGeneration: currentGeneration
            )
        }

        let validBody: [String: Any] = ["token": token, "title": "Title", "body": "Body"]
        #expect(validated(["title": "Title", "body": "Body"]) == nil)
        #expect(validated(["token": "wrong", "title": "Title", "body": "Body"]) == nil)
        #expect(validated(["token": token, "title": 42, "body": "Body"]) == nil)
        #expect(validated(["token": token, "title": "Title", "body": false]) == nil)
        #expect(validated(validBody, scheme: "file") == nil)
        #expect(validated(validBody, scheme: "about") == nil)
        #expect(validated(validBody, host: "") == nil)
        #expect(validated(validBody, mainFrame: false) == nil)
        #expect(validated(validBody, currentWebView: false) == nil)
        #expect(validated(validBody, currentGeneration: false) == nil)
    }

    @Test func wrapperPreservesNativeContractAndPermissionGating() async throws {
        let controller = WKUserContentController()
        let probe = BrowserWebNotificationContractProbe()
        controller.addScriptMessageHandler(
            probe,
            contentWorld: .page,
            name: BrowserWebNotificationMessageHandler.name
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              let permission = "denied";
              class NativeNotification {
                static get permission() { return permission; }
                static requestPermission() { return Promise.resolve(permission); }
                constructor(title, options = {}) {
                  if (title === "throw") throw new TypeError("native boom");
                  const result = Object.create(NativeNotification.prototype);
                  result.title = String(title);
                  result.body = options.body === undefined ? "" : String(options.body);
                  result.onclick = null;
                  window.__nativeNotificationResult = result;
                  return result;
                }
              }
              window.__NativeNotification = NativeNotification;
              window.__setNotificationPermission = value => { permission = value; };
              Object.defineProperty(window, "Notification", {
                value: NativeNotification,
                configurable: true,
                writable: true
              });
              return true;
            })();
            """
        )
        _ = try await webView.evaluateJavaScript(BrowserPanel.webNotificationBridgeScriptSource(token: token))

        let denied = try #require(try await webView.evaluateJavaScript(
            """
            (() => {
              const notification = new Notification("Denied", { body: "No forward" });
              notification.onclick = () => 7;
              return {
                permission: Notification.permission,
                requestPermissionIsFunction: typeof Notification.requestPermission === "function",
                samePrototype: Notification.prototype === __NativeNotification.prototype,
                nativeReturn: notification === __nativeNotificationResult,
                instanceOfWrapped: notification instanceof Notification,
                onclickPreserved: notification.onclick() === 7
              };
            })();
            """
        ) as? [String: Any])
        #expect(denied["permission"] as? String == "default")
        #expect(denied["requestPermissionIsFunction"] as? Bool == true)
        #expect(denied["samePrototype"] as? Bool == true)
        #expect(denied["nativeReturn"] as? Bool == true)
        #expect(denied["instanceOfWrapped"] as? Bool == true)
        #expect(denied["onclickPreserved"] as? Bool == true)
        #expect(probe.bodies.isEmpty)

        let identity = try #require(try await webView.evaluateJavaScript(
            """
            ({
              name: Notification.name,
              length: Notification.length,
              constructorMatches: (new Notification("Identity")).constructor === Notification
            })
            """
        ) as? [String: Any])
        #expect(identity["name"] as? String == "NativeNotification")
        #expect(identity["length"] as? Int == 1)
        #expect(identity["constructorMatches"] as? Bool == true)

        let permissionState = try await webView.callAsyncJavaScript(
            "return (await navigator.permissions.query({ name: 'notifications' })).state",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        #expect(permissionState == "prompt")

        let grantedPermission = try await webView.callAsyncJavaScript(
            "return await Notification.requestPermission()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        #expect(grantedPermission == "granted")
        _ = try await webView.evaluateJavaScript(
            "new Notification('Granted', { body: 'Forward me' });"
        )
        #expect(probe.bodies == [[
            "type": "notification",
            "token": token,
            "title": "Granted",
            "body": "Forward me",
        ]])

        let nativeError = try #require(try await webView.evaluateJavaScript(
            """
            (() => {
              try {
                new Notification("throw");
                return null;
              } catch (error) {
                return { name: error.name, message: error.message };
              }
            })();
            """
        ) as? [String: String])
        #expect(nativeError == ["name": "TypeError", "message": "native boom"])
    }

    @Test func fallbackMapsRemoteAliasAndReadsLivePermissionState() async throws {
        let controller = WKUserContentController()
        let probe = BrowserWebNotificationContractProbe()
        probe.statusReply = "granted"
        controller.addScriptMessageHandler(
            probe,
            contentWorld: .page,
            name: BrowserWebNotificationMessageHandler.name
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loadProbe = BrowserWebNotificationLoadProbe()
        webView.navigationDelegate = loadProbe
        defer { webView.navigationDelegate = nil }
        try await loadProbe.load(
            "<!doctype html><html><body>alias permission probe</body></html>",
            in: webView,
            baseURL: try #require(URL(string: "http://cmux-loopback.localtest.me:3000"))
        )
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              class NativeNotification {
                static get permission() { return "default"; }
                static requestPermission() { return Promise.resolve("default"); }
                constructor(title, options = {}) { this.title = String(title); this.body = String(options.body ?? ""); }
              }
              Object.defineProperty(window, "Notification", { value: NativeNotification, configurable: true, writable: true });
            })();
            """
        )
        _ = try await webView.evaluateJavaScript(BrowserPanel.webNotificationBridgeScriptSource(
            token: token,
            allowedOrigins: ["http://cmux-loopback.localtest.me:3000"]
        ))
        #expect(try await webView.evaluateJavaScript("Notification.permission") as? String == "granted")

        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: setting.userDefaultsKey)
        let profileID = BrowserProfileRepository.builtInDefaultProfileID
        let securityOrigin = try #require(URL(string: "http://cmux-loopback.localtest.me:3000"))
        let legacyDisplayOrigin = try #require(URL(string: "http://localhost:3000"))
        let repository = BrowserProfileStore.shared.notificationPermissions
        let previousSecurityDecision = repository.decision(for: securityOrigin, profileID: profileID)
        let previousLegacyDecision = repository.decision(for: legacyDisplayOrigin, profileID: profileID)
        BrowserWebNotificationNativeAdapter.shared.forceForegroundFallbackForTesting = true
        defer {
            BrowserWebNotificationNativeAdapter.shared.forceForegroundFallbackForTesting = false
            repository.setDecision(previousSecurityDecision, for: securityOrigin, profileID: profileID)
            repository.setDecision(previousLegacyDecision, for: legacyDisplayOrigin, profileID: profileID)
            if let previousSetting { defaults.set(previousSetting, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }
        setting.set(true, in: defaults)
        repository.setDecision(.prompt, for: securityOrigin, profileID: profileID)
        repository.setDecision(.allowed, for: legacyDisplayOrigin, profileID: profileID)
        let panel = BrowserPanel(workspaceId: UUID(), profileID: profileID, renderInitialNavigation: false)
        defer { panel.close() }
        panel.replaceWebViewPreservingState(
            from: panel.webView,
            websiteDataStore: panel.webView.configuration.websiteDataStore,
            reason: "test_live_web_notification_permission"
        )
        let panelWebView = panel.webView
        let panelLoadProbe = BrowserWebNotificationLoadProbe()
        panelWebView.navigationDelegate = panelLoadProbe
        defer { panelWebView.navigationDelegate = nil }
        try await panelLoadProbe.load(
            "<!doctype html><html><body>live permission probe</body></html>",
            in: panelWebView,
            baseURL: try #require(URL(string: "http://cmux-loopback.localtest.me:3000"))
        )
        let bridgeToken = try #require(panel.webNotificationBridgeToken?.javaScriptStringLiteral)
        let liveStatus = try await panelWebView.callAsyncJavaScript(
            """
            return await window.webkit.messageHandlers.\(BrowserWebNotificationMessageHandler.name).postMessage({
              type: "status", token: \(bridgeToken)
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        #expect(liveStatus == "granted")
        #expect(repository.decision(for: securityOrigin, profileID: profileID) == .allowed)
        #expect(repository.decision(for: legacyDisplayOrigin, profileID: profileID) == .prompt)
    }

    @Test func permissionRequestsRespectLiveSettingAndCoalesceByOrigin() throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: setting.userDefaultsKey)
        let profileID = BrowserProfileRepository.builtInDefaultProfileID
        let origin = try #require(URL(string: "https://example.com"))
        let repository = BrowserProfileStore.shared.notificationPermissions
        let previousDecision = repository.decision(for: origin, profileID: profileID)
        defer {
            repository.setDecision(previousDecision, for: origin, profileID: profileID)
            if let previousSetting { defaults.set(previousSetting, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }
        let panel = BrowserPanel(workspaceId: UUID(), profileID: profileID, renderInitialNavigation: false)
        defer { panel.close() }

        setting.set(false, in: defaults)
        repository.setDecision(.allowed, for: origin, profileID: profileID)
        var disabledReply: Bool?
        panel.resolveWebNotificationPermission(for: origin, in: panel.webView) { disabledReply = $0 }
        #expect(disabledReply == false)

        setting.set(true, in: defaults)
        repository.setDecision(.prompt, for: origin, profileID: profileID)
        var presentations = 0
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        panel.webNotificationPermissionAlertPresenter = { _, _, completion, _ in
            presentations += 1
            completions.append(completion)
        }
        var replies: [Bool] = []
        panel.resolveWebNotificationPermission(for: origin, in: panel.webView) { replies.append($0) }
        panel.resolveWebNotificationPermission(for: origin, in: panel.webView) { replies.append($0) }
        #expect(presentations == 1)
        #expect(replies.isEmpty)
        for completion in completions { completion(.alertFirstButtonReturn) }
        #expect(replies == [true, true])
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeProviderGrantsAndDeliversOnSupportedMacOS() async throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion > 14 else { return }
        #expect(BrowserWebNotificationNativeAdapter.shared.shouldInstallForegroundFallback == false)

        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: setting.userDefaultsKey)
        let profileID = BrowserProfileRepository.builtInDefaultProfileID
        let origin = try #require(URL(string: "https://example.com"))
        let repository = BrowserProfileStore.shared.notificationPermissions
        let previousDecision = repository.decision(for: origin, profileID: profileID)
        defer {
            repository.setDecision(previousDecision, for: origin, profileID: profileID)
            if let previousSetting { defaults.set(previousSetting, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }

        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: profileID,
            renderInitialNavigation: false
        )
        defer { panel.close() }
        setting.set(true, in: defaults)
        repository.setDecision(.allowed, for: origin, profileID: profileID)
        panel.replaceWebViewPreservingState(
            from: panel.webView,
            websiteDataStore: panel.webView.configuration.websiteDataStore,
            reason: "test_native_web_notification_provider_setup"
        )

        let (deliveries, deliveryContinuation) = AsyncStream<(
            title: String,
            subtitle: String,
            body: String
        )>.makeStream()
        defer { deliveryContinuation.finish() }
        panel.deliverWebNotification = { _, _, title, subtitle, body in
            deliveryContinuation.yield((title, subtitle, body))
        }
        let webView = panel.webView
        let loadProbe = BrowserWebNotificationLoadProbe()
        webView.navigationDelegate = loadProbe
        defer { webView.navigationDelegate = nil }
        try await loadProbe.load(
            "<!doctype html><html><body>native notification probe</body></html>",
            in: webView,
            baseURL: origin
        )

        let permission = try await webView.callAsyncJavaScript(
            "return await Notification.requestPermission()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        #expect(permission == "granted")
        _ = try await webView.evaluateJavaScript(
            "new Notification('Native probe', { body: 'Ready' }); true"
        )
        var deliveryIterator = deliveries.makeAsyncIterator()
        let delivered = await deliveryIterator.next()
        #expect(delivered?.title == "Native probe")
        #expect(delivered?.subtitle == "example.com")
        #expect(delivered?.body == "Ready")
    }

    @Test func settingAppliesLiveAndRoutesToTheOriginatingSurface() throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: setting.userDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: setting.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: setting.userDefaultsKey)
            }
        }

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
        }

        defaults.removeObject(forKey: setting.userDefaultsKey)
        #expect(setting.value(in: defaults) == false)

        let workspaceID = UUID()
        let panel = BrowserPanel(workspaceId: workspaceID, renderInitialNavigation: false)
        defer { panel.close() }
        let payload = BrowserWebNotificationPayload(title: "Deploy", body: "Finished", hostname: "example.com")
        panel.handleWebNotificationPayload(payload, fromWebViewInstanceID: panel.webViewInstanceID)
        #expect(store.notifications.isEmpty)

        setting.set(true, in: defaults)
        panel.handleWebNotificationPayload(payload, fromWebViewInstanceID: panel.webViewInstanceID)

        let notification = try #require(store.notifications.first)
        #expect(notification.tabId == workspaceID)
        #expect(notification.surfaceId == panel.id)
        #expect(notification.title == "Deploy")
        #expect(notification.subtitle == "example.com")
        #expect(notification.body == "Finished")

        setting.set(false, in: defaults)
        panel.handleWebNotificationPayload(
            BrowserWebNotificationPayload(title: "Suppressed", body: "Hidden", hostname: "example.com"),
            fromWebViewInstanceID: panel.webViewInstanceID
        )
        #expect(store.notifications.count == 1)

        setting.set(true, in: defaults)
        panel.handleWebNotificationPayload(payload, fromWebViewInstanceID: UUID())
        #expect(store.notifications.count == 1)
    }

    @Test func replacementRotatesTokenAndRemovesOldHandler() async throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: setting.userDefaultsKey)
        BrowserWebNotificationNativeAdapter.shared.forceForegroundFallbackForTesting = true
        defer {
            BrowserWebNotificationNativeAdapter.shared.forceForegroundFallbackForTesting = false
            if let previous { defaults.set(previous, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }
        // BrowserPanel performs one-time settings-file bootstrap during init,
        // so opt in afterward before creating the generation under test.
        setting.set(true, in: defaults)
        panel.replaceWebViewPreservingState(
            from: panel.webView,
            websiteDataStore: panel.webView.configuration.websiteDataStore,
            reason: "test_web_notification_bridge_setup"
        )
        let oldWebView = panel.webView
        let oldInstanceID = panel.webViewInstanceID
        let oldToken = try #require(panel.webNotificationBridgeToken)
        let oldHandler = try #require(panel.webNotificationMessageHandler)

        panel.replaceWebViewPreservingState(
            from: oldWebView,
            websiteDataStore: oldWebView.configuration.websiteDataStore,
            reason: "test_web_notification_bridge"
        )

        let newToken = try #require(panel.webNotificationBridgeToken)
        let newHandler = try #require(panel.webNotificationMessageHandler)
        #expect(panel.webView !== oldWebView)
        #expect(panel.webViewInstanceID != oldInstanceID)
        #expect(newToken != oldToken)
        #expect(newHandler !== oldHandler)
        #expect(newHandler.webViewInstanceID == panel.webViewInstanceID)

        let oldHandlerStillCallable: Bool
        do {
            oldHandlerStillCallable = try await oldWebView.evaluateJavaScript(
                """
                (() => {
                  try {
                    window.webkit.messageHandlers.\(BrowserWebNotificationMessageHandler.name).postMessage({
                      type: "notification", token: \(oldToken.javaScriptStringLiteral ?? "\"\""), title: "Late", body: "Old"
                    });
                    return true;
                  } catch (_) {
                    return false;
                  }
                })();
                """
            ) as? Bool == true
        } catch {
            oldHandlerStillCallable = false
        }
        #expect(oldHandlerStillCallable == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func popupUsesIndependentControllerAndBoundNotificationEndpoint() async throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: setting.userDefaultsKey)
        let profileID = BrowserProfileRepository.builtInDefaultProfileID
        let origin = try #require(URL(string: "https://example.com"))
        let repository = BrowserProfileStore.shared.notificationPermissions
        let previousDecision = repository.decision(for: origin, profileID: profileID)
        BrowserWebNotificationNativeAdapter.shared.forceForegroundFallbackForTesting = true
        defer {
            BrowserWebNotificationNativeAdapter.shared.forceForegroundFallbackForTesting = false
            repository.setDecision(previousDecision, for: origin, profileID: profileID)
            if let previousSetting { defaults.set(previousSetting, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }
        setting.set(true, in: defaults)
        repository.setDecision(.allowed, for: origin, profileID: profileID)
        let panel = BrowserPanel(workspaceId: UUID(), profileID: profileID, renderInitialNavigation: false)
        defer { panel.close() }

        let suppliedConfiguration = WKWebViewConfiguration()
        suppliedConfiguration.userContentController = panel.webView.configuration.userContentController
        let popupWebView = try #require(panel.createFloatingPopup(
            configuration: suppliedConfiguration,
            windowFeatures: WKWindowFeatures()
        ))
        defer { popupWebView.window?.close() }
        #expect(popupWebView.configuration.userContentController !== panel.webView.configuration.userContentController)
        #expect(popupWebView.uiDelegate?.responds(
            to: NSSelectorFromString("_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:")
        ) == true)

        let loadProbe = BrowserWebNotificationLoadProbe()
        popupWebView.navigationDelegate = loadProbe
        defer { popupWebView.navigationDelegate = nil }
        try await loadProbe.load(
            "<!doctype html><html><body>popup notification probe</body></html>",
            in: popupWebView,
            baseURL: origin
        )
        let permission = try await popupWebView.callAsyncJavaScript(
            "return await Notification.requestPermission()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        #expect(permission == "granted")
    }

    @Test func fallbackHandlerRejectsDirectPostsWithoutStoredPermission() async throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: setting.userDefaultsKey)
        let profileID = BrowserProfileRepository.builtInDefaultProfileID
        let origin = try #require(URL(string: "https://example.com"))
        let repository = BrowserProfileStore.shared.notificationPermissions
        let previousDecision = repository.decision(for: origin, profileID: profileID)
        BrowserWebNotificationNativeAdapter.shared.forceForegroundFallbackForTesting = true
        defer {
            BrowserWebNotificationNativeAdapter.shared.forceForegroundFallbackForTesting = false
            repository.setDecision(previousDecision, for: origin, profileID: profileID)
            if let previousSetting { defaults.set(previousSetting, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }

        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: profileID,
            renderInitialNavigation: false
        )
        defer { panel.close() }
        setting.set(true, in: defaults)
        repository.setDecision(.denied, for: origin, profileID: profileID)
        panel.replaceWebViewPreservingState(
            from: panel.webView,
            websiteDataStore: panel.webView.configuration.websiteDataStore,
            reason: "test_web_notification_permission_gate"
        )

        var deliveredTitle: String?
        panel.deliverWebNotification = { _, _, title, _, _ in deliveredTitle = title }
        let webView = panel.webView
        let loadProbe = BrowserWebNotificationLoadProbe()
        webView.navigationDelegate = loadProbe
        defer { webView.navigationDelegate = nil }
        try await loadProbe.load(
            "<!doctype html><html><body>fallback permission probe</body></html>",
            in: webView,
            baseURL: origin
        )
        let token = try #require(panel.webNotificationBridgeToken?.javaScriptStringLiteral)

        do {
            _ = try await webView.callAsyncJavaScript(
                """
                return await window.webkit.messageHandlers.\(BrowserWebNotificationMessageHandler.name).postMessage({
                      type: "notification",
                      token: \(token),
                      title: "Denied replay",
                      body: "Must not forward"
                    });
                """,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
        } catch {
            // A native permission rejection is the expected result.
        }
        #expect(deliveredTitle == nil)

        repository.setDecision(.allowed, for: origin, profileID: profileID)
        let reply = try await webView.callAsyncJavaScript(
            """
            return await window.webkit.messageHandlers.\(BrowserWebNotificationMessageHandler.name).postMessage({
                  type: "notification",
                  token: \(token),
                  title: "Allowed replay",
                  body: "Forward this"
                });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        #expect(reply == "ok")
        #expect(deliveredTitle == "Allowed replay")
    }

    @Test func backgroundWebsiteNotificationsUseTheGlobalSessionTarget() throws {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
        }

        let origin = try #require(URL(string: "https://example.com"))
        let id = store.addGlobalWebsiteNotification(
            title: "Background",
            subtitle: "example.com",
            body: "Ready",
            origin: origin
        )
        let notification = try #require(store.notifications.first(where: { $0.id == id }))
        #expect(notification.target == .global)
        #expect(notification.tabId == TerminalNotification.globalTargetSentinel)
        #expect(notification.paneFlash == false)
        #expect(notification.source == .website(origin: origin))
    }

    @Test func persistentDeliveryRespectsTheLiveForwardingSetting() throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: setting.userDefaultsKey)
        let store = TerminalNotificationStore.shared
        let adapter = BrowserWebNotificationNativeAdapter.shared
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let profileID = UUID()
        adapter.setProfileForTesting(profileID, on: dataStore)
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        defer {
            adapter.setProfileForTesting(nil, on: dataStore)
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            if let previousSetting { defaults.set(previousSetting, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }

        setting.set(false, in: defaults)
        let notification = BrowserPersistentNotificationProbe(
            title: "Background",
            body: "Must stay hidden",
            origin: try #require(URL(string: "https://example.com"))
        )
        adapter.showPersistentNotification(notification, from: dataStore)
        #expect(store.notifications.isEmpty)
    }

    @Test func nativePermissionSnapshotRespectsTheLiveForwardingSetting() throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: setting.userDefaultsKey)
        let adapter = BrowserWebNotificationNativeAdapter.shared
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let profileID = UUID()
        let origin = try #require(URL(string: "https://example.com"))
        let repository = BrowserProfileStore.shared.notificationPermissions
        let previousDecision = repository.decision(for: origin, profileID: profileID)
        defer {
            adapter.setProfileForTesting(nil, on: dataStore)
            repository.setDecision(previousDecision, for: origin, profileID: profileID)
            if let previousSetting { defaults.set(previousSetting, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }

        adapter.setProfileForTesting(profileID, on: dataStore)
        repository.setDecision(.allowed, for: origin, profileID: profileID)
        setting.set(false, in: defaults)

        #expect(adapter.notificationPermissions(for: dataStore).isEmpty)
    }

    @Test func nativeForegroundDeliveryUsesOnlyTheNotificationsSecurityOrigin() async throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: setting.userDefaultsKey)
        defer {
            if let previousSetting { defaults.set(previousSetting, forKey: setting.userDefaultsKey) }
            else { defaults.removeObject(forKey: setting.userDefaultsKey) }
        }
        setting.set(true, in: defaults)
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }
        var subtitle: String?
        panel.deliverWebNotification = { _, _, _, deliveredSubtitle, _ in
            subtitle = deliveredSubtitle
        }

        let loadProbe = BrowserWebNotificationLoadProbe()
        panel.webView.navigationDelegate = loadProbe
        defer { panel.webView.navigationDelegate = nil }
        try await loadProbe.load(
            "<!doctype html><html><body>unrelated active page</body></html>",
            in: panel.webView,
            baseURL: try #require(URL(string: "https://wrong.example"))
        )

        panel.handleNativeWebNotification(title: "No origin", body: "Ready")
        #expect(subtitle == "")

        panel.handleNativeWebNotification(
            title: "Origin probe",
            body: "Ready",
            securityOrigin: try #require(URL(string: "http://cmux-loopback.localtest.me:4317"))
        )
        #expect(subtitle == "localhost")
    }

    @Test func removedNativeManagerAddressCanBeProvisionedAgain() {
        let adapter = BrowserWebNotificationNativeAdapter.shared
        let manager = UnsafeRawPointer(bitPattern: 0xCAFE)!
        defer { adapter.simulateManagerRemovalForTesting(manager) }
        #expect(adapter.provisionManagerForTesting(manager))
        #expect(adapter.isManagerTrackedForTesting(manager))

        adapter.simulateManagerRemovalForTesting(manager)
        #expect(!adapter.isManagerTrackedForTesting(manager))
        #expect(adapter.provisionManagerForTesting(manager))
    }

    @Test func nativeForegroundAcknowledgementSurvivesPageRegistrationTeardown() {
        let adapter = BrowserWebNotificationNativeAdapter.shared
        let pageKey: UInt = 0xBEEF
        let manager = UnsafeRawPointer(bitPattern: 0xCAFE)!
        let notificationID: UInt64 = 42
        var acknowledged: (manager: UnsafeRawPointer, notificationID: UInt64)?
        adapter.didShowObserverForTesting = { manager, notificationID in
            acknowledged = (manager, notificationID)
        }
        adapter.trackPageManagerForTesting(pageKey: pageKey, manager: manager)
        adapter.simulatePageRegistrationTeardownForTesting(pageKey: pageKey)
        defer {
            adapter.simulateManagerRemovalForTesting(manager)
            adapter.resetNativeDeliveryTestingState()
        }

        adapter.acknowledgeForegroundNotificationForTesting(
            pageKey: pageKey,
            notificationID: notificationID
        )

        #expect(acknowledged?.manager == manager)
        #expect(acknowledged?.notificationID == notificationID)
    }

    @Test func rejectedPersistentClickOpensTheDisplayOrigin() throws {
        let adapter = BrowserWebNotificationNativeAdapter.shared
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let notificationID = UUID()
        let proxyOrigin = try #require(URL(string: "http://cmux-loopback.localtest.me:4317"))
        var openedURL: URL?
        adapter.persistentClickProcessorForTesting = { _, _, completion in
            completion(false)
            return true
        }
        adapter.externalURLOpenerForTesting = { url in
            openedURL = url
            return true
        }
        adapter.registerPersistentClickForTesting(
            notificationID: notificationID,
            dataStore: dataStore,
            origin: proxyOrigin
        )
        defer { adapter.resetNativeDeliveryTestingState() }

        adapter.handleGlobalNotificationClick(notificationID: notificationID, fallbackOrigin: proxyOrigin)
        #expect(openedURL?.absoluteString == "http://localhost:4317")
    }

    @Test func clearingWebsiteNotificationReleasesPersistentClickPayload() throws {
        let store = TerminalNotificationStore.shared
        let adapter = BrowserWebNotificationNativeAdapter.shared
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let origin = try #require(URL(string: "https://example.com"))
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureNotificationRemovalHandlerForTesting { notificationIDs in
            adapter.removePersistentClickRegistrations(notificationIDs: notificationIDs)
        }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetNotificationRemovalHandlerForTesting()
            adapter.resetNativeDeliveryTestingState()
        }

        let notificationID = store.addGlobalWebsiteNotification(
            title: "Background",
            subtitle: "example.com",
            body: "Ready",
            origin: origin
        )
        adapter.registerPersistentClickForTesting(
            notificationID: notificationID,
            dataStore: dataStore,
            dictionary: ["serialized": String(repeating: "x", count: 4_096)],
            origin: origin
        )
        #expect(adapter.hasPersistentClickRegistrationForTesting(notificationID))

        store.remove(id: notificationID)

        #expect(!adapter.hasPersistentClickRegistrationForTesting(notificationID))
    }

    @Test func websiteClickMarksReadOnlyWhenTheActionIsAccepted() throws {
        let store = TerminalNotificationStore.shared
        let adapter = BrowserWebNotificationNativeAdapter.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalStore = appDelegate.notificationStore
        let origin = try #require(URL(string: "https://example.com"))
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        defer {
            appDelegate.notificationStore = originalStore
            adapter.resetNativeDeliveryTestingState()
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
        }
        appDelegate.notificationStore = store

        let rejectedID = store.addGlobalWebsiteNotification(
            title: "Rejected",
            subtitle: "example.com",
            body: "Ready",
            origin: origin
        )
        let rejected = try #require(store.notifications.first(where: { $0.id == rejectedID }))
        adapter.externalURLOpenerForTesting = { _ in false }
        #expect(!appDelegate.openTerminalNotification(rejected))
        #expect(store.notifications.first(where: { $0.id == rejectedID })?.isRead == false)

        let acceptedID = store.addGlobalWebsiteNotification(
            title: "Accepted",
            subtitle: "example.com",
            body: "Ready",
            origin: origin
        )
        let accepted = try #require(store.notifications.first(where: { $0.id == acceptedID }))
        adapter.externalURLOpenerForTesting = { _ in true }
        #expect(appDelegate.openTerminalNotification(accepted))
        #expect(store.notifications.first(where: { $0.id == acceptedID })?.isRead == true)
    }

    @Test func websiteOSResponseUsesWebsiteClickRouting() throws {
        let store = TerminalNotificationStore.shared
        let adapter = BrowserWebNotificationNativeAdapter.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalStore = appDelegate.notificationStore
        let origin = try #require(URL(string: "https://example.com"))
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        adapter.externalURLOpenerForTesting = { _ in true }
        defer {
            appDelegate.notificationStore = originalStore
            adapter.resetNativeDeliveryTestingState()
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
        }
        appDelegate.notificationStore = store
        let notificationID = store.addGlobalWebsiteNotification(
            title: "OS click",
            subtitle: "example.com",
            body: "Ready",
            origin: origin
        )

        appDelegate.handleNotificationResponseForTesting(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: notificationID.uuidString,
            userInfo: [
                TerminalNotificationStore.websiteDisplayOriginUserInfoKey: origin.absoluteString,
            ]
        )
        #expect(store.notifications.first(where: { $0.id == notificationID })?.isRead == true)
    }

    @Test func settingsFileAndGeneratedTemplateExposeForwardingToggle() throws {
        let setting = SettingCatalog().browser.forwardWebNotifications
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: setting.userDefaultsKey)
        let backupsKey = "cmux.settingsFile.backups.v1"
        let importedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
        let previousBackups = defaults.data(forKey: backupsKey)
        let previousImportedDefaults = defaults.data(forKey: importedDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: setting.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: setting.userDefaultsKey)
            }
            if let previousBackups { defaults.set(previousBackups, forKey: backupsKey) }
            else { defaults.removeObject(forKey: backupsKey) }
            if let previousImportedDefaults { defaults.set(previousImportedDefaults, forKey: importedDefaultsKey) }
            else { defaults.removeObject(forKey: importedDefaultsKey) }
        }
        defaults.removeObject(forKey: backupsKey)
        defaults.removeObject(forKey: importedDefaultsKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-notification-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("cmux.json")

        try """
        { "browser": { "forwardWebNotifications": false } }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let fileStore = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(setting.value(in: defaults) == false)

        try """
        { "browser": { "forwardWebNotifications": true } }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        fileStore.reload()
        #expect(setting.value(in: defaults))
        #expect(CmuxSettingsFileStore.defaultTemplate().contains("\"forwardWebNotifications\" : false")
            || CmuxSettingsFileStore.defaultTemplate().contains("\"forwardWebNotifications\": false"))
    }

}
