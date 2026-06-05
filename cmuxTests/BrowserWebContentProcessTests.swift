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
