import CmuxBrowser
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
struct DiffViewerURLSchemeHandlerLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func sidecarMaximumManifestRemainsRestorable() async throws {
        let token = UUID().uuidString.lowercased()
        let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        let fixtureURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let entryURL = fixtureURL.appendingPathComponent("index.html", isDirectory: false)
        let manifestURL = rootURL.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        let leaseURL = rootURL.appendingPathComponent(".session-lease-\(token).lock", isDirectory: false)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        try "<!doctype html><title>restorable</title>"
            .write(to: entryURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: leaseURL)
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        let files: [[String: String]] = (0..<CmuxDiffViewerURLSchemeHandler.maxRegisteredFiles).map { index in
            [
                "request_path": index == 0 ? "/index.html" : "/asset-\(index).html",
                "file_path": entryURL.path,
                "mime_type": "text/html",
            ]
        }
        let manifest: [String: Any] = ["token": token, "files": files]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)

        let handler = CmuxDiffViewerURLSchemeHandler()
        #expect(await handler.registerFromManifest(token: token))
        #expect(handler.diffViewerRestorable(token: token, requestPath: "/index.html"))

        let oversizedFiles = files + [[
            "request_path": "/oversized.html",
            "file_path": entryURL.path,
            "mime_type": "text/html",
        ]]
        let oversizedManifest: [String: Any] = ["token": token, "files": oversizedFiles]
        try JSONSerialization.data(withJSONObject: oversizedManifest)
            .write(to: manifestURL, options: .atomic)
        let freshHandler = CmuxDiffViewerURLSchemeHandler()
        #expect(!(await freshHandler.registerFromManifest(token: token)))
        #expect(!freshHandler.diffViewerRestorable(token: token, requestPath: "/index.html"))
    }

    @Test
    func oversizedAllowlistIsRejectedAtRegistrationBoundary() async {
        let handler = CmuxDiffViewerURLSchemeHandler()
        let files = (0...CmuxDiffViewerURLSchemeHandler.maxRegisteredFiles).map { index in
            CmuxDiffViewerURLSchemeHandler.RegisteredFile(
                requestPath: "/asset-\(index).html",
                fileURL: URL(fileURLWithPath: "/tmp/nonexistent-\(index).html"),
                mimeType: "text/html"
            )
        }

        do {
            try await handler.register(token: UUID().uuidString.lowercased(), files: files)
            Issue.record("Expected an oversized allowlist to be rejected")
        } catch let error as CmuxDiffViewerSessionError {
            #expect(error == .allowlistTooLarge)
        } catch {
            Issue.record("Unexpected registration error: \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulStreamDeliversEveryCallbackOnMainThread() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let schemeTask = DiffViewerRecordingSchemeTask(
            request: URLRequest(url: fixture.requestURL)
        )

        fixture.handler.webView(fixture.webView, start: schemeTask)

        var callbacks: [DiffViewerRecordingSchemeTask.Callback] = []
        for await callback in schemeTask.callbacks {
            callbacks.append(callback)
        }

        #expect(callbacks.map(\.kind) == [.response, .data, .finish])
        #expect(callbacks.allSatisfy { $0.wasOnMainThread })
        let response = try #require(callbacks.first?.response as? HTTPURLResponse)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Security-Policy") == [
            "default-src 'none'",
            "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'",
            "style-src 'unsafe-inline'",
            "img-src 'self' data:",
            "connect-src 'self'",
            "font-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; "))
        #expect(response.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        #expect(response.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy") == "same-origin")
    }

    @Test(.timeLimit(.minutes(1)))
    func streamFailureIsDeliveredOnMainThread() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try FileManager.default.removeItem(at: fixture.fileURL)

        let schemeTask = DiffViewerRecordingSchemeTask(
            request: URLRequest(url: fixture.requestURL)
        )

        fixture.handler.webView(fixture.webView, start: schemeTask)

        var callbacks: [DiffViewerRecordingSchemeTask.Callback] = []
        for await callback in schemeTask.callbacks {
            callbacks.append(callback)
        }

        #expect(callbacks.map(\.kind) == [.response, .failure])
        #expect(callbacks.allSatisfy { $0.wasOnMainThread })
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentCompressedStreamsRemainCorrectAndMainThreadBound() async throws {
        let token = UUID().uuidString.lowercased()
        let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let handler = CmuxDiffViewerURLSchemeHandler()
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var registeredFiles: [CmuxDiffViewerURLSchemeHandler.RegisteredFile] = []
        var requests: [(task: DiffViewerRecordingSchemeTask, expectedBody: Data)] = []

        for index in 0..<8 {
            let requestPath = "/asset-\(index).mjs"
            let fileURL = rootURL.appendingPathComponent("asset-\(index).mjs.deflate")
            let text = String(repeating: "export const asset\(index) = true;\n", count: 4_096)
            try DeflatedAssetTestSupport.writeText(text, to: fileURL)
            registeredFiles.append(.init(
                requestPath: requestPath,
                fileURL: fileURL,
                mimeType: "text/javascript"
            ))
            let requestURL = try #require(URL(
                string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)\(requestPath)"
            ))
            requests.append((
                DiffViewerRecordingSchemeTask(request: URLRequest(url: requestURL)),
                Data(text.utf8)
            ))
        }

        try await handler.register(token: token, files: registeredFiles)
        for request in requests {
            handler.webView(webView, start: request.task)
        }

        for request in requests {
            var callbacks: [DiffViewerRecordingSchemeTask.Callback] = []
            for await callback in request.task.callbacks {
                callbacks.append(callback)
            }
            var body = Data()
            for callback in callbacks {
                if let data = callback.data {
                    body.append(data)
                }
            }

            #expect(callbacks.first?.kind == .response)
            #expect(callbacks.last?.kind == .finish)
            #expect(callbacks.dropFirst().dropLast().allSatisfy { $0.kind == .data })
            #expect(callbacks.allSatisfy { $0.wasOnMainThread })
            #expect(body == request.expectedBody)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func stopNeverWaitsForOffMainCallbackDelivery() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let schemeTask = DiffViewerRecordingSchemeTask(
            request: URLRequest(url: fixture.requestURL),
            simulatesBlockingMainHop: true
        )
        var callbackIterator = schemeTask.callbacks.makeAsyncIterator()
        var blockingHopEntryIterator = schemeTask.blockingHopEntries.makeAsyncIterator()
        var blockingHopExitIterator = schemeTask.blockingHopExits.makeAsyncIterator()

        fixture.handler.webView(fixture.webView, start: schemeTask)
        let firstCallback = try #require(await callbackIterator.next())

        // The pre-fix handler reaches this branch: its stream queue reports that
        // the callback is parked waiting for the main run loop. Waiting for the
        // entry signal before stopping makes the lifecycle ordering causal.
        if !firstCallback.wasOnMainThread {
            _ = try #require(await blockingHopEntryIterator.next())
        }

        fixture.handler.webView(fixture.webView, stop: schemeTask)
        schemeTask.releaseBlockingMainHop()

        if !firstCallback.wasOnMainThread {
            let exit = try #require(await blockingHopExitIterator.next())
            #expect(exit == .releasedByTest)
        }

        #expect(firstCallback.kind == .response)
        #expect(firstCallback.wasOnMainThread)
    }

    @Test(.timeLimit(.minutes(1)))
    func deferredBrowserNavigateRefreshesAStaleAllowlist() async throws {
        let defaults = UserDefaults.standard
        let browserDisabledKey = BrowserAvailabilitySettings.disabledKey
        let previousBrowserDisabled = defaults.object(forKey: browserDisabledKey)
        BrowserAvailabilitySettings.setDisabled(false)

        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            manager.tabs.forEach { $0.teardownAllPanels() }
            if let previousBrowserDisabled {
                defaults.set(previousBrowserDisabled, forKey: browserDisabledKey)
            } else {
                defaults.removeObject(forKey: browserDisabledKey)
            }
            NotificationCenter.default.post(
                name: BrowserAvailabilitySettings.didChangeNotification,
                object: nil
            )
        }

        let workspace = try #require(manager.tabs.first)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let browserPanel = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            focus: true,
            creationPolicy: .restoration
        ))

        let token = UUID().uuidString.lowercased()
        let trustedRoot = CmuxDiffViewerSessionPreparer.defaultTrustedRootURL
        let fixtureRoot = trustedRoot
            .appendingPathComponent("deferred-navigation-\(UUID().uuidString)", isDirectory: true)
        let openingURL = fixtureRoot.appendingPathComponent("opening.html", isDirectory: false)
        let completedURL = fixtureRoot.appendingPathComponent("completed.html", isDirectory: false)
        let manifestURL = trustedRoot
            .appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        let leaseURL = trustedRoot
            .appendingPathComponent(".session-lease-\(token).lock", isDirectory: false)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        try "<!doctype html><title>opening</title>"
            .write(to: openingURL, atomically: true, encoding: .utf8)
        try "<!doctype html><title>completed</title>"
            .write(to: completedURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: leaseURL)
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        let handler = CmuxDiffViewerURLSchemeHandler.shared
        try await handler.register(
            token: token,
            files: [
                .init(
                    requestPath: "/opening.html",
                    fileURL: openingURL,
                    mimeType: "text/html"
                ),
            ]
        )
        let completedViewerURL = try #require(URL(
            string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/completed.html"
        ))
        #expect(handler.registeredFile(for: completedViewerURL) == nil)

        let manifest: [String: Any] = [
            "token": token,
            "files": [
                [
                    "request_path": "/opening.html",
                    "file_path": openingURL.path,
                    "mime_type": "text/html",
                ],
                [
                    "request_path": "/completed.html",
                    "file_path": completedURL.path,
                    "mime_type": "text/html",
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: manifestURL, options: .atomic)

        let request: [String: Any] = [
            "id": "deferred-navigation",
            "method": "browser.navigate",
            "params": [
                "surface_id": browserPanel.id.uuidString,
                "url": completedViewerURL.absoluteString,
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let controller = TerminalController.shared
        let rawResponse = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: controller.handleSocketLine(requestLine))
            }
        }
        let responseData = try #require(rawResponse.data(using: .utf8))
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )

        #expect(response["ok"] as? Bool == true)
        #expect(handler.registeredFile(for: completedViewerURL) != nil)
    }

    private func makeFixture() async throws -> (
        handler: CmuxDiffViewerURLSchemeHandler,
        webView: WKWebView,
        rootURL: URL,
        fileURL: URL,
        requestURL: URL
    ) {
        let token = UUID().uuidString.lowercased()
        let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("index.html", isDirectory: false)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "<!doctype html><title>deadlock regression</title>"
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = CmuxDiffViewerURLSchemeHandler()
        try await handler.register(
            token: token,
            files: [.init(requestPath: "/index.html", fileURL: fileURL, mimeType: "text/html")]
        )
        let requestURL = try #require(URL(
            string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/index.html"
        ))
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        return (handler, webView, rootURL, fileURL, requestURL)
    }
}

