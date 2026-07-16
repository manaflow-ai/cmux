import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class BrowserWebNotificationContractProbe: NSObject, WKScriptMessageHandlerWithReply {
    private(set) var bodies: [[String: String]] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: String] else {
            replyHandler(nil, "invalid_message")
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

    @Test func nativeProviderGrantsAndDeliversOnSupportedMacOS() async throws {
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

        let profileID = UUID()
        let origin = try #require(URL(string: "https://example.com"))
        let id = store.addGlobalWebsiteNotification(
            title: "Background",
            subtitle: "example.com",
            body: "Ready",
            profileID: profileID,
            origin: origin
        )
        let notification = try #require(store.notifications.first(where: { $0.id == id }))
        #expect(notification.target == .global)
        #expect(notification.tabId == TerminalNotification.globalTargetSentinel)
        #expect(notification.paneFlash == false)
        #expect(notification.source == .website(profileID: profileID, origin: origin, isBackground: true))
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
