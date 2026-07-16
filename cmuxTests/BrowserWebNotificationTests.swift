import CmuxSettings
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class BrowserWebNotificationContractProbe: NSObject, WKScriptMessageHandler {
    private(set) var bodies: [[String: String]] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: String] else { return }
        bodies.append(body)
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
        controller.add(probe, contentWorld: .page, name: BrowserWebNotificationMessageHandler.name)
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
        #expect(denied["permission"] as? String == "denied")
        #expect(denied["requestPermissionIsFunction"] as? Bool == true)
        #expect(denied["samePrototype"] as? Bool == true)
        #expect(denied["nativeReturn"] as? Bool == true)
        #expect(denied["instanceOfWrapped"] as? Bool == true)
        #expect(denied["onclickPreserved"] as? Bool == true)
        #expect(probe.bodies.isEmpty)

        _ = try await webView.evaluateJavaScript(
            "__setNotificationPermission('granted'); new Notification('Granted', { body: 'Forward me' });"
        )
        #expect(probe.bodies == [[
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
        #expect(setting.value(in: defaults))

        let workspaceID = UUID()
        let panel = BrowserPanel(workspaceId: workspaceID, renderInitialNavigation: false)
        defer { panel.close() }
        panel.deliverWebNotification = { workspaceId, surfaceId, title, subtitle, body in
            store.addNotification(
                tabId: workspaceId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body,
                retargetsToLiveSurfaceOwner: false
            )
        }

        let payload = BrowserWebNotificationPayload(title: "Deploy", body: "Finished", hostname: "example.com")
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
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }
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
                      token: \(encodedJavaScriptString(oldToken)), title: "Late", body: "Old"
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

    @Test func settingsFileAndGeneratedTemplateExposeForwardingToggle() throws {
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
        #expect(CmuxSettingsFileStore.defaultTemplate().contains("\"forwardWebNotifications\" : true")
            || CmuxSettingsFileStore.defaultTemplate().contains("\"forwardWebNotifications\": true"))
    }

    private func encodedJavaScriptString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }
}
