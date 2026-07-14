import AppKit
import CmuxSettings
import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserWebExtensionSupportLifecycleTests {
    @Test
    func repeatedReplacementForSameExtensionContextKeepsWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false
        )
        defer { panel.close() }
        let context = NSObject()
        let contextIdentifier = ObjectIdentifier(context)

        panel.replaceWebViewForWebExtensionNavigation(
            webViewConfiguration: WKWebViewConfiguration(),
            contextIdentifier: contextIdentifier
        )
        let firstReplacement = panel.webView

        panel.replaceWebViewForWebExtensionNavigation(
            webViewConfiguration: WKWebViewConfiguration(),
            contextIdentifier: contextIdentifier
        )

        #expect(panel.webView === firstReplacement)
    }

    @Test
    func extensionContextSwapPreservesLogicalNavigationHistory() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false
        )
        defer { panel.close() }
        let backURL = try #require(URL(string: "https://example.com/back"))
        let currentURL = try #require(URL(string: "https://example.com/current"))
        let extensionURL = try #require(URL(string: "webkit-extension://cmux-test/options.html"))
        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [backURL.absoluteString],
            forwardHistoryURLStrings: [],
            currentURLString: currentURL.absoluteString
        )

        panel.navigateFromWebExtension(
            to: extensionURL,
            webViewConfiguration: WKWebViewConfiguration()
        )

        #expect(panel.canGoBack)
        let history = panel.sessionNavigationHistorySnapshot()
        #expect(history.backHistoryURLStrings == [
            backURL.absoluteString,
            currentURL.absoluteString,
        ])
    }

    @Test
    @available(macOS 15.4, *)
    func startupRestoreDoesNotWaitForExtensionSettingsReconciliation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let appDelegate = try #require(AppDelegate.shared)
            let previousDidAttemptStartupSessionRestore = appDelegate.didAttemptStartupSessionRestore
            let support = BrowserWebExtensionSupport()
            let tabManager = TabManager(
                autoWelcomeIfNeeded: false,
                browserWebExtensionHost: support
            )
            let window = NSWindow()
            let windowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: tabManager,
                window: window
            )
            appDelegate.didAttemptStartupSessionRestore = false
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                tabManager.tabs.forEach { $0.teardownAllPanels() }
                window.close()
                appDelegate.didAttemptStartupSessionRestore = previousDidAttemptStartupSessionRestore
            }

            appDelegate.completeMainWindowRegistrationWhenBrowserExtensionsReady(
                tabManager: tabManager,
                window: window
            )

            #expect(appDelegate.didAttemptStartupSessionRestore)
        }
    }

    @Test
    @available(macOS 15.4, *)
    func loadingContextRepairsAnExtensionPageRestoredBeforeReconciliation() async throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-late-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = """
        {
          "manifest_version": 3,
          "name": "Late Context Test Extension",
          "version": "1.0"
        }
        """
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        let entry = BrowserWebExtensionEntry(
            id: "late-context-\(UUID().uuidString)",
            kind: .unpackedDirectory,
            path: directory.path,
            enabled: true
        )

        let probeSupport = BrowserWebExtensionSupport()
        await probeSupport.apply(entries: [entry])
        let probeContext = try #require(probeSupport.context(forActionID: entry.id))
        let extensionURL = probeContext.baseURL.appendingPathComponent("restored.html")
        #expect(probeSupport.unloadAllWebExtensions())

        let support = BrowserWebExtensionSupport()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: extensionURL,
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        support.register(panel: panel)
        defer {
            support.unregister(panelID: panel.id)
            _ = support.unloadAllWebExtensions()
            panel.close()
        }
        #expect(panel.webExtensionPageContextIdentifier == nil)

        await support.apply(entries: [entry])

        let loadedContext = try #require(support.context(forActionID: entry.id))
        #expect(panel.webExtensionPageContextIdentifier == ObjectIdentifier(loadedContext))
        #expect(!panel.shouldRenderWebView)
    }

    @Test
    @available(macOS 15.4, *)
    func teardownExplicitlyRemovesPermissionObserverTokens() {
        let notificationCenter = NotificationCenter.default
        let name = Notification.Name("cmuxTests.browserWebExtension.permissionObserver")
        let notificationReceived = DispatchSemaphore(value: 0)
        let token = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived.signal()
        }
        defer { notificationCenter.removeObserver(token) }

        var support: BrowserWebExtensionSupport? = BrowserWebExtensionSupport()
        weak var weakSupport = support
        support?.permissionObserverTokensByEntryID["test"] = [ObjectIdentifier(NSObject()): [token]]
        support = nil

        #expect(weakSupport == nil)
        notificationCenter.post(name: name, object: nil)
        #expect(notificationReceived.wait(timeout: .now()) == .timedOut)
    }
}
