import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class BrowserPanelInitialNavigationTests: XCTestCase {
    func testInitialURLCanBePreservedWithoutRenderingWebView() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/custom-layout"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            renderInitialNavigation: false
        )

        XCTAssertEqual(panel.currentURL, url)
        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertFalse(panel.shouldRenderWebViewForSessionSnapshot())
    }

    func testDiffViewerURLIsNotPersistedForSessionRestore() throws {
        let schemeURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://token/index.html"))
        let schemePanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: schemeURL,
            renderInitialNavigation: false
        )

        XCTAssertEqual(schemePanel.preferredURLStringForOmnibar(), schemeURL.absoluteString)
        XCTAssertNil(schemePanel.preferredURLStringForSessionSnapshot())
        XCTAssertFalse(schemePanel.shouldPersistSessionSnapshot())
        XCTAssertFalse(schemePanel.shouldRenderWebViewForSessionSnapshot())

        let loopbackURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/token/diff.html#cmux-diff-viewer"))
        let loopbackPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: loopbackURL,
            renderInitialNavigation: false
        )
        XCTAssertEqual(loopbackPanel.preferredURLStringForOmnibar(), loopbackURL.absoluteString)
        XCTAssertNil(loopbackPanel.preferredURLStringForSessionSnapshot())
        XCTAssertFalse(loopbackPanel.shouldPersistSessionSnapshot())
        XCTAssertFalse(loopbackPanel.shouldRenderWebViewForSessionSnapshot())

        let aliasURL = try XCTUnwrap(URL(string: "http://cmux-loopback.localtest.me:49152/token/diff.html#cmux-diff-viewer"))
        let aliasPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: aliasURL,
            renderInitialNavigation: false
        )
        XCTAssertNil(aliasPanel.preferredURLStringForSessionSnapshot())
        XCTAssertFalse(aliasPanel.shouldPersistSessionSnapshot())

        let normalLocalhostURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/app"))
        let normalLocalhostPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: normalLocalhostURL,
            renderInitialNavigation: false
        )
        XCTAssertEqual(normalLocalhostPanel.preferredURLStringForSessionSnapshot(), normalLocalhostURL.absoluteString)
        XCTAssertTrue(normalLocalhostPanel.shouldPersistSessionSnapshot())
    }

    func testDiffViewerURLIsNotRecordedInBrowserHistory() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-history-\(UUID().uuidString).json")
        let store = BrowserHistoryStore(fileURL: fileURL)
        defer {
            store.clearHistory()
            try? FileManager.default.removeItem(at: fileURL)
        }

        let schemeURL = try XCTUnwrap(URL(string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://token/index.html"))
        let loopbackURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/token/diff.html#cmux-diff-viewer"))
        let aliasURL = try XCTUnwrap(URL(string: "http://cmux-loopback.localtest.me:49152/token/diff.html#cmux-diff-viewer"))
        let normalURL = try XCTUnwrap(URL(string: "https://example.com/page"))

        store.recordVisit(url: schemeURL, title: "Diff")
        store.recordVisit(url: loopbackURL, title: "Diff")
        store.recordVisit(url: aliasURL, title: "Diff")
        store.recordTypedNavigation(url: aliasURL)
        store.recordTypedNavigation(url: loopbackURL)
        XCTAssertTrue(store.entries.isEmpty)

        store.recordVisit(url: normalURL, title: "Normal")
        XCTAssertEqual(store.entries.map(\.url), [normalURL.absoluteString])
    }
}


