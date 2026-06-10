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


private func drainBrowserPanelMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1.0)
}

@MainActor
private func makeTemporaryBrowserPanelProfile(named prefix: String) throws -> BrowserProfileDefinition {
    try XCTUnwrap(
        BrowserProfileStore.shared.createProfile(
            named: "\(prefix)-\(UUID().uuidString)"
        )
    )
}

@MainActor
final class BrowserPanelProfileIsolationTests: XCTestCase {
    func testStaleDidFinishDoesNotRecordVisitIntoSwitchedProfileHistory() throws {
        let alternateProfile = try makeTemporaryBrowserPanelProfile(named: "Switched")
        let defaultStore = BrowserHistoryStore.shared
        let alternateStore = BrowserProfileStore.shared.historyStore(for: alternateProfile.id)
        defaultStore.clearHistory()
        alternateStore.clearHistory()
        defer {
            defaultStore.clearHistory()
            alternateStore.clearHistory()
        }

        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID
        )
        let staleWebView = panel.webView
        let staleDelegate = try XCTUnwrap(staleWebView.navigationDelegate)
        let staleURL = try XCTUnwrap(URL(string: "https://example.com/stale-finish"))
        staleWebView.loadHTMLString(
            "<html><head><title>Stale</title></head><body>stale</body></html>",
            baseURL: staleURL
        )

        XCTAssertTrue(
            panel.switchToProfile(alternateProfile.id),
            "Expected profile switch to succeed, current=\(panel.profileID) requested=\(alternateProfile.id) exists=\(BrowserProfileStore.shared.profileDefinition(id: alternateProfile.id) != nil)"
        )
        defaultStore.clearHistory()
        alternateStore.clearHistory()

        staleDelegate.webView?(staleWebView, didFinish: nil)
        drainBrowserPanelMainQueue()

        XCTAssertTrue(
            defaultStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the old profile history store, found \(defaultStore.entries.map { $0.url })"
        )
        XCTAssertTrue(
            alternateStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the newly selected profile history store, found \(alternateStore.entries.map { $0.url })"
        )
    }
}


