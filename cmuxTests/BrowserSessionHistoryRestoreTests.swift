import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Session history restore
@MainActor
final class BrowserSessionHistoryRestoreTests: XCTestCase {
    private final class ProvisionalNavigationRaceServer {
        enum ServerError: Error {
            case listenerDidNotBecomeReady
            case listenerPortUnavailable
        }

        private static let queueKey = DispatchSpecificKey<Void>()
        private let listener: NWListener
        private let queue = DispatchQueue(label: "cmux.browser.provisional-navigation-race-server")
        private let lock = NSLock()
        private var heldBConnections: [NWConnection] = []
        private var receivedBRequest = false
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: .any
            )
            listener = try NWListener(using: parameters)
            queue.setSpecific(key: Self.queueKey, value: ())

            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    ready.signal()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)

            guard ready.wait(timeout: .now() + 2.0) == .success else {
                throw ServerError.listenerDidNotBecomeReady
            }
            guard let port = listener.port?.rawValue else {
                throw ServerError.listenerPortUnavailable
            }
            self.port = port
        }

        var didReceiveBRequest: Bool {
            lock.lock()
            defer { lock.unlock() }
            return receivedBRequest
        }

        func url(path: String) -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)")!
        }

        func releaseHeldBResponses() -> Int {
            if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
                return releaseHeldBResponsesOnQueue()
            }
            return queue.sync {
                releaseHeldBResponsesOnQueue()
            }
        }

        private func releaseHeldBResponsesOnQueue() -> Int {
            let connections: [NWConnection]
            lock.lock()
            connections = heldBConnections
            heldBConnections.removeAll()
            lock.unlock()

            for connection in connections {
                sendPage("B", on: connection)
            }
            return connections.count
        }

        func stop() {
            listener.cancel()
            _ = releaseHeldBResponses()
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            receiveRequest(on: connection)
        }

        private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
                guard let self else { return }
                if error != nil {
                    connection.cancel()
                    return
                }

                var nextBuffer = buffer
                if let data {
                    nextBuffer.append(data)
                }

                guard let requestText = String(data: nextBuffer, encoding: .utf8),
                      requestText.contains("\r\n\r\n") else {
                    self.receiveRequest(on: connection, buffer: nextBuffer)
                    return
                }

                let requestLine = requestText.split(separator: "\r\n", maxSplits: 1).first ?? ""
                let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if path == "/b" {
                    self.lock.lock()
                    self.receivedBRequest = true
                    self.heldBConnections.append(connection)
                    self.lock.unlock()
                    return
                }

                self.sendPage("A", on: connection)
            }
        }

        private func sendPage(_ marker: String, on connection: NWConnection) {
            let body = """
            <!doctype html>
            <html>
            <head><title>Race \(marker)</title></head>
            <body>
            <script>window.__cmuxRacePage = "\(marker)";</script>
            <main id="page">Race \(marker)</main>
            </body>
            </html>
            """
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func writeBrowserFixturePage(
        at url: URL,
        title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let html = """
        <html>
        <head><title>\(title)</title></head>
        <body>\(title)</body>
        </html>
        """

        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to write browser fixture page: \(error)", file: file, line: line)
            throw error
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTFail("Timed out waiting for \(description)", file: file, line: line)
        throw BrowserTestTimeout(description: description)
    }

    private struct BrowserTestTimeout: Error, CustomStringConvertible {
        let description: String
    }

    private func waitForBrowserPanel(
        _ panel: BrowserPanel,
        url: URL,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if panel.preferredURLStringForOmnibar() == url.absoluteString && !panel.isLoading {
                return
            }
        }

        XCTFail(
            "Timed out waiting for browser panel to load \(url.absoluteString). Current=\(panel.preferredURLStringForOmnibar() ?? "nil") loading=\(panel.isLoading)",
            file: file,
            line: line
        )
    }

    func testSessionNavigationHistorySnapshotUsesRestoredStacks() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ],
            currentURLString: "https://example.com/c"
        )

        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)

        let snapshot = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(
            snapshot.backHistoryURLStrings,
            ["https://example.com/a", "https://example.com/b"]
        )
        XCTAssertEqual(
            snapshot.forwardHistoryURLStrings,
            ["https://example.com/d"]
        )
    }

    func testSessionNavigationHistoryBackAndForwardUpdateStacks() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ],
            currentURLString: "https://example.com/c"
        )

        panel.goBack()
        let afterBack = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(afterBack.backHistoryURLStrings, ["https://example.com/a"])
        XCTAssertEqual(
            afterBack.forwardHistoryURLStrings,
            ["https://example.com/c", "https://example.com/d"]
        )
        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)

        panel.goForward()
        let afterForward = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(
            afterForward.backHistoryURLStrings,
            ["https://example.com/a", "https://example.com/b"]
        )
        XCTAssertEqual(afterForward.forwardHistoryURLStrings, ["https://example.com/d"])
        XCTAssertTrue(panel.canGoBack)
        XCTAssertTrue(panel.canGoForward)
    }

    func testGoBackPrefersLiveWKWebViewHistoryBeforeRestoredFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pageA = tempDir.appendingPathComponent("a.html")
        let pageB = tempDir.appendingPathComponent("b.html")
        let pageC = tempDir.appendingPathComponent("c.html")
        try writeBrowserFixturePage(at: pageA, title: "A")
        try writeBrowserFixturePage(at: pageB, title: "B")
        try writeBrowserFixturePage(at: pageC, title: "C")

        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: pageB
        )
        defer { panel.close() }
        waitForBrowserPanel(panel, url: pageB)

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: [pageA.absoluteString],
            forwardHistoryURLStrings: [],
            currentURLString: pageB.absoluteString
        )

        _ = browserLoadRequest(URLRequest(url: pageC), in: panel.webView)
        waitForBrowserPanel(panel, url: pageC)

        let snapshot = panel.sessionNavigationHistorySnapshot()
        XCTAssertEqual(
            snapshot.backHistoryURLStrings,
            [pageA.absoluteString, pageB.absoluteString]
        )

        panel.goBack()
        waitForBrowserPanel(panel, url: pageB)

        panel.goBack()
        waitForBrowserPanel(panel, url: pageA)
    }

    func testBackDuringProvisionalNavigationDoesNotDesyncPublishedURLFromRenderedPage() throws {
        let server = try ProvisionalNavigationRaceServer()
        defer { server.stop() }

        let pageA = server.url(path: "/a")
        let pageB = server.url(path: "/b")
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: pageA)
        defer { panel.close() }

        waitForBrowserPanel(panel, url: pageA)
        XCTAssertEqual(panel.pageTitle, "Race A")

        panel.navigate(to: pageB)
        try waitUntil("server to receive provisional page B request") {
            server.didReceiveBRequest
        }
        try waitUntil("browser back availability during provisional page B navigation") {
            panel.canGoBack && panel.webView.isLoading
        }
        XCTAssertFalse(panel.canGoForward)

        panel.goBack()
        try waitUntil("back action to expose page B as forward history before it can commit") {
            panel.currentURL?.path == pageA.path && !panel.webView.isLoading
                && panel.canGoForward
        }

        let releasedBResponseCount = server.releaseHeldBResponses()
        XCTAssertGreaterThan(releasedBResponseCount, 0)
        try waitUntil("browser to remain on page A after held page B response is released") {
            !panel.webView.isLoading &&
                panel.pageTitle == "Race A" &&
                panel.currentURL?.path == pageA.path
        }

        let publishedURL = try XCTUnwrap(panel.currentURL)
        XCTAssertEqual(publishedURL.path, pageA.path)
        XCTAssertEqual(panel.pageTitle, "Race A")
    }

    func testWebViewReplacementAfterProcessTerminationUpdatesInstanceIdentity() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://example.com")
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        let oldInstanceID = panel.webViewInstanceID

        panel.debugSimulateWebContentProcessTermination()

        XCTAssertFalse(panel.webView === oldWebView)
        XCTAssertNotEqual(panel.webViewInstanceID, oldInstanceID)
        XCTAssertNotNil(panel.webView.navigationDelegate)
        XCTAssertNotNil(panel.webView.uiDelegate)
    }

    func testWebViewReplacementPreservesEmptyNewTabRenderState() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        XCTAssertFalse(panel.shouldRenderWebView)

        panel.debugSimulateWebContentProcessTermination()

        XCTAssertFalse(panel.shouldRenderWebView)
    }

    func testResetSidebarContextClearsBrowserPanelsIntoNewTabState() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let contextPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let browser = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                url: URL(string: "https://example.com"),
                focus: false
            )
        )

        browser.restoreSessionNavigationHistory(
            backHistoryURLStrings: ["https://example.com/prev"],
            forwardHistoryURLStrings: ["https://example.com/next"],
            currentURLString: "https://example.com/current"
        )
        browser.startFind()

        workspace.statusEntries["task"] = SidebarStatusEntry(key: "task", value: "Issue #1208")
        workspace.metadataBlocks["notes"] = SidebarMetadataBlock(
            key: "notes",
            markdown: "test",
            priority: 0,
            timestamp: Date()
        )
        workspace.progress = SidebarProgressState(value: 0.5, label: "Loading")
        workspace.updatePanelGitBranch(panelId: contextPanelId, branch: "issue-1208", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: contextPanelId,
            number: 1208,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https://example.com/pull/1208")),
            status: .open
        )
        workspace.logEntries.append(
            SidebarLogEntry(
                message: "Issue #1208",
                level: .info,
                source: "test",
                timestamp: Date()
            )
        )
        workspace.surfaceListeningPorts[contextPanelId] = [3000]
        workspace.recomputeListeningPorts()

        XCTAssertTrue(browser.shouldRenderWebView)
        XCTAssertNotNil(browser.preferredURLStringForOmnibar())
        XCTAssertTrue(browser.canGoBack)
        XCTAssertTrue(browser.canGoForward)
        XCTAssertNotNil(browser.searchState)
        XCTAssertFalse(workspace.statusEntries.isEmpty)
        XCTAssertFalse(workspace.logEntries.isEmpty)
        XCTAssertFalse(workspace.metadataBlocks.isEmpty)
        XCTAssertNotNil(workspace.progress)
        XCTAssertNotNil(workspace.gitBranch)
        XCTAssertNotNil(workspace.pullRequest)
        XCTAssertEqual(workspace.listeningPorts, [3000])

        let priorWebView = browser.webView
        let priorInstanceID = browser.webViewInstanceID
        workspace.resetSidebarContext(reason: "test")

        XCTAssertTrue(workspace.statusEntries.isEmpty)
        XCTAssertTrue(workspace.logEntries.isEmpty)
        XCTAssertTrue(workspace.metadataBlocks.isEmpty)
        XCTAssertNil(workspace.progress)
        XCTAssertNil(workspace.gitBranch)
        XCTAssertTrue(workspace.panelGitBranches.isEmpty)
        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(workspace.panelPullRequests.isEmpty)
        XCTAssertTrue(workspace.surfaceListeningPorts.isEmpty)
        XCTAssertTrue(workspace.listeningPorts.isEmpty)
        XCTAssertFalse(browser.shouldRenderWebView)
        XCTAssertNil(browser.preferredURLStringForOmnibar())
        XCTAssertFalse(browser.canGoBack)
        XCTAssertFalse(browser.canGoForward)
        XCTAssertNil(browser.searchState)
        XCTAssertFalse(browser.webView === priorWebView)
        XCTAssertNotEqual(browser.webViewInstanceID, priorInstanceID)
    }

}