/// Models WebKit's synchronous off-main hop to the main run loop without
/// leaving a permanently wedged test process. A callback delivered off-main
/// remains in flight for one second, so a blocking `stop` is deterministic.
private final class DiffViewerRecordingSchemeTask: NSObject, WKURLSchemeTask {
    struct Callback: @unchecked Sendable {
        enum Kind: Sendable, Equatable {
            case response
            case data
            case finish
            case failure
        }

        let kind: Kind
        let wasOnMainThread: Bool
        let data: Data?
        let response: URLResponse?
    }

    enum BlockingHopExit: Sendable, Equatable {
        case releasedByTest
        case safetyTimeout
    }

    let request: URLRequest
    let callbacks: AsyncStream<Callback>
    let blockingHopEntries: AsyncStream<Void>
    let blockingHopExits: AsyncStream<BlockingHopExit>

    private let callbackContinuation: AsyncStream<Callback>.Continuation
    private let blockingHopEntryContinuation: AsyncStream<Void>.Continuation
    private let blockingHopExitContinuation: AsyncStream<BlockingHopExit>.Continuation
    private let simulatesBlockingMainHop: Bool
    private let blockingMainHopRelease = DispatchSemaphore(value: 0)

    init(request: URLRequest, simulatesBlockingMainHop: Bool = false) {
        self.request = request
        self.simulatesBlockingMainHop = simulatesBlockingMainHop

        let callbackStream = AsyncStream<Callback>.makeStream()
        callbacks = callbackStream.stream
        callbackContinuation = callbackStream.continuation

        let blockingHopEntryStream = AsyncStream<Void>.makeStream()
        blockingHopEntries = blockingHopEntryStream.stream
        blockingHopEntryContinuation = blockingHopEntryStream.continuation

        let blockingHopExitStream = AsyncStream<BlockingHopExit>.makeStream()
        blockingHopExits = blockingHopExitStream.stream
        blockingHopExitContinuation = blockingHopExitStream.continuation
    }

    func didReceive(_ response: URLResponse) {
        recordCallback(.response, response: response)
    }

    func didReceive(_ data: Data) {
        recordCallback(.data, data: data)
    }

    func didFinish() {
        recordCallback(.finish)
        callbackContinuation.finish()
    }

    func didFailWithError(_ error: Error) {
        recordCallback(.failure)
        callbackContinuation.finish()
    }

    func releaseBlockingMainHop() {
        blockingMainHopRelease.signal()
    }

    private func recordCallback(
        _ kind: Callback.Kind,
        data: Data? = nil,
        response: URLResponse? = nil
    ) {
        let wasOnMainThread = Thread.isMainThread
        callbackContinuation.yield(Callback(
            kind: kind,
            wasOnMainThread: wasOnMainThread,
            data: data,
            response: response
        ))
        if simulatesBlockingMainHop, !wasOnMainThread {
            blockingHopEntryContinuation.yield(())
            let result = blockingMainHopRelease.wait(timeout: .now() + 1)
            blockingHopExitContinuation.yield(
                result == .success ? .releasedByTest : .safetyTimeout
            )
            blockingHopExitContinuation.finish()
        }
    }
}
