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
    func browserPanelsUseSeparateWebContentProcessPools() {
        let first = BrowserPanel(workspaceId: UUID())
        let second = BrowserPanel(workspaceId: UUID())
        defer {
            first.close()
            second.close()
        }

        #expect(!(first.webView.configuration.processPool === second.webView.configuration.processPool))
        #expect(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
    }

    @Test
    func configureWebViewConfigurationPreservesCopiedProcessPoolWhenOmitted() {
        let configuration = WKWebViewConfiguration()
        let originalProcessPool = configuration.processPool
        let suppliedProcessPool = WKProcessPool()

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .nonPersistent()
        )
        #expect(configuration.processPool === originalProcessPool)

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .nonPersistent(),
            processPool: suppliedProcessPool
        )
        #expect(configuration.processPool === suppliedProcessPool)
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
        let oldProcessPool = oldWebView.configuration.processPool

        panel.debugSimulateWebContentProcessTermination()

        #expect(!(panel.webView === oldWebView))
        #expect(panel.webViewInstanceID != oldInstanceID)
        #expect(panel.webView.configuration.processPool === oldProcessPool)
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(panel.webView.navigationDelegate != nil)
        #expect(panel.webView.uiDelegate != nil)
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
