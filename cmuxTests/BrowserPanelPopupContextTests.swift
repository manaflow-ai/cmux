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
final class BrowserPanelPopupContextTests: XCTestCase {
    func testFloatingPopupInheritsOpenerBrowserContext() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        let popupWebView = try XCTUnwrap(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        XCTAssertTrue(
            popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore
        )
    }

    func testFloatingPopupInheritsRemoteWorkspaceWebsiteDataStore() throws {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        let popupWebView = try XCTUnwrap(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        XCTAssertTrue(
            popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore
        )
        XCTAssertFalse(popupWebView.configuration.websiteDataStore === WKWebsiteDataStore.default())
    }
}

