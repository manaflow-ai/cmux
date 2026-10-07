import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A tab a `cmux browser repl` session drives never hands a page-opened
/// window to the system browser: when the user has turned the embedded
/// browser off while the tab stays open, the popup is refused, not opened
/// outside the session's domain policy (docs/browser-repl/README.md,
/// Sessions and tabs).
@MainActor
@Suite(.serialized)
struct BrowserReplPopupExternalFallbackTests {
    private final class Opens {
        var urls: [URL] = []
    }

    @Test func sessionPopupsNeverOpenTheSystemBrowserWhileTheBrowserIsDisabled() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let defaults = UserDefaults.standard
            let previousOverride = BrowserAvailabilitySettings.managedPolicyOverrideForTesting
            let previousUserValue = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
            defer {
                BrowserAvailabilitySettings.managedPolicyOverrideForTesting = previousOverride
                if let previousUserValue {
                    defaults.set(previousUserValue, forKey: BrowserAvailabilitySettings.disabledKey)
                } else {
                    defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
                }
                appDelegate.tabManager = nil
                AppDelegate.shared = previousAppDelegate
            }
            BrowserAvailabilitySettings.managedPolicyOverrideForTesting = false
            defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            appDelegate.tabManager = tabManager
            let workspace = tabManager.addWorkspace(select: true)
            defer {
                if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                    tabManager.closeWorkspace(workspace)
                }
            }
            let opens = Opens()
            workspace.externalBrowserFallbackOpenForTesting = { opens.urls.append($0) }
            let pane = try #require(workspace.bonsplitController.focusedPaneId)
            // The session's tab exists before the user turns the browser off.
            let panel = try #require(workspace.newBrowserSurface(
                inPane: pane,
                url: URL(string: "about:blank"),
                focus: false,
                creationPolicy: .automationPreload
            ))
            let sessionID = "popup-fallback-test-\(UUID().uuidString)"
            defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
            let attachment = try BrowserReplTabAttachments.shared.attach(
                panel: panel,
                sessionID: sessionID,
                world: .world(name: sessionID)
            ) { _, _ in }
            attachment.markCreated(by: sessionID)

            // The user-level toggle keeps open tabs open.
            defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
            let popupURL = try #require(URL(string: "https://popup.example.com/leak?token=page-held"))
            let request = URLRequest(url: popupURL)

            // `.session` route: the tab the session created.
            if case .opened? = attachment.adoptPopup(request: request, configuration: WKWebViewConfiguration()) {
                Issue.record("A popup tab opened while the browser is disabled")
            }
            #expect(attachment.handlePopup(request: request) == false)
            // `.inputSession` route: the window opened for the session's input.
            if case .opened? = attachment.adoptPopup(
                request: request,
                configuration: WKWebViewConfiguration(),
                forInputSession: sessionID
            ) {
                Issue.record("A popup tab opened for the session's input while the browser is disabled")
            }
            #expect(attachment.handlePopup(request: request, forInputSession: sessionID) == false)
            // `.browser` route: a background tab nobody is told of.
            if case .opened? = attachment.adoptPopup(
                request: request,
                configuration: WKWebViewConfiguration(),
                announce: false
            ) {
                Issue.record("A background popup tab opened while the browser is disabled")
            }

            #expect(opens.urls.isEmpty, "A session's popup went to the system browser: \(opens.urls)")
            #expect(workspace.panels.values.filter { $0 is BrowserPanel }.count == 1)
        }
    }
}
