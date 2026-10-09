import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A download's failure text is WebKit's and can name the download's URL,
/// credentials included. A session that drives a tab it did not create (a
/// user's tab) never reads URL credentials there, so the
/// `download.finished` error it gets has them replaced, as its
/// `download.started` URL does (docs/browser-repl/README.md, Sessions and
/// tabs).
@MainActor
@Suite(.serialized)
struct BrowserReplDownloadErrorRedactionTests {
    private final class Events {
        var received: [(String, [String: Any])] = []
    }

    @Test func aFailedDownloadInAUsersTabNamesNoURLCredentials() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            defer {
                appDelegate.tabManager = nil
                AppDelegate.shared = previousAppDelegate
            }
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            appDelegate.tabManager = tabManager
            let workspace = tabManager.addWorkspace(select: true)
            defer {
                if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                    tabManager.closeWorkspace(workspace)
                }
            }
            let pane = try #require(workspace.bonsplitController.focusedPaneId)
            // The user's tab: no session created it.
            let panel = try #require(workspace.newBrowserSurface(
                inPane: pane,
                url: URL(string: "about:blank"),
                focus: false,
                creationPolicy: .automationPreload
            ))
            let sessionID = "download-error-redaction-\(UUID().uuidString)"
            defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
            let events = Events()
            let attachment = try BrowserReplTabAttachments.shared.attach(
                panel: panel,
                sessionID: sessionID,
                world: .world(name: sessionID)
            ) { name, payload in events.received.append((name, payload)) }
            attachment.setHandledEvents([.download], sessionID: sessionID)

            let secretURL = "https://alice:hunter2@files.example.com/report.csv"
            let route = attachment.downloadDidStart(
                id: "d1",
                startedBy: sessionID,
                source: BrowserReplDownloadSource(hops: [secretURL]),
                url: URL(string: secretURL),
                suggestedFilename: "report.csv"
            )
            guard case .session = route else {
                Issue.record("The session's own download in a user's tab was not routed to it: \(route)")
                return
            }
            attachment.downloadDidFail(id: "d1", error: "The download from \(secretURL) failed.")

            let finished = try #require(events.received.last { $0.0 == "download.finished" })
            let error = try #require(finished.1["error"] as? String)
            #expect(!error.contains("hunter2"), "a non-creating session read the URL's credentials: \(error)")
            #expect(error.contains("files.example.com"))
        }
    }
}
