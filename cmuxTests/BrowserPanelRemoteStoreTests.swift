@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class BrowserPanelRemoteStoreTests: XCTestCase {
    func testRemoteWorkspacePanelsShareWorkspaceScopedWebsiteDataStore() {
        let localPanel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        let remoteWorkspaceId = UUID()
        let firstRemotePanel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        let secondRemotePanel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )

        XCTAssertTrue(localPanel.webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertFalse(firstRemotePanel.webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(
            firstRemotePanel.webView.configuration.websiteDataStore ===
                secondRemotePanel.webView.configuration.websiteDataStore
        )
    }

    func testRemoteWorkspaceDefersInitialNavigationUntilProxyEndpointIsReady() {
        let remoteWorkspaceId = UUID()
        let url = URL(string: "http://localhost:3000/demo")!
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            initialURL: url,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertNil(panel.webView.url)

        panel.setRemoteProxyEndpoint(BrowserProxyEndpoint(host: "127.0.0.1", port: 9876))

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.url == nil, RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertEqual(panel.webView.url?.host, "cmux-loopback.localtest.me")
    }

    func testRemoteWorkspacePreservesLocalhostSubdomainWhenAliasingLoopbackURL() {
        let remoteWorkspaceId = UUID()
        let url = URL(string: "http://api.localhost:3000/demo")!
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            initialURL: url,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertNil(panel.webView.url)

        panel.setRemoteProxyEndpoint(BrowserProxyEndpoint(host: "127.0.0.1", port: 9876))

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.url == nil, RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertEqual(panel.webView.url?.host, "api.cmux-loopback.localtest.me")
    }

    func testRemoteWorkspaceRuntimeBridgeAliasesMultipleLoopbackPortsFromSamePage() async throws {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        let baseURL = try XCTUnwrap(URL(string: "http://cmux-loopback.localtest.me:3000/"))

        panel.webView.loadHTMLString(
            "<!doctype html><html><body>remote loopback bridge</body></html>",
            baseURL: baseURL
        )
        try await waitForBrowserWebViewLoad(panel.webView)

        let result = try await panel.evaluateJavaScript(
            """
            (() => {
              const rewrite = window.__cmuxRewriteRemoteLoopbackURL;
              if (typeof rewrite !== 'function') {
                return 'missing bridge';
              }
              return JSON.stringify([
                rewrite('http://localhost:3000/frontend'),
                rewrite('http://localhost:8000/api'),
                rewrite('http://api.localhost:8000/v1'),
                rewrite('ws://localhost:5173/hmr'),
                rewrite('wss://localhost:5173/hmr'),
                rewrite('https://localhost:9443/secure')
              ]);
            })()
            """
        ) as? String

        XCTAssertEqual(
            result,
            #"["http://cmux-loopback.localtest.me:3000/frontend","http://cmux-loopback.localtest.me:8000/api","http://api.cmux-loopback.localtest.me:8000/v1","ws://cmux-loopback.localtest.me:5173/hmr","wss://localhost:5173/hmr","https://localhost:9443/secure"]"#
        )
    }

    func testRemoteWorkspaceKeepsHTTPSLoopbackUnaliased() {
        let remoteWorkspaceId = UUID()
        let url = URL(string: "https://localhost:3443/demo")!
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            initialURL: url,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertNil(panel.webView.url)

        panel.setRemoteProxyEndpoint(BrowserProxyEndpoint(host: "127.0.0.1", port: 9876))

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.url == nil, RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}

        XCTAssertEqual(panel.preferredURLStringForOmnibar(), url.absoluteString)
        XCTAssertEqual(panel.webView.url?.host, "localhost")
    }

    private func waitForBrowserWebViewLoad(_ webView: WKWebView, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while webView.isLoading {
            if Date() >= deadline {
                XCTFail("Timed out waiting for browser web view to finish loading")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testBrowserMoveIntoRemoteWorkspaceRebuildsWebsiteDataStoreScope() throws {
        let source = Workspace()
        let sourcePaneId = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let sourceBrowser = try XCTUnwrap(source.newBrowserSurface(inPane: sourcePaneId, focus: false))
        let localStore = sourceBrowser.webView.configuration.websiteDataStore
        XCTAssertTrue(localStore === WKWebsiteDataStore.default())

        let destination = Workspace()
        destination.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: 22,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64001,
                relayID: "relay-store-dest",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-store-dest.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let destinationPaneId = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let destinationBrowser = try XCTUnwrap(destination.newBrowserSurface(inPane: destinationPaneId, focus: false))
        let destinationStore = destinationBrowser.webView.configuration.websiteDataStore
        XCTAssertFalse(destinationStore === WKWebsiteDataStore.default())

        let detached = try XCTUnwrap(source.detachSurface(panelId: sourceBrowser.id))
        let attachedPanelId = try XCTUnwrap(
            destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false)
        )
        let movedBrowser = try XCTUnwrap(destination.panels[attachedPanelId] as? BrowserPanel)

        XCTAssertTrue(movedBrowser.webView.configuration.websiteDataStore === destinationStore)
        XCTAssertFalse(movedBrowser.webView.configuration.websiteDataStore === localStore)
    }

    func testBrowserMoveOutOfRemoteWorkspaceRestoresDefaultWebsiteDataStore() throws {
        let source = Workspace()
        source.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: 22,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64002,
                relayID: "relay-store-source",
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-store-source.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let sourcePaneId = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let movedBrowser = try XCTUnwrap(source.newBrowserSurface(inPane: sourcePaneId, focus: false))
        let remainingRemoteBrowser = try XCTUnwrap(source.newBrowserSurface(inPane: sourcePaneId, focus: false))
        let remoteStore = remainingRemoteBrowser.webView.configuration.websiteDataStore
        XCTAssertFalse(remoteStore === WKWebsiteDataStore.default())

        let destination = Workspace()
        let destinationPaneId = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let detached = try XCTUnwrap(source.detachSurface(panelId: movedBrowser.id))
        let attachedPanelId = try XCTUnwrap(
            destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false)
        )
        let attachedBrowser = try XCTUnwrap(destination.panels[attachedPanelId] as? BrowserPanel)

        XCTAssertTrue(attachedBrowser.webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(remainingRemoteBrowser.webView.configuration.websiteDataStore === remoteStore)
        XCTAssertFalse(remainingRemoteBrowser.webView.configuration.websiteDataStore === attachedBrowser.webView.configuration.websiteDataStore)
    }

    func testNewTerminalSurfaceStaysRemoteWhileBrowserPanelsKeepWorkspaceRemote() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let initialTerminalId = try XCTUnwrap(workspace.focusedPanelId)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64000,
            relayID: "relay-test",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(configuration, autoConnect: false)
        _ = workspace.newBrowserSurface(inPane: paneId, url: URL(string: "https://example.com"), focus: false)

        workspace.markRemoteTerminalSessionEnded(surfaceId: initialTerminalId, relayPort: configuration.relayPort)

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)

        _ = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
    }
}

