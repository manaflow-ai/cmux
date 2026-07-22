import AppKit
import Bonsplit
@testable import CmuxBrowser
import CryptoKit
import Foundation
import Network
import os
import SwiftUI
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct BrowserWebExtensionsManagerTests {
    private actor CatalogRequestGate {
        private var didStart = false
        private var didCancel = false
        private var isReleased = false
        private var startedContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func markStarted() async {
            didStart = true
            startedContinuation?.resume()
            startedContinuation = nil
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !didStart else { return }
            await withCheckedContinuation { continuation in
                startedContinuation = continuation
            }
        }

        func markCancelled() {
            didCancel = true
        }

        func wasCancelled() -> Bool {
            didCancel
        }

        func release() {
            isReleased = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private final class SuspendedCatalogURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var gate: CatalogRequestGate?
        private var requestTask: Task<Void, Never>?

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.scheme?.lowercased() == "https"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let gate = Self.gate else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.resourceUnavailable)
                )
                return
            }
            requestTask = Task { [weak self] in
                await gate.markStarted()
                guard let self, !Task.isCancelled else { return }
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.cancelled)
                )
            }
        }

        override func stopLoading() {
            requestTask?.cancel()
            requestTask = nil
            if let gate = Self.gate {
                Task { await gate.markCancelled() }
            }
        }
    }

    private final class RuntimeLoadGate {
        private var bufferedOutcome: BrowserWebExtensionLoadOutcome?
        private var continuation: CheckedContinuation<BrowserWebExtensionLoadOutcome, Never>?

        func wait() async -> BrowserWebExtensionLoadOutcome {
            if let bufferedOutcome {
                self.bufferedOutcome = nil
                return bufferedOutcome
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(_ outcome: BrowserWebExtensionLoadOutcome = .ready) {
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: outcome)
            } else {
                bufferedOutcome = outcome
            }
        }
    }

    private final class RuntimeDeadlineGate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async throws {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class NewTabGate {
        private var isResolved = false
        private var bufferedPanel: BrowserPanel?
        private var continuation: CheckedContinuation<BrowserPanel?, Never>?

        func wait() async -> BrowserPanel? {
            if isResolved { return bufferedPanel }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(returning panel: BrowserPanel?) {
            guard !isResolved else { return }
            isResolved = true
            bufferedPanel = panel
            continuation?.resume(returning: panel)
            continuation = nil
        }
    }

    private actor InstallCommitGate {
        private var isEntered = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?

        func pauseAfterCommit() async throws {
            isEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            try await Task.sleep(for: .seconds(3600))
        }

        func waitUntilEntered() async {
            guard !isEntered else { return }
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }
    }

    private actor VerificationSuspensionGate {
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var isEntered = false
        private var isReleased = false

        func suspend() async {
            isEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            guard !isEntered else { return }
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }

        func resume() {
            isReleased = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor PermissionPromptGate {
        private var didEnter = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var decisionContinuation: CheckedContinuation<BrowserWebExtensionPermissionDecision, Never>?
        private var bufferedDecision: BrowserWebExtensionPermissionDecision?

        func present() async -> BrowserWebExtensionPermissionDecision {
            didEnter = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            if let bufferedDecision {
                self.bufferedDecision = nil
                return bufferedDecision
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    decisionContinuation = continuation
                }
            } onCancel: {
                Task { await self.resolve(.deny) }
            }
        }

        func waitUntilEntered() async {
            guard !didEnter else { return }
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }

        func resolve(_ decision: BrowserWebExtensionPermissionDecision) {
            if let decisionContinuation {
                self.decisionContinuation = nil
                decisionContinuation.resume(returning: decision)
            } else {
                bufferedDecision = decision
            }
        }
    }

    private final class ScriptMessageCounter: NSObject, WKScriptMessageHandler {
        private let countStorage = OSAllocatedUnfairLock(initialState: 0)

        var count: Int {
            countStorage.withLock { $0 }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            countStorage.withLock { $0 += 1 }
        }
    }

    private final class WebViewLoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?

        func load(_ html: String, in webView: WKWebView) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func load(_ request: URLRequest, in webView: WKWebView) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.load(request)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(.failure(error))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(.failure(error))
        }

        private func finish(_ result: Result<Void, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private final class ExtensionHTTPFixtureServer {
        enum ServerError: Error {
            case listenerDidNotBecomeReady
            case listenerPortUnavailable
        }

        private let listener: NWListener
        private let queue = DispatchQueue(label: "cmux.web-extension-fixture-http")
        private let lock = NSLock()
        private let routes: [String: (contentType: String, body: String)]
        private var requestCounts: [String: Int] = [:]
        private(set) var port: UInt16 = 0

        init(routes: [String: (contentType: String, body: String)]) throws {
            self.routes = routes
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: .any
            )
            listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 2) == .success else {
                throw ServerError.listenerDidNotBecomeReady
            }
            guard let port = listener.port?.rawValue else {
                throw ServerError.listenerPortUnavailable
            }
            self.port = port
        }

        func url(path: String) -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)")!
        }

        func requestCount(for path: String) -> Int {
            lock.withLock { requestCounts[path, default: 0] }
        }

        func stop() {
            listener.cancel()
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            receiveRequest(on: connection)
        }

        private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
                guard let self else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                var nextBuffer = buffer
                if let data { nextBuffer.append(data) }
                guard let request = String(data: nextBuffer, encoding: .utf8),
                      request.contains("\r\n\r\n") else {
                    self.receiveRequest(on: connection, buffer: nextBuffer)
                    return
                }
                let requestLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
                let rawPath = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
                self.lock.withLock { self.requestCounts[path, default: 0] += 1 }
                self.sendResponse(self.routes[path], on: connection)
            }
        }

        private func sendResponse(
            _ route: (contentType: String, body: String)?,
            on connection: NWConnection
        ) {
            let status = route == nil ? "404 Not Found" : "200 OK"
            let contentType = route?.contentType ?? "text/plain; charset=utf-8"
            let body = route?.body ?? "not found"
            let bodyData = Data(body.utf8)
            let response = Data("""
            HTTP/1.1 \(status)\r
            Content-Type: \(contentType)\r
            Content-Length: \(bodyData.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r
            """.utf8) + bodyData
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private enum BehaviorFixtureError: Error {
        case timedOutWaitingForJavaScript(String)
        case missingExtensionPageConfiguration
        case invalidJavaScriptResult
    }

    private final class RejectingCreateTabDelegate: BonsplitDelegate {
        func splitTabBar(
            _ controller: BonsplitController,
            shouldCreateTab tab: Bonsplit.Tab,
            inPane pane: PaneID
        ) -> Bool {
            false
        }
    }

    private final class RejectingSplitPaneDelegate: BonsplitDelegate {
        func splitTabBar(
            _ controller: BonsplitController,
            shouldSplitPane pane: PaneID,
            orientation: SplitOrientation
        ) -> Bool {
            false
        }
    }

    private static func makeExtensionsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-extensions-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeExtension(
        named name: String,
        in root: URL,
        manifest: [String: Any]
    ) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private static func waitForJavaScriptString(
        _ script: String,
        toEqual expected: String,
        in webView: WKWebView,
        timeout: Duration = .seconds(8)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let value = try? await webView.evaluateJavaScript(script) as? String,
               value == expected {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw BehaviorFixtureError.timedOutWaitingForJavaScript(expected)
    }

    private static func waitUntil(
        _ label: String,
        timeout: Duration = .seconds(8),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw BehaviorFixtureError.timedOutWaitingForJavaScript(label)
    }

    private static func postScriptMessage(
        named name: String,
        body: String,
        in webView: WKWebView
    ) async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.webkit.messageHandlers[name].postMessage(body); return true;",
            arguments: ["name": name, "body": body],
            in: nil,
            contentWorld: .page
        )
    }

    private static func accessibilityIdentifier(of element: Any) -> String? {
        if let view = element as? NSView {
            return view.accessibilityIdentifier()
        }
        if let accessibilityElement = element as? NSAccessibilityElement {
            return accessibilityElement.accessibilityIdentifier()
        }
        return nil
    }

    private static func accessibilityChildren(of element: Any) -> [Any] {
        if let view = element as? NSView {
            return view.accessibilityChildren() ?? []
        }
        if let accessibilityElement = element as? NSAccessibilityElement {
            return accessibilityElement.accessibilityChildren() ?? []
        }
        return []
    }

    private static func accessibilityElement(
        identifier: String,
        in root: NSView
    ) -> Any? {
        var queue: [Any] = [root]
        var visited = Set<ObjectIdentifier>()
        while !queue.isEmpty {
            let element = queue.removeFirst()
            if let object = element as? AnyObject {
                guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            }
            if accessibilityIdentifier(of: element) == identifier {
                return element
            }
            queue.append(contentsOf: accessibilityChildren(of: element))
        }
        return nil
    }

    private static func accessibilityIdentifiers(in root: NSView) -> [String] {
        var queue: [Any] = [root]
        var identifiers: [String] = []
        var visited = Set<ObjectIdentifier>()
        while !queue.isEmpty {
            let element = queue.removeFirst()
            let object = element as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let identifier = accessibilityIdentifier(of: element) {
                identifiers.append(identifier)
            }
            queue.append(contentsOf: accessibilityChildren(of: element))
        }
        return identifiers
    }

    private static func pressAccessibilityElement(_ element: Any) -> Bool {
        if let view = element as? NSView {
            return view.accessibilityPerformPress()
        }
        if let accessibilityElement = element as? NSAccessibilityElement {
            return accessibilityElement.accessibilityPerformPress()
        }
        return false
    }

    @available(macOS 15.4, *)
    private static func loadExtensionPage(
        _ relativePath: String,
        context: WKWebExtensionContext,
        manager: BrowserWebExtensionsManager
    ) async throws -> WKWebView {
        let url = context.baseURL.appendingPathComponent(relativePath)
        guard let pageConfiguration = manager.pageConfiguration(for: url) else {
            throw BehaviorFixtureError.missingExtensionPageConfiguration
        }
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: pageConfiguration.configuration
        )
        let waiter = WebViewLoadWaiter()
        webView.navigationDelegate = waiter
        try await waiter.load(URLRequest(url: url), in: webView)
        return webView
    }

    private static func writeSafariExtensionFixture(
        in root: URL,
        bundleIdentifier: String
    ) throws -> (app: URL, appex: URL, resources: URL, trustMarker: URL) {
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let appex = app.appendingPathComponent(
            "Contents/PlugIns/Fixture.appex",
            isDirectory: true
        )
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "XPC!",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
            ],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: appex.appendingPathComponent("Contents/Info.plist"))
        var manifest = minimalManifest
        manifest["name"] = "Safari lifecycle fixture"
        manifest["action"] = ["default_title": "Fixture"]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: resources.appendingPathComponent("manifest.json"))
        try "// no-op".write(
            to: resources.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let trustMarker = app.appendingPathComponent("Contents/trust-marker")
        try "trusted".write(to: trustMarker, atomically: true, encoding: .utf8)
        return (app, appex, resources, trustMarker)
    }

    @available(macOS 15.4, *)
    private static func assertFailedSafariAppLifecycle(tamper: Bool) async throws {
        let managedRoot = try makeExtensionsRoot()
        let appRoot = try makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: managedRoot)
            try? FileManager.default.removeItem(at: appRoot)
        }
        let bundleIdentifier = "com.example.lifecycle.safari"
        let fixture = try writeSafariExtensionFixture(
            in: appRoot,
            bundleIdentifier: bundleIdentifier
        )
        let identity = BrowserWebExtensionSafariAppIdentity(
            id: "lifecycle-fixture",
            appBundleIdentifier: "com.example.lifecycle",
            extensionBundleIdentifier: bundleIdentifier,
            teamIdentifier: "TESTTEAM"
        )
        let reference = BrowserWebExtensionAppExtensionReference(
            bundleURL: fixture.appex,
            bundleIdentifier: bundleIdentifier,
            installationName: bundleIdentifier
        )
        let record = BrowserWebExtensionManagedRecord(
            id: bundleIdentifier,
            displayName: "Safari lifecycle fixture",
            version: "1.0",
            source: .safariApp(reference),
            isEnabled: true,
            isToolbarPinned: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        try await repository.upsertManagedRecord(record, in: managedRoot)
        let verify: BrowserWebExtensionsManager.SafariAppVerifier = { _ in
            guard (try? String(contentsOf: fixture.trustMarker, encoding: .utf8)) == "trusted" else {
                throw BrowserWebExtensionInstallError.integrityMismatch
            }
            return identity
        }
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            verifySafariAppExtension: verify,
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: fixture.resources)
            }
        )
        await manager.loadExtensions()
        #expect(manager.loadedContexts.count == 1)
        manager.shutdown()

        if tamper {
            try "tampered".write(
                to: fixture.trustMarker,
                atomically: true,
                encoding: .utf8
            )
        } else {
            try FileManager.default.removeItem(at: fixture.app)
        }

        let relaunchedManager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            verifySafariAppExtension: verify,
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: fixture.resources)
            }
        )
        await relaunchedManager.loadExtensions()
        let snapshot = relaunchedManager.presentationSnapshot()
        let failedItem = try #require(snapshot.extensions.first)
        #expect(relaunchedManager.loadedContexts.isEmpty)
        #expect(snapshot.extensions.count == 1)
        #expect(snapshot.failures.isEmpty)
        #expect(failedItem.managementID == bundleIdentifier)
        #expect(!failedItem.isEnabled)
        #expect(!failedItem.hasAction)
        #expect(failedItem.loadFailure != nil)

        if tamper {
            try "trusted".write(
                to: fixture.trustMarker,
                atomically: true,
                encoding: .utf8
            )
            try await relaunchedManager.setExtensionEnabled(
                managementID: bundleIdentifier,
                isEnabled: true
            )
            #expect(relaunchedManager.loadedContexts.count == 1)
            #expect(relaunchedManager.presentationSnapshot().extensions.first?.loadFailure == nil)
        } else {
            try await relaunchedManager.removeExtension(managementID: bundleIdentifier)
            #expect(relaunchedManager.presentationSnapshot().extensions.isEmpty)
            let ledger = try await repository.managementLedger(in: managedRoot)
            #expect(ledger.records.isEmpty)
        }
    }

    private static let minimalManifest: [String: Any] = [
        "manifest_version": 3,
        "name": "cmux test extension",
        "version": "1.0",
        "description": "Test fixture",
        "permissions": ["storage"],
        "host_permissions": ["*://example.com/*"],
        "content_scripts": [
            [
                "matches": ["*://example.com/*"],
                "js": ["content.js"],
            ]
        ],
    ]

    private static func makeIconPNG(color: NSColor = .systemBlue) throws -> Data {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private static func centerColor(in pngData: Data) throws -> NSColor {
        let bitmap = try #require(NSBitmapImageRep(data: pngData))
        let color = try #require(bitmap.colorAt(
            x: bitmap.pixelsWide / 2,
            y: bitmap.pixelsHigh / 2
        ))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private static func recordRawManagedPackageForLoadTesting(
        _ package: URL,
        in root: URL
    ) async throws {
        let repository = BrowserWebExtensionDirectoryRepository()
        let digest = try await repository.digestForManagedPackage(at: package)
        try await repository.upsertManagedRecord(
            BrowserWebExtensionManagedRecord(
                id: package.lastPathComponent,
                displayName: package.lastPathComponent,
                version: "",
                source: .directory(filename: package.lastPathComponent, digest: digest),
                isEnabled: true,
                grantedPermissions: [],
                grantedMatchPatterns: []
            ),
            in: root
        )
    }

    @available(macOS 15.4, *)
    @Test func candidateDiscoveryFindsDirectoriesAndZipsOnly() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        FileManager.default.createFile(atPath: root.appendingPathComponent("archive.zip").path, contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent("notes.txt").path, contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent(".DS_Store").path, contents: Data())

        let names = BrowserWebExtensionsManager.candidateURLs(in: root).map(\.lastPathComponent)
        #expect(names == ["archive.zip", "sample"])
    }

    @Test func productionCatalogPinsOnlyVerifiedPortablePackages() throws {
        let catalog = BrowserWebExtensionCatalog.production
        let entry = try #require(catalog.entry(id: "1password"))

        #expect(catalog.verifiedEntries.map(\.id) == ["1password"])
        #expect(entry.version == "8.12.28.25")
        #expect(
            entry.packageURL.absoluteString
                == "https://addons.mozilla.org/firefox/downloads/file/4899098/1password_x_password_manager-8.12.28.25.xpi"
        )
        #expect(
            entry.packageSHA256
                == "fc369b5ee7958a57c519aa37e7ba540ebe08d58b4bc976fab1ba2e91bc01bc25"
        )
    }

    @Test func extensionRecommendationCopyIsLocalizedInEnglishAndJapanese() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in [
            "browser.extensions.catalog.onePassword.detail",
            "browser.extensions.externalApp.bitwarden.detail",
        ] {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect((localizations["en"] as? [String: Any]) != nil)
            #expect((localizations["ja"] as? [String: Any]) != nil)
        }
    }

    @Test func managerHidesEmptyCatalogSection() {
        #expect(!BrowserExtensionsManagerPage.shouldShowCatalog(entryCount: 0))
        #expect(BrowserExtensionsManagerPage.shouldShowCatalog(entryCount: 1))
    }

    @Test func toolbarSubscriptionSurvivesInitialPhaseAndProcessesLaterInvalidations() async throws {
        let profileID = UUID()
        let updateChannel = AsyncStream<BrowserWebExtensionUpdate>.makeStream()
        var loadCount = 0
        let toolbar = BrowserExtensionsToolbarButton(
            isPresented: .constant(false),
            panelID: UUID(),
            profileID: profileID,
            iconPointSize: 16,
            hitSize: 24,
            loadSnapshot: {
                loadCount += 1
                return BrowserWebExtensionsPresentationSnapshot(
                    state: .ready,
                    extensions: [],
                    failures: []
                )
            },
            updates: { updateChannel.stream },
            openManager: { true },
            setToolbarPinned: { _, _ in true },
            performAction: { _, _ in true }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: toolbar)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            updateChannel.continuation.finish()
            window.orderOut(nil)
            window.contentView = nil
        }

        try await Self.waitUntil("toolbar initial snapshot") { loadCount == 1 }

        updateChannel.continuation.yield(.phaseChanged(.ready))
        try await Self.waitUntil("toolbar phase refresh") { loadCount == 2 }

        updateChannel.continuation.yield(.snapshotInvalidated(profileID))
        try await Self.waitUntil("toolbar first live refresh") { loadCount == 3 }

        updateChannel.continuation.yield(.snapshotInvalidated(profileID))
        try await Self.waitUntil("toolbar second live refresh") { loadCount == 4 }
    }

    @Test func pinnedToolbarActionsRespectMountedWidthBudget() async throws {
        func visiblePinnedIdentifiers(width: CGFloat, pinCount: Int) async throws -> [String] {
            let items = (0..<pinCount).map { index in
                BrowserWebExtensionPresentationItem(
                    id: "pin-\(index)",
                    managementID: "disk:pin-\(index)",
                    name: "Pinned \(index)",
                    hasAction: true,
                    isToolbarPinned: true,
                    isActionEnabled: true,
                    isAwaitingPopup: false,
                    badgeText: "",
                    iconData: nil
                )
            }
            var loadCount = 0
            let toolbar = BrowserExtensionsToolbarButton(
                isPresented: .constant(false),
                panelID: UUID(),
                profileID: UUID(),
                iconPointSize: 16,
                hitSize: 24,
                loadSnapshot: {
                    loadCount += 1
                    return BrowserWebExtensionsPresentationSnapshot(
                        state: .ready,
                        extensions: items,
                        failures: []
                    )
                },
                updates: {
                    AsyncStream { continuation in continuation.finish() }
                },
                openManager: { true },
                setToolbarPinned: { _, _ in true },
                performAction: { _, _ in true }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let hostingView = NSHostingView(
                rootView: toolbar.frame(width: width, height: 24, alignment: .trailing)
            )
            hostingView.frame = window.contentLayoutRect
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            try await Self.waitUntil("mounted toolbar snapshot") { loadCount == 1 }
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            for _ in 0..<3 { await Task.yield() }
            return Self.accessibilityIdentifiers(in: hostingView)
                .filter { $0.hasPrefix("BrowserExtensionToolbarAction-") }
                .sorted()
        }

        #expect(try await visiblePinnedIdentifiers(width: 24, pinCount: 0) == [])
        #expect(try await visiblePinnedIdentifiers(width: 24, pinCount: 4) == [])
        #expect(try await visiblePinnedIdentifiers(width: 48, pinCount: 4) == [
            "BrowserExtensionToolbarAction-pin-0"
        ])
        #expect(try await visiblePinnedIdentifiers(width: 120, pinCount: 4).count == 4)
        #expect(try await visiblePinnedIdentifiers(width: 120, pinCount: 12).count == 4)
    }

    @Test func managerPageDisappearanceCancelsSuspendedCatalogPreparation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let requestGate = CatalogRequestGate()
        SuspendedCatalogURLProtocol.gate = requestGate
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SuspendedCatalogURLProtocol.self]
        let packageRepository = BrowserWebExtensionCatalogPackageRepository(
            packageSession: BrowserWebExtensionPackageSession(
                configuration: sessionConfiguration
            )
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            catalogPackageRepository: packageRepository
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(
            manager,
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID
        )
        let panel = BrowserPanel(workspaceId: UUID(), browserServices: services)
        let appearance = PanelAppearance(
            backgroundColor: .windowBackgroundColor,
            foregroundColor: .labelColor,
            dividerColor: .separator,
            unfocusedOverlayNSColor: .clear,
            unfocusedOverlayOpacity: 0,
            usesClearContentBackground: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: BrowserExtensionsManagerPage(
                panel: panel,
                appearance: appearance
            )
        )
        hostingView.frame = window.contentLayoutRect
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            Task { await requestGate.release() }
            SuspendedCatalogURLProtocol.gate = nil
            window.orderOut(nil)
            window.contentView = nil
            panel.close()
            manager.shutdown()
        }

        var getButton: Any?
        let buttonDeadline = Date().addingTimeInterval(3)
        repeat {
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            getButton = Self.accessibilityElement(
                identifier: "BrowserExtensionsCatalogGet-1password",
                in: hostingView
            )
            if getButton != nil { break }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            await Task.yield()
        } while Date() < buttonDeadline
        #expect(Self.pressAccessibilityElement(try #require(getButton)))
        await requestGate.waitUntilStarted()

        window.contentView = nil
        for _ in 0..<100 where !(await requestGate.wasCancelled()) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await requestGate.wasCancelled())
        await requestGate.release()
    }

    @available(macOS 15.4, *)
    @Test func installedRecommendationsUseManagementIdentityInsteadOfContextShape() {
        let managementID = "com.example.safari-extension"
        let item = BrowserWebExtensionPresentationItem(
            id: BrowserWebExtensionsManager.contextIdentifier(for: managementID),
            managementID: managementID,
            name: "Fixture",
            hasAction: true,
            isToolbarPinned: false,
            isActionEnabled: true,
            isAwaitingPopup: false,
            badgeText: "",
            iconData: nil
        )
        let snapshot = BrowserWebExtensionsPresentationSnapshot(
            state: .ready,
            extensions: [item],
            failures: []
        )

        #expect(BrowserExtensionsManagerPage.isInstalled(
            managementID: managementID,
            in: snapshot
        ))
        #expect(!BrowserExtensionsManagerPage.isInstalled(
            managementID: "cmux-browser-extension-com.example.safari-extension",
            in: snapshot
        ))
    }

    @available(macOS 15.4, *)
    @Test func contextIdentifiersAreDeterministicAndCollisionResistant() {
        let spaced = BrowserWebExtensionsManager.contextIdentifier(for: "a b")
        let dashed = BrowserWebExtensionsManager.contextIdentifier(for: "a-b")

        #expect(spaced != dashed)
        #expect(spaced == BrowserWebExtensionsManager.contextIdentifier(for: "a b"))
        #expect(spaced.hasPrefix(BrowserWebExtensionsManager.managedContextIdentifierPrefix))
    }

    @available(macOS 15.4, *)
    @Test func collidingLegacyLogicalIDsRemainDistinctAcrossRelaunch() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a b", "a-b"] {
            let extensionDirectory = try Self.writeExtension(
                named: name,
                in: root,
                manifest: Self.minimalManifest.merging(["name": name]) { _, new in new }
            )
            try "// no-op".write(
                to: extensionDirectory.appendingPathComponent("content.js"),
                atomically: true,
                encoding: .utf8
            )
        }
        let expected = Set(["a b", "a-b"].map {
            BrowserWebExtensionsManager.contextIdentifier(for: $0)
        })
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        for name in ["a b", "a-b"] {
            try await manager.approveInstalledCandidate(
                root.appendingPathComponent(name, isDirectory: true)
            )
        }
        await manager.loadExtensions()

        #expect(Set(manager.loadedContexts.map(\.uniqueIdentifier)) == expected)
        manager.shutdown()

        let relaunchedManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        await relaunchedManager.loadExtensions()
        #expect(Set(relaunchedManager.loadedContexts.map(\.uniqueIdentifier)) == expected)
    }

    @Test func toolbarExtensionIconStaysInsideArtworkBoxAtEveryChromeScale() {
        let minimum = BrowserChromeMetrics(tabBarFontSize: 0.001)
        let standard = BrowserChromeMetrics(tabBarFontSize: BrowserChromeMetrics.referenceFontSize)
        let maximum = BrowserChromeMetrics(tabBarFontSize: 10_000)

        #expect(BrowserExtensionIconMetrics.toolbarContentSize(
            iconPointSize: minimum.navigationIconFontSize
        ) == 8)
        #expect(BrowserExtensionIconMetrics.toolbarContentSize(
            iconPointSize: standard.navigationIconFontSize
        ) == 14)
        #expect(BrowserExtensionIconMetrics.toolbarContentSize(
            iconPointSize: maximum.navigationIconFontSize
        ) == BrowserExtensionIconMetrics.maximumToolbarArtworkSize)
    }

    @available(macOS 15.4, *)
    @Test func extensionActionPopoversPreferBelowTheToolbar() {
        #expect(BrowserExtensionPopoverMetrics.managerArrowEdge == .top)
        #expect(BrowserWebExtensionsManager.actionPopupPreferredEdge == .minY)
    }

    @available(macOS 15.4, *)
    @Test func popupPlacementChoosesVisibleSideBeforePresentation() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let toolbarAnchor = NSRect(x: 480, y: 730, width: 40, height: 24)
        let bottomAnchor = NSRect(x: 480, y: 20, width: 40, height: 24)

        let toolbarPlan = BrowserWebExtensionPopupPlacementLock.plan(
            contentHeight: 300,
            anchorScreenRect: toolbarAnchor,
            visibleFrame: visibleFrame
        )
        let bottomPlan = BrowserWebExtensionPopupPlacementLock.plan(
            contentHeight: 300,
            anchorScreenRect: bottomAnchor,
            visibleFrame: visibleFrame
        )

        #expect(toolbarPlan.side == .below)
        #expect(toolbarPlan.preferredEdge == .minY)
        #expect(bottomPlan.side == .above)
        #expect(bottomPlan.preferredEdge == .maxY)
        let belowOrigin = BrowserWebExtensionPopupPlacementLock.lockedOrigin(
            side: toolbarPlan.side,
            popupSize: NSSize(width: 300, height: 324),
            anchorScreenRect: toolbarAnchor,
            visibleFrame: visibleFrame
        )
        let aboveOrigin = BrowserWebExtensionPopupPlacementLock.lockedOrigin(
            side: bottomPlan.side,
            popupSize: NSSize(width: 300, height: 324),
            anchorScreenRect: bottomAnchor,
            visibleFrame: visibleFrame
        )
        #expect(belowOrigin.y + 324 == toolbarAnchor.minY)
        #expect(aboveOrigin.y == bottomAnchor.maxY)
    }

    @available(macOS 15.4, *)
    @Test func popupPlacementKeepsItsChosenSideAcrossContentResizes() async throws {
        let visibleFrame = try #require(NSScreen.main?.visibleFrame)
        let window = NSWindow(
            contentRect: NSRect(
                x: visibleFrame.midX - 180,
                y: visibleFrame.maxY - 300,
                width: 360,
                height: 240
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = NSButton(frame: NSRect(x: 160, y: 190, width: 40, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.close() }
        let contentController = NSViewController()
        contentController.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        let popover = NSPopover()
        popover.contentViewController = contentController
        popover.contentSize = NSSize(width: 280, height: 100)
        popover.animates = false
        let plan = try #require(BrowserWebExtensionPopupPlacementLock.plan(
            popover: popover,
            anchorView: anchor,
            anchorRect: anchor.bounds
        ))
        #expect(plan.side == .below)
        popover.show(
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: plan.preferredEdge
        )
        let placementLock = try #require(BrowserWebExtensionPopupPlacementLock(
            popover: popover,
            anchorView: anchor,
            anchorRect: anchor.bounds,
            side: plan.side
        ))
        defer {
            placementLock.stop()
            popover.performClose(nil)
        }
        let anchorScreenRect = try #require(anchor.window).convertToScreen(
            anchor.convert(anchor.bounds, to: nil)
        )

        for height in [180, 260, 120] {
            popover.contentSize = NSSize(width: 280, height: height)
            await Task.yield()
            let frame = try #require(popover.contentViewController?.view.window?.frame)
            #expect(frame.maxY <= anchorScreenRect.minY + 1)
            #expect(frame.minY >= visibleFrame.minY - 1)
        }
        #expect(placementLock.stabilizationCount >= 2)
        #expect(placementLock.firstStabilizedFrame != nil)
        #expect(placementLock.lastStabilizedFrame != nil)
    }

    @Test func iconEncodingUsesStableBoundedAspectPreservingPixels() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func makeImage(width: Int, height: Int, components: [CGFloat]) throws -> NSImage {
            let context = try #require(CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let color = try #require(CGColor(colorSpace: colorSpace, components: components))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            return NSImage(cgImage: image, size: NSSize(width: width, height: height))
        }
        let source = try makeImage(width: 64, height: 32, components: [0, 0, 1, 1])
        let first = try #require(BrowserWebExtensionPresentationIconEncoder.rasterize(
            source,
            size: CGSize(width: 32, height: 32)
        ))
        let firstPNG = try #require(
            BrowserWebExtensionPresentationIconEncoder.pngData(for: first.image)
        )
        let copy = try #require(NSImage(data: firstPNG))
        let second = try #require(BrowserWebExtensionPresentationIconEncoder.rasterize(
            copy,
            size: CGSize(width: 32, height: 32)
        ))
        let changedImage = try makeImage(width: 64, height: 32, components: [1, 0, 0, 1])
        let changed = try #require(BrowserWebExtensionPresentationIconEncoder.rasterize(
            changedImage,
            size: CGSize(width: 32, height: 32)
        ))

        #expect(first.image.width == 32)
        #expect(first.image.height == 32)
        #expect(first.signature == second.signature)
        #expect(first.signature != changed.signature)
        let providerData = try #require(first.image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(providerData))
        #expect(first.image.bitsPerPixel == 32)
        #expect(first.image.alphaInfo == .premultipliedLast)
        func alpha(x: Int, y: Int) -> UInt8 {
            bytes[y * first.image.bytesPerRow + x * 4 + 3]
        }
        #expect(alpha(x: 16, y: 16) > 230)
        #expect(alpha(x: 16, y: 1) < 25)
    }

    @Test func decodedExtensionIconCacheReusesContentIdentity() throws {
        let data = try Self.makeIconPNG(color: .systemBlue)
        BrowserExtensionDecodedImageCache.removeAllForTesting()

        let first = try #require(BrowserExtensionDecodedImageCache.image(for: data))
        let second = try #require(BrowserExtensionDecodedImageCache.image(for: Data(data)))

        #expect(first === second)
        #expect(BrowserExtensionDecodedImageCache.decodeCountForTesting == 1)
    }

    @Test func packageVerifierAcceptsPinnedDigestAndRejectsChangedBytes() throws {
        let data = Data("cmux".utf8)
        let digest = "548d4fabc56e7b556bbd7d01c3bcb6288fc8de3078dcb38fc3698fb3c26508c9"
        let verifier = BrowserWebExtensionPackageVerifier()

        try verifier.verify(data, expectedSHA256: digest)
        #expect(throws: BrowserWebExtensionCatalogInstallError.integrityMismatch) {
            try verifier.verify(data + Data([0]), expectedSHA256: digest)
        }
    }

    @Test func declaredOversizedResponseCancelsBeforeBuffering() throws {
        let url = try #require(URL(string: "https://extensions.example/package.zip"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "9"]
        ))
        let cancellationCount = OSAllocatedUnfairLock(initialState: 0)

        #expect(throws: BrowserWebExtensionCatalogInstallError.packageTooLarge) {
            try BrowserWebExtensionPackageSession.validateExpectedContentLength(
                response,
                maximumByteCount: 8,
                cancel: { cancellationCount.withLock { $0 += 1 } }
            )
        }
        #expect(cancellationCount.withLock { $0 } == 1)
    }

    @Test func declaredResponseAtLimitDoesNotCancel() throws {
        let url = try #require(URL(string: "https://extensions.example/package.zip"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "8"]
        ))
        let cancellationCount = OSAllocatedUnfairLock(initialState: 0)

        try BrowserWebExtensionPackageSession.validateExpectedContentLength(
            response,
            maximumByteCount: 8,
            cancel: { cancellationCount.withLock { $0 += 1 } }
        )
        #expect(cancellationCount.withLock { $0 } == 0)
    }

    @Test func catalogPackageCollectorRejectsFirstBytePastLimitAndCancels() async throws {
        let state = CountingByteSequenceState()
        let bytes = CountingByteSequence(bytes: Array(Data("ninebytes".utf8)), state: state)

        await #expect(throws: BrowserWebExtensionCatalogInstallError.packageTooLarge) {
            _ = try await BrowserWebExtensionPackageSession.collect(
                bytes,
                maximumByteCount: 8,
                cancel: { state.recordCancellation() }
            )
        }

        #expect(state.snapshot == (nextCount: 9, cancellationCount: 1))
    }

    @Test func catalogPackageCollectorAcceptsResponseExactlyAtLimit() async throws {
        let state = CountingByteSequenceState()
        let bytes = CountingByteSequence(bytes: Array(Data("8-bytes!".utf8)), state: state)

        let data = try await BrowserWebExtensionPackageSession.collect(
            bytes,
            maximumByteCount: 8,
            cancel: { state.recordCancellation() }
        )

        #expect(data == Data("8-bytes!".utf8))
        #expect(state.snapshot == (nextCount: 9, cancellationCount: 0))
    }

    @Test func catalogPackageRedirectsRemainHTTPS() throws {
        let source = try #require(URL(string: "https://extensions.example/package.zip"))
        let insecureDestination = try #require(URL(string: "http://cdn.example/package.zip"))
        let secureDestination = try #require(URL(string: "https://cdn.example/package.zip"))
        let response = try #require(HTTPURLResponse(
            url: source,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        ))
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: source)
        let delegate = BrowserWebExtensionHTTPSRedirectDelegate()

        var acceptedRequest: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: insecureDestination)
        ) { acceptedRequest = $0 }
        #expect(acceptedRequest == nil)

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: secureDestination)
        ) { acceptedRequest = $0 }
        #expect(acceptedRequest?.url == secureDestination)
    }

    @available(macOS 15.4, *)
    @Test func unapprovedDirectoryEntryDoesNotLoad() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "unapproved",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        await manager.loadExtensions()

        #expect(manager.loadedContexts.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func freshProfileDoesNotInstallExtensionsByDefault() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        await manager.loadExtensions()

        #expect(manager.loadedContexts.isEmpty)
        #expect(manager.loadErrors.isEmpty)
        #expect(BrowserWebExtensionsManager.candidateURLs(in: root).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func loadsUnpackedExtensionAndGrantsRequestedPermissions() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()

        #expect(manager.loadErrors.isEmpty)
        #expect(manager.loadedContexts.count == 1)
        let context = try #require(manager.loadedContexts.first)
        #expect(context.uniqueIdentifier == BrowserWebExtensionsManager.contextIdentifier(for: "sample"))
        #expect(context.unsupportedAPIs.contains("browser.runtime.sendNativeMessage"))
        #expect(context.unsupportedAPIs.contains("browser.runtime.connectNative"))
        #expect(context.currentPermissions.contains(.storage))
        #expect(!context.grantedPermissionMatchPatterns.isEmpty)
        #expect(manager.controller.extensionContexts.contains(context))
    }

    @available(macOS 15.4, *)
    @Test func extensionPageConfigurationIsScopedToItsOrigin() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "page-configuration",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let extensionPage = context.baseURL.appendingPathComponent("options.html")

        #expect(manager.pageConfiguration(for: extensionPage) != nil)
        #expect(manager.pageConfiguration(for: URL(string: "https://example.com")!) == nil)
    }

    @available(macOS 15.4, *)
    @Test func workspaceResetRebindsNormalPageThenReentersSameExtensionOrigin() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "workspace-reset-extension-origin",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<title>Extension reset fixture</title>".write(
            to: directory.appendingPathComponent("options.html"),
            atomically: true,
            encoding: .utf8
        )
        let services = BrowserServices(extensionDirectory: root)
        let manager = try #require(services.webExtensionsManager)
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let extensionPage = context.baseURL.appendingPathComponent("options.html")
        let extensionConfiguration = try #require(
            manager.pageConfiguration(for: extensionPage)?.configuration
        )
        let panel = BrowserPanel(
            workspaceId: UUID(),
            browserServices: services
        )
        defer {
            panel.close()
            manager.shutdown()
        }

        panel.navigate(to: extensionPage)
        try await Self.waitForJavaScriptString(
            "document.title",
            toEqual: "Extension reset fixture",
            in: panel.webView
        )
        #expect(
            panel.webView.configuration.userContentController
                === extensionConfiguration.userContentController
        )
        #expect(!panel.hasNormalPageBindingsForTesting)

        panel.resetForWorkspaceContextChange(reason: "test-extension-origin")
        let normalWebView = panel.webView

        #expect(panel.hasNormalPageBindingsForTesting)
        #expect(
            normalWebView.configuration.userContentController
                !== extensionConfiguration.userContentController
        )

        panel.navigate(to: extensionPage)

        #expect(panel.webView !== normalWebView)
        #expect(
            panel.webView.configuration.userContentController
                === extensionConfiguration.userContentController
        )
        #expect(panel.webView.configuration.webExtensionController === manager.controller)
        try await Self.waitForJavaScriptString(
            "document.title",
            toEqual: "Extension reset fixture",
            in: panel.webView
        )
    }

    @Test func baseWebViewConfigurationPreservesItsWebsiteDataStore() {
        let extensionDataStore = WKWebsiteDataStore.nonPersistent()
        let profileDataStore = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = extensionDataStore
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "window.extensionOwned = true",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = BrowserPanel.makeWebView(
            profileID: UUID(),
            websiteDataStore: profileDataStore,
            baseConfiguration: configuration
        )

        #expect(webView.configuration.websiteDataStore === extensionDataStore)
        #expect(webView.configuration.userContentController.userScripts.contains {
            $0.source == "window.extensionOwned = true"
        })
    }

    @available(macOS 15.4, *)
    @Test func approvalLedgerRemainsReadableAcrossAppRestarts() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "restart-readable",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        try await manager.approveInstalledCandidate(directory)

        let ledger = root.appendingPathComponent(".cmux-extension-management.json")
        let values = try ledger.resourceValues(forKeys: [.fileProtectionKey])
        #expect(values.fileProtection != .complete)
        #expect(try Data(contentsOf: ledger).isEmpty == false)
    }

    @available(macOS 15.4, *)
    @Test func standardLimitsAcceptLargeUnpackedExtension() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = root.appendingPathComponent("large-extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        let payload = extensionDirectory.appendingPathComponent("background.js")
        try Data().write(to: payload)
        let handle = try FileHandle(forWritingTo: payload)
        try handle.truncate(atOffset: 80 * 1024 * 1024)
        try handle.close()
        let repository = BrowserWebExtensionDirectoryRepository()

        try await repository.validatePackageSize(at: extensionDirectory)
    }

    @available(macOS 15.4, *)
    @Test func oversizedArchiveIsRejectedBeforeApprovalHashing() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("oversized.zip")
        try Data().write(to: archive)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(
            atOffset: UInt64(256 * 1024 * 1024 + 1)
        )
        try handle.close()
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            try await manager.approveInstalledCandidate(archive)
        }
    }

    @available(macOS 15.4, *)
    @Test func unpackedInstallRejectsCumulativeBytesBeforeCreatingDestination() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = sourceRoot.appendingPathComponent("oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 6).write(to: source.appendingPathComponent("first.js"))
        try Data(repeating: 0x42, count: 6).write(to: source.appendingPathComponent("second.js"))
        let repository = BrowserWebExtensionDirectoryRepository(packageLimits: .init(
            maximumByteCount: 10,
            maximumFileCount: 10
        ))

        do {
            _ = try await repository.installCandidate(from: source, into: managedRoot)
            Issue.record("Expected cumulative unpacked bytes to reject installation")
        } catch let error as BrowserWebExtensionInstallError {
            guard case .packageTooLarge = error else {
                Issue.record("Expected packageTooLarge, got \(error)")
                return
            }
        }

        #expect(!FileManager.default.fileExists(
            atPath: managedRoot.appendingPathComponent("oversized").path
        ))
        #expect(try FileManager.default.contentsOfDirectory(atPath: managedRoot.path).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func unpackedInstallCountsDirectoriesTowardEntryLimit() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = sourceRoot.appendingPathComponent("entry-heavy", isDirectory: true)
        for name in ["first", "second", "third"] {
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let repository = BrowserWebExtensionDirectoryRepository(packageLimits: .init(
            maximumByteCount: 10,
            maximumFileCount: 2
        ))

        do {
            _ = try await repository.installCandidate(from: source, into: managedRoot)
            Issue.record("Expected unpacked entry count to reject installation")
        } catch let error as BrowserWebExtensionInstallError {
            guard case .packageContainsTooManyFiles = error else {
                Issue.record("Expected packageContainsTooManyFiles, got \(error)")
                return
            }
        }

        #expect(!FileManager.default.fileExists(
            atPath: managedRoot.appendingPathComponent("entry-heavy").path
        ))
        #expect(try FileManager.default.contentsOfDirectory(atPath: managedRoot.path).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func unpackedInstallAcceptsExactCumulativeLimits() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = sourceRoot.appendingPathComponent("exact-limit", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 6).write(to: source.appendingPathComponent("first.js"))
        try Data(repeating: 0x42, count: 6).write(to: source.appendingPathComponent("second.js"))
        let repository = BrowserWebExtensionDirectoryRepository(packageLimits: .init(
            maximumByteCount: 12,
            maximumFileCount: 2
        ))

        let installed = try await repository.installCandidate(from: source, into: managedRoot)

        #expect(try Data(contentsOf: installed.appendingPathComponent("first.js")).count == 6)
        #expect(try Data(contentsOf: installed.appendingPathComponent("second.js")).count == 6)
    }

    @available(macOS 15.4, *)
    @Test func unpackedInstallRevalidatesSymlinksAfterPreflight() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = sourceRoot.appendingPathComponent("replaced", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let script = source.appendingPathComponent("content.js")
        try Data("safe".utf8).write(to: script)
        let repository = BrowserWebExtensionDirectoryRepository()
        try await repository.validatePackageSize(at: source)
        try FileManager.default.removeItem(at: script)
        try FileManager.default.createSymbolicLink(
            at: script,
            withDestinationURL: sourceRoot.appendingPathComponent("outside.js")
        )

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            _ = try await repository.installCandidate(from: source, into: managedRoot)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: managedRoot.path).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func installsValidExtensionIntoManagedDirectoryAndLoadsItImmediately() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(named: "sample", in: sourceRoot, manifest: Self.minimalManifest)
        try "// no-op".write(to: source.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        let manager = BrowserWebExtensionsManager(directory: managedRoot, controllerConfiguration: .nonPersistent())

        let receipt = try await manager.installExtension(from: source)

        #expect(receipt.name == "cmux test extension")
        let ledger = try await BrowserWebExtensionDirectoryRepository()
            .managementLedger(in: managedRoot)
        let record = try #require(ledger.records["sample"])
        guard case .directory(let filename, _) = record.source else {
            Issue.record("Expected an immutable managed directory")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: managedRoot.appendingPathComponent(filename)
                .appendingPathComponent("manifest.json").path
        ))
        #expect(manager.loadedContexts.count == 1)
        #expect(manager.presentationSnapshot().extensions.map(\.name) == ["cmux test extension"])
    }

    @available(macOS 15.4, *)
    @Test func arbitraryDiskInstallsWithSameBasenameRemainIsolated() async throws {
        let firstSourceRoot = try Self.makeExtensionsRoot()
        let secondSourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: firstSourceRoot)
            try? FileManager.default.removeItem(at: secondSourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        var firstManifest = Self.minimalManifest
        firstManifest["name"] = "First basename fixture"
        firstManifest["action"] = ["default_title": "First action"]
        let firstSource = try Self.writeExtension(
            named: "same-basename",
            in: firstSourceRoot,
            manifest: firstManifest
        )
        try "// first".write(
            to: firstSource.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        var secondManifest = Self.minimalManifest
        secondManifest["name"] = "Second basename fixture"
        secondManifest["version"] = "2.0"
        secondManifest["action"] = ["default_title": "Second action"]
        let secondSource = try Self.writeExtension(
            named: "same-basename",
            in: secondSourceRoot,
            manifest: secondManifest
        )
        try "// second".write(
            to: secondSource.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository
        )

        _ = try await manager.installExtension(from: firstSource)
        let firstContext = try #require(manager.loadedContexts.first)
        try await manager.setToolbarActionPinned(
            true,
            uniqueIdentifier: firstContext.uniqueIdentifier
        )
        let secondPreview = try await manager.prepareInstall(from: secondSource)
        #expect(!secondPreview.isUpdate)
        _ = try await manager.confirmPreparedInstall(id: secondPreview.id)

        let ledger = try await repository.managementLedger(in: managedRoot)
        #expect(ledger.records.count == 2)
        #expect(ledger.records.keys.allSatisfy { managementID in
            guard managementID.hasPrefix("disk:") else { return false }
            return UUID(uuidString: String(managementID.dropFirst("disk:".count))) != nil
        })
        #expect(ledger.records.values.filter(\.isToolbarPinned).count == 1)
        #expect(manager.loadedContexts.count == 2)
        #expect(Set(manager.loadedContexts.map(\.uniqueIdentifier)).count == 2)
    }

    @available(macOS 15.4, *)
    @Test func disabledDiskUpdateRemainsDisabledAndDoesNotCreateContext() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(
            named: "disabled-update",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository
        )
        _ = try await manager.installExtension(from: source)
        let managementID = try #require(
            try await repository.managementLedger(in: managedRoot).records.keys.first
        )
        try await manager.setExtensionEnabled(managementID: managementID, isEnabled: false)

        let updatePreview = try await manager.prepareInstall(from: source)
        #expect(updatePreview.isUpdate)
        _ = try await manager.confirmPreparedInstall(id: updatePreview.id)

        let updatedRecord = try #require(
            try await repository.managementLedger(in: managedRoot).records[managementID]
        )
        #expect(!updatedRecord.isEnabled)
        #expect(manager.loadedContexts.isEmpty)
        #expect(manager.controller.extensionContexts.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func failedSafariUpdateDoesNotLoadDisabledRollbackRecord() async throws {
        let appRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: appRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let bundleIdentifier = "com.example.disabled-rollback.safari"
        let fixture = try Self.writeSafariExtensionFixture(
            in: appRoot,
            bundleIdentifier: bundleIdentifier
        )
        let identity = BrowserWebExtensionSafariAppIdentity(
            id: "disabled-rollback-fixture",
            appBundleIdentifier: "com.example.disabled-rollback",
            extensionBundleIdentifier: bundleIdentifier,
            teamIdentifier: "TESTTEAM"
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            verifySafariAppExtension: { _ in identity },
            appExtensionLoader: { _ in
                let count = loadCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count == 4 {
                    throw BrowserWebExtensionInstallError.integrityMismatch
                }
                return try await WKWebExtension(resourceBaseURL: fixture.resources)
            }
        )
        _ = try await manager.installExtension(from: fixture.app)
        let managementID = try #require(
            try await repository.managementLedger(in: managedRoot).records.keys.first
        )
        try await manager.setExtensionEnabled(managementID: managementID, isEnabled: false)
        let updatePreview = try await manager.prepareInstall(from: fixture.app)
        #expect(updatePreview.isUpdate)

        await #expect(throws: BrowserWebExtensionInstallError.integrityMismatch) {
            _ = try await manager.confirmPreparedInstall(id: updatePreview.id)
        }

        let restoredRecord = try #require(
            try await repository.managementLedger(in: managedRoot).records[managementID]
        )
        #expect(!restoredRecord.isEnabled)
        #expect(manager.loadedContexts.isEmpty)
        #expect(manager.controller.extensionContexts.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func sourceMutationAfterReviewFailsBeforeLedgerCommit() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(
            named: "reviewed-source",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        let script = source.appendingPathComponent("content.js")
        try "// reviewed".write(to: script, atomically: true, encoding: .utf8)
        let repository = BrowserWebExtensionDirectoryRepository()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository
        )
        let preview = try await manager.prepareInstall(from: source)
        try "// replaced after review".write(
            to: script,
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            _ = try await manager.confirmPreparedInstall(id: preview.id)
        }
        let ledger = try await repository.managementLedger(in: managedRoot)
        #expect(ledger.records.isEmpty)
        #expect(manager.loadedContexts.isEmpty)
        #expect(manager.presentationSnapshot().extensions.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func cancellationAfterLedgerCommitReturnsCommittedInstall() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(
            named: "commit-cancellation",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        let gate = InstallCommitGate()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            postManagementCommitHook: {
                try await gate.pauseAfterCommit()
            }
        )
        let preview = try await manager.prepareInstall(from: source)
        let installTask = Task { @MainActor in
            try await manager.confirmPreparedInstall(id: preview.id)
        }
        await gate.waitUntilEntered()
        installTask.cancel()

        let receipt = try await installTask.value
        #expect(receipt.name == "cmux test extension")
        let ledger = try await repository.managementLedger(in: managedRoot)
        #expect(ledger.records["commit-cancellation"] != nil)
        #expect(manager.loadedContexts.count == 1)
        let item = try #require(manager.presentationSnapshot().extensions.first)
        #expect(item.managementID == "commit-cancellation")
        #expect(item.isEnabled)
    }

    @available(macOS 15.4, *)
    @Test func installsSafariAppExtensionAsBundleBackedReference() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let app = sourceRoot.appendingPathComponent("Password Manager.app", isDirectory: true)
        let appex = app.appendingPathComponent(
            "Contents/PlugIns/Password Manager Safari.appex",
            isDirectory: true
        )
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.password-manager.safari",
            "CFBundleShortVersionString": "2.3.4",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "XPC!",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
            ],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: appex.appendingPathComponent("Contents/Info.plist"))
        let manifest = Self.minimalManifest.merging(["name": "Safari container fixture"]) { _, new in new }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: resources.appendingPathComponent("manifest.json"))
        try "// no-op".write(
            to: resources.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let identity = BrowserWebExtensionSafariAppIdentity(
            id: "password-manager-fixture",
            appBundleIdentifier: "com.example.password-manager",
            extensionBundleIdentifier: "com.example.password-manager.safari",
            teamIdentifier: "TESTTEAM"
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            verifySafariAppExtension: { _ in identity },
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: resources)
            }
        )

        let receipt = try await manager.installExtension(from: app)

        #expect(receipt.name == "Safari container fixture")
        #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent(
            "com.example.password-manager.safari",
            isDirectory: true
        ).path))
        let reference = BrowserWebExtensionAppExtensionReference(
            bundleURL: appex.standardizedFileURL,
            bundleIdentifier: "com.example.password-manager.safari",
            installationName: "com.example.password-manager.safari"
        )
        let ledger = try await repository.managementLedger(in: managedRoot)
        #expect(ledger.records["com.example.password-manager.safari"]?.source == .safariApp(reference))
        #expect(manager.loadedContexts.first?.uniqueIdentifier
            == BrowserWebExtensionsManager.contextIdentifier(
                for: "com.example.password-manager.safari"
            ))
        #expect(manager.loadedContexts.first?.unsupportedAPIs
            .contains("browser.runtime.sendNativeMessage") == false)
        #expect(manager.loadedContexts.first?.unsupportedAPIs
            .contains("browser.runtime.connectNative") == false)

        manager.shutdown()
        let relaunchedManager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            verifySafariAppExtension: { _ in identity },
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: resources)
            }
        )
        await relaunchedManager.loadExtensions()

        #expect(relaunchedManager.loadErrors.isEmpty)
        #expect(relaunchedManager.loadedContexts.first?.uniqueIdentifier
            == BrowserWebExtensionsManager.contextIdentifier(
                for: "com.example.password-manager.safari"
            ))
    }

    @available(macOS 15.4, *)
    @Test func removedSafariAppRelaunchKeepsAUsableRemovalRow() async throws {
        try await Self.assertFailedSafariAppLifecycle(tamper: false)
    }

    @available(macOS 15.4, *)
    @Test func tamperedSafariAppRelaunchCanRetryAfterTrustIsRestored() async throws {
        try await Self.assertFailedSafariAppLifecycle(tamper: true)
    }

    @available(macOS 15.4, *)
    @Test func safariVerificationSuspendsOffMainAndDeadlineCancelsBeforeWebKitLoad() async throws {
        let managedRoot = try Self.makeExtensionsRoot()
        let appRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: managedRoot)
            try? FileManager.default.removeItem(at: appRoot)
        }
        let bundleIdentifier = "com.example.deadline.safari"
        let fixture = try Self.writeSafariExtensionFixture(
            in: appRoot,
            bundleIdentifier: bundleIdentifier
        )
        let identity = BrowserWebExtensionSafariAppIdentity(
            id: "deadline-fixture",
            appBundleIdentifier: "com.example.deadline",
            extensionBundleIdentifier: bundleIdentifier,
            teamIdentifier: "TESTTEAM"
        )
        let reference = BrowserWebExtensionAppExtensionReference(
            bundleURL: fixture.appex,
            bundleIdentifier: bundleIdentifier,
            installationName: bundleIdentifier
        )
        let record = BrowserWebExtensionManagedRecord(
            id: bundleIdentifier,
            displayName: "Deadline fixture",
            version: "1.0",
            source: .safariApp(reference),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        try await repository.upsertManagedRecord(record, in: managedRoot)
        let verificationGate = VerificationSuspensionGate()
        let deadlineGate = RuntimeDeadlineGate()
        let loaderCount = OSAllocatedUnfairLock(initialState: 0)
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: UUID(),
            waitForDeadline: { try await deadlineGate.wait() }
        )
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            profileRuntime: runtime,
            directoryRepository: repository,
            verifySafariAppExtension: { _ in
                await verificationGate.suspend()
                return identity
            },
            appExtensionLoader: { _ in
                loaderCount.withLock { $0 += 1 }
                return try await WKWebExtension(resourceBaseURL: fixture.resources)
            }
        )
        var updates = runtime.updates().makeAsyncIterator()
        _ = await updates.next()

        manager.startLoading()
        await verificationGate.waitUntilEntered()
        deadlineGate.resume()
        while runtime.phase != .degraded(.loadDeadlineExceeded) {
            guard await updates.next() != nil else {
                Issue.record("Runtime stream ended before the responsive deadline")
                return
            }
        }

        #expect(loaderCount.withLock { $0 } == 0)
        #expect(manager.loadedContexts.isEmpty)
        await verificationGate.resume()
        for _ in 0..<4 { await Task.yield() }
        #expect(loaderCount.withLock { $0 } == 0)
        #expect(manager.loadedContexts.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func safariStartupPerformsBothStrictVerificationPasses() async throws {
        let managedRoot = try Self.makeExtensionsRoot()
        let appRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: managedRoot)
            try? FileManager.default.removeItem(at: appRoot)
        }
        let bundleIdentifier = "com.example.double-check.safari"
        let fixture = try Self.writeSafariExtensionFixture(
            in: appRoot,
            bundleIdentifier: bundleIdentifier
        )
        let identity = BrowserWebExtensionSafariAppIdentity(
            id: "double-check-fixture",
            appBundleIdentifier: "com.example.double-check",
            extensionBundleIdentifier: bundleIdentifier,
            teamIdentifier: "TESTTEAM"
        )
        let reference = BrowserWebExtensionAppExtensionReference(
            bundleURL: fixture.appex,
            bundleIdentifier: bundleIdentifier,
            installationName: bundleIdentifier
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        try await repository.upsertManagedRecord(
            BrowserWebExtensionManagedRecord(
                id: bundleIdentifier,
                displayName: "Double check fixture",
                version: "1.0",
                source: .safariApp(reference),
                isEnabled: true,
                grantedPermissions: [],
                grantedMatchPatterns: []
            ),
            in: managedRoot
        )
        let verificationCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            verifySafariAppExtension: { _ in
                verificationCount.withLock { $0 += 1 }
                return identity
            },
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: fixture.resources)
            }
        )

        await manager.loadExtensions()

        #expect(manager.loadedContexts.count == 1)
        #expect(verificationCount.withLock { $0 } == 2)
    }

    @available(macOS 15.4, *)
    @Test func startupHashesEachManagedPackageExactlyOnceBeforeLoad() async throws {
        let managedRoot = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: managedRoot) }
        let source = try Self.writeExtension(
            named: "single-digest",
            in: managedRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let setupManager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent()
        )
        try await setupManager.approveInstalledCandidate(source)
        setupManager.shutdown()
        let loadingRepository = BrowserWebExtensionDirectoryRepository()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: loadingRepository
        )

        await manager.loadExtensions()

        #expect(manager.loadedContexts.count == 1)
        let digestRequestCount = await loadingRepository.managedPackageDigestRequestCountForTesting()
        #expect(digestRequestCount == 1)
    }

    @available(macOS 15.4, *)
    @Test func presentationSnapshotIncludesDeclaredExtensionIcon() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["icons"] = ["16": "icon.png"]
        manifest["action"] = ["default_icon": ["16": "icon.png"]]
        let directory = try Self.writeExtension(named: "sample", in: root, manifest: manifest)
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try Self.makeIconPNG().write(to: directory.appendingPathComponent("icon.png"))
        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())

        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()

        let item = try #require(manager.presentationSnapshot().extensions.first)
        let iconData = try #require(item.iconData)
        #expect(NSImage(data: iconData) != nil)
    }

    @available(macOS 15.4, *)
    @Test func presentationSnapshotRecognizesEveryManifestActionKind() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        for actionKey in ["action", "browser_action", "page_action"] {
            var manifest = Self.minimalManifest
            manifest["name"] = actionKey
            if actionKey != "action" {
                manifest["manifest_version"] = 2
                manifest["permissions"] = ["storage", "*://example.com/*"]
                manifest.removeValue(forKey: "host_permissions")
            }
            manifest[actionKey] = [
                "default_title": actionKey,
                "default_popup": "popup.html",
            ]
            let directory = try Self.writeExtension(
                named: actionKey,
                in: root,
                manifest: manifest
            )
            try "// no-op".write(
                to: directory.appendingPathComponent("content.js"),
                atomically: true,
                encoding: .utf8
            )
            try "<main>Popup for \(actionKey)</main>".write(
                to: directory.appendingPathComponent("popup.html"),
                atomically: true,
                encoding: .utf8
            )
            try await manager.approveInstalledCandidate(directory)
        }

        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer {
            manager.unregister(panelID: panel.id)
            panel.close()
        }
        let tabs = manager.loadedContexts.flatMap { context in
            manager.webExtensionController(manager.controller, openWindowsFor: context)
                .flatMap { $0.tabs?(for: context) ?? [] }
        }
        let tab = try #require(tabs.first)

        let items = manager.presentationSnapshot().extensions
        let allHaveActions = items.allSatisfy { $0.hasAction }
        #expect(items.map(\.name) == ["action", "browser_action", "page_action"])
        #expect(allHaveActions)
        #expect(manager.loadedContexts.allSatisfy { context in
            context.action(for: tab)?.presentsPopup == true
        })
    }

    @available(macOS 15.4, *)
    @Test func tabOrderSingleMoveResolverIdentifiesFrontAndBackMoves() {
        let a = UUID()
        let b = UUID()
        let c = UUID()

        #expect(BrowserWebExtensionsManager.movedPanelIDForSingleMove(
            previous: [a, b, c],
            current: [b, c, a]
        ) == a)
        #expect(BrowserWebExtensionsManager.movedPanelIDForSingleMove(
            previous: [a, b, c],
            current: [c, a, b]
        ) == c)
        #expect(BrowserWebExtensionsManager.movedPanelIDForSingleMove(
            previous: [a, b, c],
            current: [a, b, c]
        ) == nil)
    }

    @Test func flatExtensionTabIndexResolvesToNeighborInsertionPlan() {
        let a = UUID()
        let b = UUID()
        let c = UUID()

        #expect(BrowserWebExtensionTabInsertionPlan.resolve(
            index: 0,
            orderedPanelIDs: [a, b, c]
        ) == .before(a))
        #expect(BrowserWebExtensionTabInsertionPlan.resolve(
            index: 2,
            orderedPanelIDs: [a, b, c]
        ) == .before(c))
        #expect(BrowserWebExtensionTabInsertionPlan.resolve(
            index: 3,
            orderedPanelIDs: [a, b, c]
        ) == .after(c))
        #expect(BrowserWebExtensionTabInsertionPlan.resolve(
            index: 0,
            orderedPanelIDs: []
        ) == .fallbackEnd)
    }

    @available(macOS 15.4, *)
    @Test func workspaceExtensionTabInsertionUsesFlatOrderAcrossPanes() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let rootPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.newBrowserSurface(
            inPane: rootPane,
            focus: false,
            creationPolicy: .restoration
        ))
        let second = try #require(workspace.newBrowserSplit(
            from: first.id,
            orientation: .horizontal,
            focus: false,
            creationPolicy: .restoration
        ))
        let manager = try #require(services.webExtensionsManager)
        let owner = try #require(manager.registrationOwner(for: first.id))
        let browserPanelIDs = {
            workspace.orderedPanelIds.filter { workspace.panels[$0] is BrowserPanel }
        }
        #expect(browserPanelIDs() == [first.id, second.id])

        let inserted = try #require(owner.createTab(1, false, false))
        #expect(browserPanelIDs() == [first.id, inserted.id, second.id])
        #expect(workspace.paneId(forPanelId: inserted.id) == workspace.paneId(forPanelId: second.id))

        let appended = try #require(owner.createTab(NSNotFound, false, false))
        #expect(browserPanelIDs().last == appended.id)
        #expect(workspace.paneId(forPanelId: appended.id) == workspace.paneId(forPanelId: second.id))
    }

    @available(macOS 15.4, *)
    @Test func dockExtensionTabInsertionUsesFlatOrderAcrossPanes() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let store = DockSplitStore(
            workspaceId: UUID(),
            browserServices: services,
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let firstID = try #require(store.newSurface(
            kind: .browser,
            inPane: rootPane,
            focus: false
        ))
        let secondID = try #require(store.newSplit(
            kind: .browser,
            orientation: .horizontal,
            insertFirst: false,
            sourcePanelId: firstID,
            focus: false
        ))
        let manager = try #require(services.webExtensionsManager)
        let owner = try #require(manager.registrationOwner(for: firstID))
        let browserPanelIDs = {
            store.bonsplitController.allTabIds.compactMap { tabID -> UUID? in
                guard let panel = store.panel(for: tabID) as? BrowserPanel else { return nil }
                return panel.id
            }
        }
        #expect(browserPanelIDs() == [firstID, secondID])

        let inserted = try #require(owner.createTab(1, false, false))
        #expect(browserPanelIDs() == [firstID, inserted.id, secondID])
        #expect(store.paneId(forPanelId: inserted.id) == store.paneId(forPanelId: secondID))

        let appended = try #require(owner.createTab(NSNotFound, false, false))
        #expect(browserPanelIDs().last == appended.id)
        #expect(store.paneId(forPanelId: appended.id) == store.paneId(forPanelId: secondID))
    }

    @available(macOS 15.4, *)
    @Test func toolbarActionPinningPersistsAcrossManagerRelaunch() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Pinned action"]
        let directory = try Self.writeExtension(
            named: "pinned-action",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let identifier = BrowserWebExtensionsManager.contextIdentifier(for: "pinned-action")
        let firstManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await firstManager.approveInstalledCandidate(directory)
        await firstManager.loadExtensions()

        #expect(firstManager.presentationSnapshot().extensions.first?.isToolbarPinned == false)
        try await firstManager.setToolbarActionPinned(true, uniqueIdentifier: identifier)
        #expect(firstManager.presentationSnapshot().extensions.first?.isToolbarPinned == true)
        firstManager.shutdown()

        let relaunchedManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        await relaunchedManager.loadExtensions()

        #expect(relaunchedManager.presentationSnapshot().extensions.first?.isToolbarPinned == true)
        try await relaunchedManager.setToolbarActionPinned(false, uniqueIdentifier: identifier)
        #expect(relaunchedManager.presentationSnapshot().extensions.first?.isToolbarPinned == false)
    }

    @available(macOS 15.4, *)
    @Test func disablingAndReenablingRestoresThePersistedToolbarPin() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Pinned lifecycle action"]
        let directory = try Self.writeExtension(
            named: "pinned-lifecycle-action",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let identifier = BrowserWebExtensionsManager.contextIdentifier(
            for: "pinned-lifecycle-action"
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        try await manager.setToolbarActionPinned(true, uniqueIdentifier: identifier)

        try await manager.setExtensionEnabled(
            managementID: "pinned-lifecycle-action",
            isEnabled: false
        )
        try await manager.setExtensionEnabled(
            managementID: "pinned-lifecycle-action",
            isEnabled: true
        )

        #expect(manager.presentationSnapshot().extensions.first?.isToolbarPinned == true)
        manager.shutdown()
        let relaunchedManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        await relaunchedManager.loadExtensions()
        #expect(relaunchedManager.presentationSnapshot().extensions.first?.isToolbarPinned == true)
    }

    @available(macOS 15.4, *)
    @Test func catalogArchiveInstallationPreservesPinnedRawDigestAndStaysCurrent() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let archive = sourceRoot.appendingPathComponent("fixture.zip")
        let archiveBytes = Data("verified catalog archive".utf8)
        try archiveBytes.write(to: archive)
        let pinnedDigest = SHA256.hash(data: archiveBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let repository = BrowserWebExtensionDirectoryRepository()

        let installed = try await repository.installImmutableCandidate(
            from: archive,
            into: managedRoot
        )

        #expect(installed.digest == pinnedDigest)
        let entry = BrowserWebExtensionCatalogEntry(
            id: "fixture",
            version: "1.0",
            packageURL: URL(string: "https://example.com/fixture.zip")!,
            packageSHA256: pinnedDigest
        )
        let record = BrowserWebExtensionManagedRecord(
            id: entry.installedManagementID,
            displayName: "Fixture",
            version: entry.version,
            source: .catalogArchive(
                filename: installed.url.lastPathComponent,
                digest: installed.digest,
                catalogID: entry.id
            ),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        let catalog = BrowserWebExtensionCatalog(
            verifiedEntries: [entry],
            safariAppIdentities: []
        )

        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: record,
            loadedVersion: entry.version,
            catalog: catalog
        ) == false)
    }

    @available(macOS 15.4, *)
    @Test func trustedUpdateAvailabilityDistinguishesCurrentCatalogNewCatalogAndSignedApp() {
        let currentEntry = BrowserWebExtensionCatalogEntry(
            id: "fixture",
            version: "1.0",
            packageURL: URL(string: "https://example.com/fixture-1.zip")!,
            packageSHA256: String(repeating: "1", count: 64)
        )
        let currentCatalog = BrowserWebExtensionCatalog(
            verifiedEntries: [currentEntry],
            safariAppIdentities: []
        )
        let catalogRecord = BrowserWebExtensionManagedRecord(
            id: "catalog:fixture",
            displayName: "Fixture",
            version: "1.0",
            source: .catalogArchive(
                filename: "fixture.zip",
                digest: currentEntry.packageSHA256,
                catalogID: currentEntry.id
            ),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: catalogRecord,
            loadedVersion: "1.0",
            catalog: currentCatalog
        ) == false)

        let newerCatalog = BrowserWebExtensionCatalog(
            verifiedEntries: [BrowserWebExtensionCatalogEntry(
                id: "fixture",
                version: "2.0",
                packageURL: URL(string: "https://example.com/fixture-2.zip")!,
                packageSHA256: String(repeating: "2", count: 64)
            )],
            safariAppIdentities: []
        )
        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: catalogRecord,
            loadedVersion: "1.0",
            catalog: newerCatalog
        ) == true)

        let appRecord = BrowserWebExtensionManagedRecord(
            id: "com.example.safari",
            displayName: "Signed App Fixture",
            version: "3.0",
            source: .safariApp(BrowserWebExtensionAppExtensionReference(
                bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app/Contents/PlugIns/Fixture.appex"),
                bundleIdentifier: "com.example.safari",
                installationName: "Fixture.appex"
            )),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: appRecord,
            loadedVersion: "3.0",
            catalog: currentCatalog
        ) == false)
        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: appRecord,
            loadedVersion: "3.1",
            catalog: currentCatalog
        ) == true)
    }

    @available(macOS 15.4, *)
    @Test func toolbarPinLedgerFailureIsVisibleAndDoesNotMutatePinState() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Pin failure probe"]
        let directory = try Self.writeExtension(
            named: "pin-failure-probe",
            in: root,
            manifest: manifest
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let identifier = try #require(manager.loadedContexts.first?.uniqueIdentifier)
        let ledgerURL = root.appendingPathComponent(".cmux-extension-management.json")
        let symlinkTarget = root.appendingPathComponent("ledger-target.json")
        try Data("{}".utf8).write(to: symlinkTarget)
        try FileManager.default.removeItem(at: ledgerURL)
        try FileManager.default.createSymbolicLink(
            at: ledgerURL,
            withDestinationURL: symlinkTarget
        )

        await #expect(throws: BrowserWebExtensionInstallError.symbolicLinksNotAllowed) {
            try await manager.setToolbarActionPinned(true, uniqueIdentifier: identifier)
        }

        let item = try #require(manager.presentationSnapshot().extensions.first)
        #expect(!item.isToolbarPinned)
        #expect(item.actionFailure == .toolbarPinFailed)
    }

    @available(macOS 15.4, *)
    @Test func presentationSnapshotUsesEachPackageManifestIconWithoutNameMapping() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var alphaManifest = Self.minimalManifest
        alphaManifest["name"] = "Arbitrary Alpha"
        alphaManifest["icons"] = ["16": "extension-icon.png"]
        alphaManifest["action"] = ["default_icon": ["16": "action-icon.png"]]
        let alphaDirectory = try Self.writeExtension(
            named: "arbitrary-alpha",
            in: root,
            manifest: alphaManifest
        )
        try "// no-op".write(
            to: alphaDirectory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try Self.makeIconPNG(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            .write(to: alphaDirectory.appendingPathComponent("extension-icon.png"))
        try Self.makeIconPNG(color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .write(to: alphaDirectory.appendingPathComponent("action-icon.png"))

        var betaManifest = Self.minimalManifest
        betaManifest["name"] = "Arbitrary Beta"
        betaManifest["icons"] = ["16": "extension-icon.png"]
        let betaDirectory = try Self.writeExtension(
            named: "arbitrary-beta",
            in: root,
            manifest: betaManifest
        )
        try "// no-op".write(
            to: betaDirectory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try Self.makeIconPNG(color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            .write(to: betaDirectory.appendingPathComponent("extension-icon.png"))

        var iconlessManifest = Self.minimalManifest
        iconlessManifest["name"] = "Arbitrary Iconless"
        let iconless = try Self.writeExtension(
            named: "arbitrary-iconless",
            in: root,
            manifest: iconlessManifest
        )
        try "// no-op".write(
            to: iconless.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        try await manager.approveInstalledCandidate(alphaDirectory)
        try await manager.approveInstalledCandidate(betaDirectory)
        try await manager.approveInstalledCandidate(iconless)
        await manager.loadExtensions()

        let itemsByName = Dictionary(
            uniqueKeysWithValues: manager.presentationSnapshot().extensions.map { ($0.name, $0) }
        )
        let alpha = try #require(itemsByName["Arbitrary Alpha"]?.iconData)
        let beta = try #require(itemsByName["Arbitrary Beta"]?.iconData)
        let alphaColor = try Self.centerColor(in: alpha)
        let betaColor = try Self.centerColor(in: beta)
        #expect(alphaColor.blueComponent > 0.8)
        #expect(alphaColor.blueComponent > alphaColor.redComponent + 0.5)
        #expect(alphaColor.blueComponent > alphaColor.greenComponent + 0.5)
        #expect(betaColor.greenComponent > 0.8)
        #expect(betaColor.greenComponent > betaColor.redComponent + 0.5)
        #expect(betaColor.greenComponent > betaColor.blueComponent + 0.5)
        #expect(itemsByName["Arbitrary Iconless"]?.iconData == nil)
    }

    @available(macOS 15.4, *)
    @Test func duplicateInstallIsAnIdempotentUpdateWithoutDuplicateState() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(named: "sample", in: sourceRoot, manifest: Self.minimalManifest)
        try "// no-op".write(to: source.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        let manager = BrowserWebExtensionsManager(directory: managedRoot, controllerConfiguration: .nonPersistent())
        let firstReceipt = try await manager.installExtension(from: source)
        let preview = try await manager.prepareInstall(from: source)
        #expect(preview.isUpdate)
        let secondReceipt = try await manager.confirmPreparedInstall(id: preview.id)

        #expect(firstReceipt.name == secondReceipt.name)
        #expect(manager.loadedContexts.count == 1)
        let ledger = try await BrowserWebExtensionDirectoryRepository()
            .managementLedger(in: managedRoot)
        #expect(ledger.records.keys.sorted() == ["sample"])
        #expect(BrowserWebExtensionsManager.candidateURLs(in: managedRoot).count == 1)
    }

    @available(macOS 15.4, *)
    @Test func rejectedSymlinkPackageNeverActivatesAContext() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(
            named: "symlink-package",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked-resource.js"),
            withDestinationURL: source.appendingPathComponent("content.js")
        )
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent()
        )

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            _ = try await manager.installExtension(from: source)
        }

        #expect(manager.loadedContexts.isEmpty)
        #expect(manager.controller.extensionContexts.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func contentScriptOnlyMatchPatternsAreGranted() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "cmux content script only test",
            "version": "1.0",
            "description": "Test fixture",
            "content_scripts": [
                [
                    "matches": ["*://content-only.example/*"],
                    "js": ["content.js"],
                ]
            ],
        ]
        let dir = try Self.writeExtension(named: "content-only", in: root, manifest: manifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()

        #expect(manager.loadErrors.isEmpty)
        let context = try #require(manager.loadedContexts.first)
        let url = try #require(URL(string: "https://content-only.example/page"))
        #expect(context.grantedPermissionMatchPatterns.keys.contains { $0.matches(url) })
    }

    @available(macOS 15.4, *)
    @Test func webViewConfigurationUsesInjectedController() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let configuration = WKWebViewConfiguration()

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )

        #expect(configuration.webExtensionController === services.webExtensionsManager?.controller)
    }

    @available(macOS 15.4, *)
    @Test func webViewConfigurationDoesNotStartExtensionsBeforeWebViewExists() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let profileID = UUID()
        let manager = services.webExtensionsManager(for: profileID)
        let configuration = WKWebViewConfiguration()

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            profileID: profileID,
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )

        #expect(configuration.webExtensionController === manager.controller)
        #expect(manager.profileRuntime.phase == .idle)
    }

    @Test func trustedSafariAppsAreOptInSuggestions() {
        #expect(BrowserWebExtensionCatalog.production.safariAppIdentities.map(\.id) == [
            "bitwarden-safari-app",
            "ublock-origin-lite-safari-app",
        ])
        #expect(BrowserWebExtensionCatalog.production.safariAppIdentities.allSatisfy {
            !$0.appBundleIdentifier.localizedCaseInsensitiveContains("1password")
                && !$0.extensionBundleIdentifier.localizedCaseInsensitiveContains("1password")
        })
    }

    @available(macOS 15.4, *)
    @Test func extensionControllerInstallsWebKitNotificationCompatibility() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WKWebExtensionController.Configuration.nonPersistent()

        _ = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: configuration
        )

        let scripts = configuration.webViewConfiguration.userContentController.userScripts
        #expect(scripts.contains { script in
            script.source == BrowserWebExtensionsManager.notificationsCompatibilityScriptSource
                && script.injectionTime == .atDocumentStart
                && script.isForMainFrameOnly == false
        })
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "!namespace.notifications"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "onClicked"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "onCreatedNavigationTarget"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "readystatechange"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "Object.defineProperty(webNavigation, 'onCreatedNavigationTarget'"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "connectNative"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "No such native application"
        ))
    }

    @available(macOS 15.4, *)
    @Test func compatibilityAPIsSurviveNestedNamespaceWrapperChurn() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: "globalThis.chrome = { webNavigation: {}, runtime: {} };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserWebExtensionsManager.notificationsCompatibilityScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        let waiter = WebViewLoadWaiter()
        webView.navigationDelegate = waiter

        try await waiter.load("<html><body>fixture</body></html>", in: webView)
        try await Task.sleep(for: .milliseconds(150))
        let rawResult = try await webView.callAsyncJavaScript(
            #"""
            const initialNavigation = chrome.webNavigation;
            const initialRuntime = chrome.runtime;
            for (let index = 0; index < 10000; index += 1) {
              const churn = { index, bytes: new Uint8Array(64) };
              if (churn.index < 0) throw new Error('unreachable');
            }
            await new Promise(resolve => setTimeout(resolve, 10));
            return {
              navigationIdentityStable: initialNavigation === chrome.webNavigation,
              runtimeIdentityStable: initialRuntime === chrome.runtime,
              navigationEventType: typeof chrome.webNavigation.onCreatedNavigationTarget,
              connectNativeType: typeof chrome.runtime.connectNative,
              notificationsType: typeof chrome.notifications,
              navigationConfigurable: Object.getOwnPropertyDescriptor(chrome, 'webNavigation')?.configurable,
              runtimeConfigurable: Object.getOwnPropertyDescriptor(chrome, 'runtime')?.configurable
            };
            """#,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let result = try #require(rawResult as? [String: Any])

        #expect(result["navigationIdentityStable"] as? Bool == true)
        #expect(result["runtimeIdentityStable"] as? Bool == true)
        #expect(result["navigationEventType"] as? String == "object")
        #expect(result["connectNativeType"] as? String == "function")
        #expect(result["notificationsType"] as? String == "object")
        #expect(result["navigationConfigurable"] as? Bool == false)
        #expect(result["runtimeConfigurable"] as? Bool == false)
    }

    @available(macOS 15.4, *)
    @Test func safariCompatibleApplicationNameUsesProviderAndSafeFallback() {
        let fallback = OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 3,
            patchVersion: 1
        )

        #expect(BrowserWebExtensionsManager.safariCompatibleApplicationName(
            safariVersionProvider: { "26.5" },
            operatingSystemVersion: fallback
        ) == "Version/26.5 Safari/605.1.15 cmux")
        #expect(BrowserWebExtensionsManager.safariCompatibleApplicationName(
            safariVersionProvider: { nil },
            operatingSystemVersion: fallback
        ) == "Version/27.3 Safari/605.1.15 cmux")
        #expect(BrowserWebExtensionsManager.safariCompatibleApplicationName(
            safariVersionProvider: { "invalid token" },
            operatingSystemVersion: fallback
        ) == "Version/27.3 Safari/605.1.15 cmux")
    }

    @available(macOS 15.4, *)
    @Test func extensionControllerUsesSafariCompatibleApplicationName() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WKWebExtensionController.Configuration.nonPersistent()

        _ = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: configuration
        )

        #expect(
            configuration.webViewConfiguration.applicationNameForUserAgent
                == BrowserWebExtensionsManager.safariCompatibleApplicationName()
        )
    }

    @available(macOS 15.4, *)
    @Test func profileManagersUseSeparateControllersAndInstallDirectories() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let alternateProfileID = UUID()
        let defaultManager = try #require(services.webExtensionsManager)
        let alternateManager = services.webExtensionsManager(for: alternateProfileID)

        #expect(defaultManager.directory == root)
        #expect(alternateManager.directory == root
            .appendingPathComponent(".profiles", isDirectory: true)
            .appendingPathComponent(alternateProfileID.uuidString.lowercased(), isDirectory: true))
        #expect(defaultManager.controller !== alternateManager.controller)
        #expect(BrowserServices.extensionDirectory(
            for: defaultProfileID,
            defaultProfileID: defaultProfileID,
            root: root
        ) == root)

        let defaultConfiguration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            defaultConfiguration,
            profileID: defaultProfileID,
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )
        let alternateConfiguration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            alternateConfiguration,
            profileID: alternateProfileID,
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )

        #expect(defaultConfiguration.webExtensionController === defaultManager.controller)
        #expect(alternateConfiguration.webExtensionController === alternateManager.controller)
    }

    @available(macOS 15.4, *)
    @Test func switchingProfileTransfersPanelBetweenExtensionRegistries() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternateProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension isolation \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: alternateProfile.id) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let panel = BrowserPanel(
            workspaceId: workspace.id,
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            browserServices: services
        )
        services.registerBrowserPanel(panel, workspace: workspace)
        defer {
            services.unregisterBrowserPanel(id: panel.id)
            panel.close()
        }
        let extensionDirectory = try Self.writeExtension(
            named: "registry-probe",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: extensionDirectory)
        )
        let defaultManager = try #require(services.webExtensionsManager)
        let alternateManager = services.webExtensionsManager(for: alternateProfile.id)

        #expect(defaultManager
            .webExtensionController(defaultManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })
        #expect(!alternateManager
            .webExtensionController(alternateManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })

        #expect(panel.switchToProfile(alternateProfile.id))

        #expect(panel.webView.configuration.webExtensionController === alternateManager.controller)
        #expect(!defaultManager
            .webExtensionController(defaultManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })
        #expect(alternateManager
            .webExtensionController(alternateManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })
    }

    @available(macOS 15.4, *)
    @Test func switchingProfileFromExtensionPageRestoresNormalPageBindings() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternateProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension page switch \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: alternateProfile.id) }
        let extensionDirectory = try Self.writeExtension(
            named: "profile-extension-page",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: extensionDirectory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<html><body>extension profile probe</body></html>".write(
            to: extensionDirectory.appendingPathComponent("probe.html"),
            atomically: true,
            encoding: .utf8
        )
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let panel = BrowserPanel(
            workspaceId: workspace.id,
            browserServices: services
        )
        services.registerBrowserPanel(panel, workspace: workspace)
        defer {
            services.unregisterBrowserPanel(id: panel.id)
            panel.close()
        }
        let defaultManager = try #require(services.webExtensionsManager)
        try await defaultManager.approveInstalledCandidate(extensionDirectory)
        await defaultManager.loadExtensions()
        let context = try #require(defaultManager.loadedContexts.first)
        #expect(panel.hasNormalPageBindingsForTesting)

        panel.navigate(to: context.baseURL.appendingPathComponent("probe.html"))
        try await Self.waitForJavaScriptString(
            "document.body?.textContent?.trim() || ''",
            toEqual: "extension profile probe",
            in: panel.webView
        )
        #expect(!panel.hasNormalPageBindingsForTesting)

        #expect(panel.switchToProfile(alternateProfile.id))

        #expect(panel.webView.configuration.webExtensionController
            === services.webExtensionsManager(for: alternateProfile.id).controller)
        #expect(panel.hasNormalPageBindingsForTesting)
    }

    @available(macOS 15.4, *)
    @Test func deletingActiveProfilePreservesPanelRegistrationForReplacementProfile() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deletedProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Deleted extension profile \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: deletedProfile.id) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let panel = BrowserPanel(
            workspaceId: workspace.id,
            profileID: deletedProfile.id,
            browserServices: services
        )
        services.registerBrowserPanel(panel, workspace: workspace)
        defer {
            services.unregisterBrowserPanel(id: panel.id)
            panel.close()
        }
        let deletedManager = services.webExtensionsManager(for: deletedProfile.id)
        #expect(services.registeredBrowserPanelCount == 1)

        #expect(BrowserProfileStore.shared.deleteProfile(id: deletedProfile.id) != nil)
        for _ in 0..<20 {
            if !services.hasRetainedWebExtensionsManagerForTesting(profileID: deletedProfile.id) {
                break
            }
            await Task.yield()
        }
        #expect(!services.hasRetainedWebExtensionsManagerForTesting(profileID: deletedProfile.id))
        #expect(deletedManager.isShutDown)
        #expect(services.registeredBrowserPanelCount == 1)

        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        #expect(panel.switchToProfile(defaultProfileID))
        let replacementManager = services.webExtensionsManager(for: defaultProfileID)
        let extensionDirectory = try Self.writeExtension(
            named: "deleted-profile-registration-probe",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: extensionDirectory)
        )
        #expect(replacementManager
            .webExtensionController(replacementManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })
    }

    @available(macOS 15.4, *)
    @Test func switchingProfileDefersRestoreUntilNewProfileExtensionsLoad() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternateProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Deferred extension restore \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: alternateProfile.id) }
        let services = BrowserServices(extensionDirectory: root)
        await services.webExtensionsManager?.loadExtensions()
        let loadGate = RuntimeLoadGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: alternateProfile.id,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        runtime.start { await loadGate.wait() }
        let alternateManager = BrowserWebExtensionsManager(
            directory: BrowserServices.extensionDirectory(
                for: alternateProfile.id,
                defaultProfileID: BrowserProfileStore.shared.builtInDefaultProfileID,
                root: root
            ),
            controllerIdentifier: alternateProfile.id,
            controllerConfiguration: .nonPersistent(),
            profileID: alternateProfile.id,
            profileRuntime: runtime
        )
        services.installWebExtensionsManagerForTesting(alternateManager, profileID: alternateProfile.id)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            initialURL: try #require(URL(string: "https://example.com/profile-restore")),
            browserServices: services
        )
        defer { panel.close() }

        #expect(panel.switchToProfile(alternateProfile.id))
        #expect(panel.isWaitingForWebExtensionsBeforeNavigation)

        loadGate.resume()
        for _ in 0..<4 { await Task.yield() }
        #expect(!panel.isWaitingForWebExtensionsBeforeNavigation)
    }

    @available(macOS 15.4, *)
    @Test func extensionControllersUseTheOwningProfileWebsiteDataStore() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension cookies A \(UUID().uuidString.prefix(6))"
        ))
        let secondProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension cookies B \(UUID().uuidString.prefix(6))"
        ))
        defer {
            _ = BrowserProfileStore.shared.deleteProfile(id: firstProfile.id)
            _ = BrowserProfileStore.shared.deleteProfile(id: secondProfile.id)
        }
        let services = BrowserServices(extensionDirectory: root)
        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let defaultManager = services.webExtensionsManager(for: defaultProfileID)
        let firstManager = services.webExtensionsManager(for: firstProfile.id)
        let secondManager = services.webExtensionsManager(for: secondProfile.id)
        let defaultStore = BrowserProfileStore.shared.websiteDataStore(for: defaultProfileID)
        let firstStore = BrowserProfileStore.shared.websiteDataStore(for: firstProfile.id)
        let secondStore = BrowserProfileStore.shared.websiteDataStore(for: secondProfile.id)

        #expect(defaultManager.controller.configuration.defaultWebsiteDataStore === defaultStore)
        #expect(firstManager.controller.configuration.defaultWebsiteDataStore === firstStore)
        #expect(secondManager.controller.configuration.defaultWebsiteDataStore === secondStore)
        #expect(firstManager.controller.configuration.defaultWebsiteDataStore !== secondStore)
        #expect(secondManager.controller.configuration.defaultWebsiteDataStore !== firstStore)
    }

    @available(macOS 15.4, *)
    @Test func webKitSuppliedPopupConfigurationPreservesSharedExtensionContentController() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "shared-popup-configuration",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<title>Shared popup fixture</title>".write(
            to: directory.appendingPathComponent("popup.html"),
            atomically: true,
            encoding: .utf8
        )
        let services = BrowserServices(extensionDirectory: root)
        let manager = try #require(services.webExtensionsManager)
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let popupURL = context.baseURL.appendingPathComponent("popup.html")
        let suppliedConfiguration = try #require(
            manager.pageConfiguration(for: popupURL)?.configuration
        )
        let sharedController = suppliedConfiguration.userContentController
        let messageCounter = ScriptMessageCounter()
        sharedController.removeScriptMessageHandler(
            forName: BrowserSSLTrustBypassMessageHandler.name
        )
        sharedController.add(
            messageCounter,
            name: BrowserSSLTrustBypassMessageHandler.name
        )
        defer {
            sharedController.removeScriptMessageHandler(
                forName: BrowserSSLTrustBypassMessageHandler.name
            )
            manager.shutdown()
        }
        let originalScriptSources = sharedController.userScripts.map(\.source)
        let siblingWebView = try await Self.loadExtensionPage(
            "popup.html",
            context: context,
            manager: manager
        )
        let token = UUID().uuidString
        try await Self.postScriptMessage(
            named: BrowserSSLTrustBypassMessageHandler.name,
            body: token,
            in: siblingWebView
        )
        try await Self.waitUntil("shared popup handler baseline") {
            messageCounter.count == 1
        }

        let firstPopup = BrowserPopupWindowController(
            configuration: suppliedConfiguration,
            windowFeatures: WKWindowFeatures(),
            browserContext: BrowserPopupBrowserContext(
                profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
                websiteDataStore: suppliedConfiguration.websiteDataStore,
                browserServices: services
            ),
            openerPanel: nil
        )
        let secondPopup = BrowserPopupWindowController(
            configuration: suppliedConfiguration,
            windowFeatures: WKWindowFeatures(),
            browserContext: BrowserPopupBrowserContext(
                profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
                websiteDataStore: suppliedConfiguration.websiteDataStore,
                browserServices: services
            ),
            openerPanel: nil
        )
        defer {
            if firstPopup.webView.window != nil { firstPopup.closePopup() }
            if secondPopup.webView.window != nil { secondPopup.closePopup() }
        }

        #expect(firstPopup.webView.configuration.userContentController === sharedController)
        #expect(secondPopup.webView.configuration.userContentController === sharedController)
        #expect(sharedController.userScripts.map(\.source) == originalScriptSources)

        secondPopup.webView.load(URLRequest(url: popupURL))
        try await Self.waitForJavaScriptString(
            "document.title",
            toEqual: "Shared popup fixture",
            in: secondPopup.webView
        )
        try await Self.postScriptMessage(
            named: BrowserSSLTrustBypassMessageHandler.name,
            body: token,
            in: secondPopup.webView
        )
        try await Self.waitUntil("shared handler after sibling popup creation") {
            messageCounter.count == 2
        }

        firstPopup.closePopup()
        try await Self.postScriptMessage(
            named: BrowserSSLTrustBypassMessageHandler.name,
            body: token,
            in: secondPopup.webView
        )
        try await Self.waitUntil("shared handler after sibling popup close") {
            messageCounter.count == 3
        }
        #expect(
            try await secondPopup.webView.evaluateJavaScript("document.title") as? String
                == "Shared popup fixture"
        )
    }

    @available(macOS 15.4, *)
    @Test func nestedPopupKeepsTheProfileContextCapturedByItsParent() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternateProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Popup isolation \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: alternateProfile.id) }
        let services = BrowserServices(extensionDirectory: root)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            browserServices: services
        )
        defer { panel.close() }
        let defaultManager = try #require(services.webExtensionsManager)
        let originalStore = panel.webView.configuration.websiteDataStore
        let parent = BrowserPopupWindowController(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures(),
            browserContext: panel.popupBrowserContext,
            openerPanel: panel
        )
        defer { parent.closePopup() }

        #expect(parent.webView.configuration.webExtensionController === defaultManager.controller)
        #expect(panel.switchToProfile(alternateProfile.id))
        let alternateManager = services.webExtensionsManager(for: alternateProfile.id)
        let child = try #require(parent.createNestedPopup(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures()
        ))

        #expect(child.configuration.websiteDataStore === originalStore)
        #expect(child.configuration.webExtensionController === defaultManager.controller)
        #expect(child.configuration.webExtensionController !== alternateManager.controller)

        let freshPopup = try #require(panel.createFloatingPopup(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures()
        ))
        #expect(freshPopup.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore)
        #expect(freshPopup.configuration.webExtensionController === alternateManager.controller)
    }

    @available(macOS 15.4, *)
    @Test func standalonePopupIsRegisteredAsExtensionPopupWindowUntilClose() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Self.writeExtension(
            named: "standalone-popup-registration",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let panel = BrowserPanel(
            workspaceId: workspace.id,
            browserServices: services
        )
        services.registerBrowserPanel(panel, workspace: workspace)
        defer {
            services.unregisterBrowserPanel(id: panel.id)
            panel.close()
        }
        let manager = try #require(services.webExtensionsManager)
        try await manager.approveInstalledCandidate(source)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let popup = BrowserPopupWindowController(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures(),
            browserContext: panel.popupBrowserContext,
            openerPanel: panel
        )

        let openWindows = manager.webExtensionController(
            manager.controller,
            openWindowsFor: context
        )
        let popupWindow = try #require(openWindows.first(where: { window in
            guard window.windowType?(for: context) == .popup else { return false }
            let tabs = window.tabs?(for: context) ?? []
            return tabs.contains(where: {
                $0.webView?(for: context) === popup.webView
            })
        }))
        #expect(popupWindow.activeTab?(for: context)?.webView?(for: context) === popup.webView)

        popup.closePopup()
        for _ in 0..<4 { await Task.yield() }

        #expect(!manager
            .webExtensionController(manager.controller, openWindowsFor: context)
            .contains(where: { $0.windowType?(for: context) == .popup }))
    }

    @available(macOS 15.4, *)
    @Test func standalonePopupRetainsItsCapturedProfileRuntimeAcrossOpenerSwitch() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let popupProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Popup runtime \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: popupProfile.id) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let panel = BrowserPanel(
            workspaceId: workspace.id,
            profileID: popupProfile.id,
            browserServices: services
        )
        services.registerBrowserPanel(panel, workspace: workspace)
        defer {
            services.unregisterBrowserPanel(id: panel.id)
            panel.close()
        }
        let popupManager = services.webExtensionsManager(for: popupProfile.id)
        let popup = BrowserPopupWindowController(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures(),
            browserContext: panel.popupBrowserContext,
            openerPanel: panel
        )

        #expect(panel.switchToProfile(BrowserProfileStore.shared.builtInDefaultProfileID))
        #expect(services.hasRetainedWebExtensionsManagerForTesting(profileID: popupProfile.id))
        #expect(!popupManager.isShutDown)

        popup.closePopup()
        for _ in 0..<4 { await Task.yield() }

        #expect(!services.hasRetainedWebExtensionsManagerForTesting(profileID: popupProfile.id))
        #expect(popupManager.isShutDown)
    }

    @available(macOS 15.4, *)
    @Test func newerNavigationCancelsDeferredStartupNavigation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let profileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let loadGate = RuntimeLoadGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        runtime.start { await loadGate.wait() }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID,
            profileRuntime: runtime
        )
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let panel = BrowserPanel(workspaceId: UUID(), browserServices: services)
        defer { panel.close() }
        var deferredNavigationCount = 0

        panel.runWhenWebExtensionsLoaded {
            deferredNavigationCount += 1
        }
        panel.navigate(to: try #require(URL(string: "https://example.com/newer")))
        loadGate.resume()
        for _ in 0..<4 { await Task.yield() }

        #expect(deferredNavigationCount == 0)
    }

    @available(macOS 15.4, *)
    @Test func browserServicesExecutesOnlyLatestNavigationAndHonorsCancellation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let loadGate = RuntimeLoadGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        runtime.start { await loadGate.wait() }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID,
            profileRuntime: runtime
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let ownerID = UUID()
        var executions: [Int] = []

        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/old"),
            reason: .initial
        ) { executions.append(1) }
        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/latest"),
            reason: .userInitiated
        ) { executions.append(2) }
        loadGate.resume()
        for await update in runtime.updates() {
            if update == .phaseChanged(.ready) { break }
        }
        for _ in 0..<20 where services.isWebExtensionNavigationPending(ownerID: ownerID) {
            await Task.yield()
        }
        #expect(executions == [2])

        runtime.start { await loadGate.wait() }
        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/cancelled"),
            reason: .restore
        ) { executions.append(3) }
        services.cancelWebExtensionNavigation(ownerID: ownerID)
        loadGate.resume()
        for await update in runtime.updates() {
            if update == .phaseChanged(.ready) { break }
        }
        await Task.yield()
        #expect(executions == [2])
    }

    @available(macOS 15.4, *)
    @Test func browserServicesReleasesAtDeadlineWithoutLateReplayAndRecovers() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let loadGate = RuntimeLoadGate()
        let deadlineGate = RuntimeDeadlineGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await deadlineGate.wait() }
        )
        runtime.start { await loadGate.wait() }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID,
            profileRuntime: runtime
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let ownerID = UUID()
        var executionCount = 0
        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/degraded"),
            reason: .initial
        ) { executionCount += 1 }

        deadlineGate.resume()
        for await update in runtime.updates() {
            if update == .phaseChanged(.degraded(.loadDeadlineExceeded)) { break }
        }
        for _ in 0..<20 where executionCount == 0 { await Task.yield() }
        #expect(executionCount == 1)

        loadGate.resume()
        runtime.start { .ready }
        for await update in runtime.updates() {
            if update == .phaseChanged(.ready) { break }
        }
        await Task.yield()
        #expect(executionCount == 1)

        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/recovered"),
            reason: .recovery
        ) { executionCount += 1 }
        for _ in 0..<20 where executionCount == 1 { await Task.yield() }
        #expect(executionCount == 2)
    }

    @available(macOS 15.4, *)
    @Test func extensionTabOrderAndIndicesFollowVisibleWorkspaceOrder() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = try Self.writeExtension(
            named: "tab-order",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: extensionDirectory)
        )
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let managerPage = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        managerPage.showBrowserExtensionsManager()
        let second = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let secondTabID = try #require(workspace.surfaceIdFromPanelId(second.id))
        #expect(workspace.bonsplitController.reorderTab(secondTabID, toIndex: 0))

        let manager = try #require(services.webExtensionsManager)
        let window = try #require(manager
            .webExtensionController(manager.controller, openWindowsFor: extensionContext)
            .first { window in
                (window.tabs?(for: extensionContext) ?? []).contains {
                    $0.webView?(for: extensionContext) === first.webView
                }
            })
        let visibleTabs = window.tabs?(for: extensionContext) ?? []
        #expect(visibleTabs.compactMap { $0.webView?(for: extensionContext) } == [second.webView, first.webView])
        let secondAdapter = try #require(visibleTabs.first as? BrowserWebExtensionTabAdapter)
        let firstAdapter = try #require(visibleTabs.last as? BrowserWebExtensionTabAdapter)
        #expect(secondAdapter.indexInWindow(for: extensionContext) == 0)
        #expect(firstAdapter.indexInWindow(for: extensionContext) == 1)

        workspace.focusPanel(managerPage.id)
        #expect(window.activeTab?(for: extensionContext) == nil)
    }

    @available(macOS 15.4, *)
    @Test func managerPaneReturnsToExtensionTabRegistryAfterNavigation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = try Self.writeExtension(
            named: "manager-registry",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: extensionDirectory)
        )
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let source = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let manager = try #require(services.webExtensionsManager)
        let openEventsBeforeManagerPage = manager.debugDidOpenTabEventCount
        let closeEventsBeforeManagerPage = manager.debugDidCloseTabEventCount
        let managerPage = try #require(workspace.openBrowserExtensionsManager(from: source.id))
        #expect(manager.debugDidOpenTabEventCount == openEventsBeforeManagerPage)
        #expect(manager.debugDidCloseTabEventCount == closeEventsBeforeManagerPage)

        let registeredWebViews = {
            manager.webExtensionController(manager.controller, openWindowsFor: extensionContext)
                .flatMap { $0.tabs?(for: extensionContext) ?? [] }
                .compactMap { $0.webView?(for: extensionContext) }
        }
        #expect(!registeredWebViews().contains(managerPage.webView))

        managerPage.navigate(to: try #require(URL(string: "https://example.com")))

        #expect(registeredWebViews().contains(managerPage.webView))
        #expect(manager.debugDidOpenTabEventCount == openEventsBeforeManagerPage + 1)
        #expect(manager.debugDidCloseTabEventCount == closeEventsBeforeManagerPage)
    }

    @available(macOS 15.4, *)
    @Test func rejectedBrowserTabCreationDoesNotRegisterOrRetainPanel() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let originalPanelCount = workspace.panels.count
        let rejectingDelegate = RejectingCreateTabDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate

        let created = workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        )

        #expect(created == nil)
        #expect(workspace.panels.count == originalPanelCount)
        #expect(services.registeredBrowserPanelCount == 0)
    }

    @available(macOS 15.4, *)
    @Test func rejectedManagerSplitKeepsOnlySourcePanelRegistered() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let source = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let originalPanelCount = workspace.panels.count
        #expect(services.registeredBrowserPanelCount == 1)
        let rejectingDelegate = RejectingSplitPaneDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate

        let manager = workspace.openBrowserExtensionsManager(from: source.id)

        #expect(manager == nil)
        #expect(workspace.panels.count == originalPanelCount)
        #expect(services.registeredBrowserPanelCount == 1)
    }

    @available(macOS 15.4, *)
    @Test func extensionControllerReportsNoFocusedWindowWithoutAKeyCmuxWindow() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "focus-probe",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: directory)
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }

        #expect(manager.webExtensionController(
            manager.controller,
            focusedWindowFor: extensionContext
        ) == nil)
    }

    @available(macOS 15.4, *)
    @Test func extensionControllerPrefersTheAuthoritativeFocusedOwner() {
        let manager = BrowserWebExtensionsManager(
            directory: FileManager.default.temporaryDirectory,
            controllerConfiguration: .nonPersistent()
        )
        let fallbackOwnerID = UUID()
        let focusedOwnerID = UUID()
        let fallbackPanel = BrowserPanel(workspaceId: fallbackOwnerID)
        let focusedPanel = BrowserPanel(workspaceId: focusedOwnerID)
        defer {
            manager.unregister(panelID: fallbackPanel.id)
            manager.unregister(panelID: focusedPanel.id)
            fallbackPanel.close()
            focusedPanel.close()
        }
        manager.register(
            panel: fallbackPanel,
            ownerID: fallbackOwnerID,
            activePanelID: { fallbackPanel.id },
            focusPriority: { 1 },
            focusPanel: { _ in }
        )
        manager.register(
            panel: focusedPanel,
            ownerID: focusedOwnerID,
            activePanelID: { focusedPanel.id },
            focusPriority: { 2 },
            focusPanel: { _ in }
        )

        #expect(manager.debugPreferredFocusedWindowOwnerID == focusedOwnerID)
    }

    @available(macOS 15.4, *)
    @Test func unregisterAndRemovalClearEveryTransientExtensionReference() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Self.writeExtension(
            named: "transient-cleanup",
            in: root,
            manifest: Self.minimalManifest.merging([
                "action": ["default_title": "Cleanup"]
            ]) { _, new in new }
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(source)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        var retainedFixture: (popover: NSPopover, webView: WKWebView)? =
            manager.seedTransientStateForTesting(
                panelID: panel.id,
                extensionIdentifier: context.uniqueIdentifier,
                context: context
            )
        #expect(manager.transientStateCountsForTesting(
            panelID: panel.id,
            extensionIdentifier: context.uniqueIdentifier
        ).total == 12)

        manager.unregister(panelID: panel.id)

        #expect(manager.transientStateCountsForTesting(
            panelID: panel.id,
            extensionIdentifier: context.uniqueIdentifier
        ).total == 0)
        retainedFixture = manager.seedTransientStateForTesting(
            panelID: panel.id,
            extensionIdentifier: context.uniqueIdentifier,
            context: context
        )
        #expect(retainedFixture?.popover != nil)

        try await manager.removeExtension(managementID: source.lastPathComponent)

        #expect(manager.transientStateCountsForTesting(
            panelID: panel.id,
            extensionIdentifier: context.uniqueIdentifier
        ).total == 0)
        retainedFixture = nil
    }

    @available(macOS 15.4, *)
    @Test func removeThenReinstallStartsWithFreshExtensionOwnedState() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(
            named: "remove-reinstall-state",
            in: sourceRoot,
            manifest: [
                "manifest_version": 3,
                "name": "Remove reinstall state fixture",
                "version": "1.0",
                "permissions": ["storage", "declarativeNetRequest"],
                "optional_permissions": ["cookies", "history"],
                "action": ["default_title": "State fixture"],
            ]
        )
        try "<title>Remove reinstall state fixture</title>".write(
            to: source.appendingPathComponent("probe.html"),
            atomically: true,
            encoding: .utf8
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerIdentifier: UUID(),
            directoryRepository: repository,
            permissionPromptPresenter: { request, _ in
                request.permissions.contains(WKWebExtension.Permission.history.rawValue)
                    ? .deny
                    : .grant
            }
        )
        defer { manager.shutdown() }

        _ = try await manager.installExtension(from: source)
        let oldRecord = try #require(
            try await repository.managementLedger(in: managedRoot).records.values.first
        )
        let oldContext = try #require(manager.loadedContexts.first)
        try await manager.setToolbarActionPinned(
            true,
            uniqueIdentifier: oldContext.uniqueIdentifier
        )
        let grantedCookies = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissions: [.cookies],
                in: nil,
                for: oldContext
            ) { permissions, _ in
                continuation.resume(returning: permissions)
            }
        }
        let deniedHistory = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissions: [.history],
                in: nil,
                for: oldContext
            ) { permissions, _ in
                continuation.resume(returning: permissions)
            }
        }
        #expect(grantedCookies == [.cookies])
        #expect(deniedHistory.isEmpty)
        let stateWebView = try await Self.loadExtensionPage(
            "probe.html",
            context: oldContext,
            manager: manager
        )
        _ = try await stateWebView.callAsyncJavaScript(
            """
            const api = globalThis.browser ?? globalThis.chrome;
            await api.storage.local.set({ removalMarker: 'stale' });
            await api.declarativeNetRequest.updateDynamicRules({
              addRules: [{
                id: 991,
                priority: 1,
                action: { type: 'block' },
                condition: {
                  urlFilter: 'cmux-remove-reinstall-stale',
                  resourceTypes: ['xmlhttprequest'],
                },
              }],
            });
            return true;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let populatedRecord = try #require(
            try await repository.managementLedger(in: managedRoot).records[oldRecord.id]
        )
        #expect(populatedRecord.isToolbarPinned)
        #expect(
            populatedRecord.grantedPermissions[
                WKWebExtension.Permission.cookies.rawValue
            ] != nil
        )
        #expect(
            populatedRecord.deniedPermissions[
                WKWebExtension.Permission.history.rawValue
            ] != nil
        )
        let oldDataRecords = await manager.controller.dataRecords(
            ofTypes: WKWebExtensionController.allExtensionDataTypes
        )
        #expect(oldDataRecords.contains { $0.uniqueIdentifier == oldContext.uniqueIdentifier })

        try await manager.removeExtension(managementID: oldRecord.id)

        #expect(try await repository.managementLedger(in: managedRoot).records.isEmpty)
        #expect(manager.loadedContexts.isEmpty)
        let remainingDataRecords = await manager.controller.dataRecords(
            ofTypes: WKWebExtensionController.allExtensionDataTypes
        )
        #expect(!remainingDataRecords.contains { $0.uniqueIdentifier == oldContext.uniqueIdentifier })

        _ = try await manager.installExtension(from: source)
        let newRecord = try #require(
            try await repository.managementLedger(in: managedRoot).records.values.first
        )
        let newContext = try #require(manager.loadedContexts.first)
        #expect(newRecord.id != oldRecord.id)
        #expect(newContext !== oldContext)
        #expect(newContext.uniqueIdentifier != oldContext.uniqueIdentifier)
        #expect(!newRecord.isToolbarPinned)
        #expect(
            newRecord.grantedPermissions[
                WKWebExtension.Permission.cookies.rawValue
            ] == nil
        )
        #expect(
            newRecord.deniedPermissions[
                WKWebExtension.Permission.history.rawValue
            ] == nil
        )
        let freshStateWebView = try await Self.loadExtensionPage(
            "probe.html",
            context: newContext,
            manager: manager
        )
        let freshState = try await freshStateWebView.callAsyncJavaScript(
            """
            const api = globalThis.browser ?? globalThis.chrome;
            const storage = await api.storage.local.get('removalMarker');
            const dynamicRules = await api.declarativeNetRequest.getDynamicRules();
            return {
              hasStorageMarker: Object.hasOwn(storage, 'removalMarker'),
              dynamicRuleCount: dynamicRules.length,
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let freshValues = try #require(freshState as? [String: Any])
        #expect((freshValues["hasStorageMarker"] as? NSNumber)?.boolValue == false)
        #expect((freshValues["dynamicRuleCount"] as? NSNumber)?.intValue == 0)
    }

    @available(macOS 15.4, *)
    @Test func lastPanelReleasesNonDefaultRuntimeButKeepsDefaultRuntime() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension lifetime \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: profile.id) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let alternatePanel = BrowserPanel(
            workspaceId: workspace.id,
            profileID: profile.id,
            browserServices: services
        )
        services.registerBrowserPanel(alternatePanel, workspace: workspace)
        var alternateManager: BrowserWebExtensionsManager? = services.webExtensionsManager(
            for: profile.id
        )
        weak var weakAlternateManager = alternateManager
        #expect(services.hasRetainedWebExtensionsManagerForTesting(profileID: profile.id))

        services.unregisterBrowserPanel(id: alternatePanel.id)
        alternatePanel.close()

        #expect(alternateManager?.isShutDown == true)
        #expect(!services.hasRetainedWebExtensionsManagerForTesting(profileID: profile.id))
        alternateManager = nil
        #expect(weakAlternateManager == nil)

        let defaultPanel = BrowserPanel(
            workspaceId: workspace.id,
            browserServices: services
        )
        services.registerBrowserPanel(defaultPanel, workspace: workspace)
        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let defaultManager = try #require(services.webExtensionsManager)
        services.unregisterBrowserPanel(id: defaultPanel.id)
        defaultPanel.close()

        #expect(!defaultManager.isShutDown)
        #expect(services.hasRetainedWebExtensionsManagerForTesting(profileID: defaultProfileID))
    }

    @available(macOS 15.4, *)
    @Test func deletingProfileReleasesItsExtensionRuntime() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension teardown \(UUID().uuidString.prefix(6))"
        ))
        let services = BrowserServices(extensionDirectory: root)
        var manager: BrowserWebExtensionsManager? = services.webExtensionsManager(for: profile.id)
        weak var weakManager = manager
        manager = nil

        #expect(BrowserProfileStore.shared.deleteProfile(id: profile.id) != nil)
        for _ in 0..<8 { await Task.yield() }

        #expect(weakManager == nil)
    }

    @Test func deletingUnloadedProfileRemovesExtensionDirectoryOffMain() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension cleanup \(UUID().uuidString.prefix(6))"
        ))
        let removalState = OSAllocatedUnfairLock(
            initialState: (didRun: false, ranOnMainThread: false)
        )
        let services = BrowserServices(
            extensionDirectory: root,
            extensionDirectoryRemover: { _ in
                removalState.withLock { state in
                    state = (didRun: true, ranOnMainThread: Thread.isMainThread)
                }
            }
        )

        #expect(BrowserProfileStore.shared.deleteProfile(id: profile.id) != nil)
        for _ in 0..<200 {
            if removalState.withLock({ $0.didRun }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = removalState.withLock { $0 }
        #expect(result.didRun)
        #expect(!result.ranOnMainThread)
        withExtendedLifetime(services) {}
    }

    @available(macOS 15.4, *)
    @Test func shutdownIsTerminalForExtensionLoadingAndInstallation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try Self.writeExtension(
            named: "shutdown-probe",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )

        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        manager.shutdown()

        await manager.loadExtensions()
        await #expect(throws: CancellationError.self) {
            _ = try await manager.installExtension(from: source)
        }

        #expect(manager.loadedContexts.isEmpty)
        #expect(BrowserWebExtensionsManager.candidateURLs(in: root).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func actionMutationsCoalesceIntoTypedToolbarUpdateWithoutTimerSynchronization() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Action probe"]
        let directory = try Self.writeExtension(named: "action-probe", in: root, manifest: manifest)
        let context = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: directory)
        )
        context.uniqueIdentifier = "cmux-action-probe"
        let action = try #require(context.action(for: nil))
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        let updates = manager.profileRuntime.updates()
        let collector = Task { @MainActor in
            for await update in updates {
                if case .actionChanged(let actionUpdate) = update,
                   let item = actionUpdate.item {
                    return [item]
                }
            }
            return []
        }

        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        let items = await collector.value
        #expect(items.count == 1)
        #expect(items.allSatisfy { $0.id == context.uniqueIdentifier })
    }

    @available(macOS 15.4, *)
    @Test func actionInvocationDelegatesImmediatelyToTheWebKitPerformer() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["background"] = ["service_worker": "background.js"]
        manifest["action"] = ["default_title": "Background probe"]
        let directory = try Self.writeExtension(
            named: "background-action-probe",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("background.js"),
            atomically: true,
            encoding: .utf8
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )

        let performCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            performExtensionAction: { _, _ in
                performCount.withLock { $0 += 1 }
            }
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }

        let context = try #require(manager.loadedContexts.first)
        #expect(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: nil
        ))
        #expect(performCount.withLock { $0 } == 1)
    }

    @available(macOS 15.4, *)
    @Test func duplicateDisplayNameActionIsAmbiguousWhileExactIdentifierRoutes() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["name"] = "Duplicate action name"
        manifest["action"] = ["default_title": "Duplicate action"]
        for directoryName in ["duplicate-one", "duplicate-two"] {
            let directory = try Self.writeExtension(
                named: directoryName,
                in: root,
                manifest: manifest
            )
            try "// no-op".write(
                to: directory.appendingPathComponent("content.js"),
                atomically: true,
                encoding: .utf8
            )
        }
        let performCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            performExtensionAction: { _, _ in
                performCount.withLock { $0 += 1 }
            }
        )
        for directoryName in ["duplicate-one", "duplicate-two"] {
            try await manager.approveInstalledCandidate(
                root.appendingPathComponent(directoryName, isDirectory: true)
            )
        }
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }

        var rejectedAmbiguousName = false
        do {
            _ = try manager.performAction(
                matching: "Duplicate action name",
                panelID: panel.id
            )
        } catch {
            rejectedAmbiguousName = true
        }
        #expect(rejectedAmbiguousName)
        #expect(performCount.withLock { $0 } == 0)

        let exactContext = try #require(manager.loadedContexts.first)
        let payload = try manager.performAction(
            matching: exactContext.uniqueIdentifier,
            panelID: panel.id
        )
        #expect(payload["extension_id"] as? String == exactContext.uniqueIdentifier)
        #expect(performCount.withLock { $0 } == 1)
    }

    @available(macOS 15.4, *)
    @Test func mv2BackgroundPageMessagesContentScriptOnFirstLoadAndReload() async throws {
        try await Self.assertBackgroundMessagingFixture(manifestVersion: 2)
    }

    @available(macOS 15.4, *)
    @Test func mv3ServiceWorkerActionMessagesContentScriptOnFirstLoadAndReload() async throws {
        try await Self.assertBackgroundMessagingFixture(manifestVersion: 3)
    }

    @available(macOS 15.4, *)
    private static func assertBackgroundMessagingFixture(manifestVersion: Int) async throws {
        let root = try makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ExtensionHTTPFixtureServer(routes: [
            "/probe": ("text/html; charset=utf-8", "<html><body>runtime probe</body></html>"),
        ])
        defer { server.stop() }
        let fixtureKind = manifestVersion == 2 ? "mv2" : "mv3"
        let fixtureName = "\(fixtureKind)-behavior-\(UUID().uuidString)"
        var manifest: [String: Any] = [
            "manifest_version": manifestVersion,
            "name": fixtureName,
            "version": "1.0",
            "content_scripts": [[
                "matches": ["http://127.0.0.1/*"],
                "js": ["content.js"],
            ]],
        ]
        if manifestVersion == 2 {
            manifest["permissions"] = ["storage", "tabs", "http://127.0.0.1/*"]
            manifest["background"] = ["page": "background.html"]
            manifest["browser_action"] = ["default_title": "MV2 behavior probe"]
        } else {
            manifest["permissions"] = ["storage", "tabs"]
            manifest["host_permissions"] = ["http://127.0.0.1/*"]
            manifest["background"] = ["service_worker": "background.js"]
            manifest["action"] = ["default_title": "MV3 behavior probe"]
        }
        let extensionDirectory = try writeExtension(
            named: fixtureName,
            in: root,
            manifest: manifest
        )
        try """
        const api = globalThis.browser ?? globalThis.chrome;
        api.runtime.onMessage.addListener((message, sender) => {
          if (message?.type !== 'cmux-runtime-probe') return undefined;
          return api.storage.local.set({ backgroundKind: '\(fixtureKind)' }).then(() => ({
            kind: '\(fixtureKind)',
            hasTab: Boolean(sender.tab && Number.isInteger(sender.tab.id)),
          }));
        });
        """.write(
            to: extensionDirectory.appendingPathComponent("background.js"),
            atomically: true,
            encoding: .utf8
        )
        if manifestVersion == 2 {
            try "<script src=\"background.js\"></script>".write(
                to: extensionDirectory.appendingPathComponent("background.html"),
                atomically: true,
                encoding: .utf8
            )
        }
        try """
        (async () => {
          const api = globalThis.browser ?? globalThis.chrome;
          const response = await api.runtime.sendMessage({ type: 'cmux-runtime-probe' });
          const stored = await api.storage.local.get('contentRuns');
          const runs = Number(stored.contentRuns || 0) + 1;
          await api.storage.local.set({ contentRuns: runs });
          document.documentElement.dataset.cmuxRuntime =
            `${response.kind}:${response.hasTab}:${runs}`;
        })().catch((error) => {
          document.documentElement.dataset.cmuxRuntime = `error:${String(error)}`;
        });
        """.write(
            to: extensionDirectory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )

        let profileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: profileID,
            browserServices: services
        )
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPriority: { 2 },
            focusPanel: { _ in }
        )
        defer {
            manager.unregister(panelID: panel.id)
            panel.close()
            manager.shutdown()
        }
        try await manager.approveInstalledCandidate(extensionDirectory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let tabs = manager
            .webExtensionController(manager.controller, openWindowsFor: context)
            .flatMap { $0.tabs?(for: context) ?? [] }
        let tab = try #require(tabs.first)
        let action = try #require(context.action(for: tab))
        #expect(action.isEnabled)

        panel.navigate(to: server.url(path: "/probe"))
        try await waitForJavaScriptString(
            "document.documentElement.dataset.cmuxRuntime || ''",
            toEqual: "\(fixtureKind):true:1",
            in: panel.webView
        )
        _ = panel.reload()
        try await waitForJavaScriptString(
            "document.documentElement.dataset.cmuxRuntime || ''",
            toEqual: "\(fixtureKind):true:2",
            in: panel.webView
        )
        #expect(server.requestCount(for: "/probe") == 2)
    }

    @available(macOS 15.4, *)
    @Test func actionPopupMessagesBackgroundAndActiveContentScript() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ExtensionHTTPFixtureServer(routes: [
            "/popup-probe": (
                "text/html; charset=utf-8",
                "<html><body>popup messaging probe</body></html>"
            ),
        ])
        defer { server.stop() }
        let fixtureName = "popup-message-\(UUID().uuidString)"
        let extensionDirectory = try Self.writeExtension(
            named: fixtureName,
            in: root,
            manifest: [
                "manifest_version": 3,
                "name": fixtureName,
                "version": "1.0",
                "permissions": ["tabs"],
                "host_permissions": ["http://127.0.0.1/*"],
                "background": ["service_worker": "background.js"],
                "content_scripts": [[
                    "matches": ["http://127.0.0.1/*"],
                    "js": ["content.js"],
                ]],
                "action": ["default_popup": "popup.html"],
            ]
        )
        try """
        const api = globalThis.browser ?? globalThis.chrome;
        api.runtime.onMessage.addListener(async (message) => {
          if (message?.type !== 'cmux-popup-start') return undefined;
          const tabs = await api.tabs.query({ active: true });
          const target = tabs.find((tab) => /^https?:/.test(tab.url || '')) ?? tabs[0];
          if (!target) return { delivered: false, reason: 'missing-tab' };
          const reply = await api.tabs.sendMessage(target.id, { type: 'cmux-popup-to-content' });
          return { delivered: reply?.ack === 'content' };
        });
        """.write(
            to: extensionDirectory.appendingPathComponent("background.js"),
            atomically: true,
            encoding: .utf8
        )
        try """
        const api = globalThis.browser ?? globalThis.chrome;
        api.runtime.onMessage.addListener((message) => {
          if (message?.type !== 'cmux-popup-to-content') return undefined;
          document.documentElement.dataset.cmuxPopupReceiver = 'delivered';
          return Promise.resolve({ ack: 'content' });
        });
        document.documentElement.dataset.cmuxPopupReceiver = 'ready';
        """.write(
            to: extensionDirectory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<html><body><script src=\"popup.js\"></script></body></html>".write(
            to: extensionDirectory.appendingPathComponent("popup.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        const api = globalThis.browser ?? globalThis.chrome;
        api.runtime.sendMessage({ type: 'cmux-popup-start' }).then((response) => {
          document.documentElement.dataset.cmuxPopup = response?.delivered ? 'delivered' : 'failed';
        }).catch((error) => {
          document.documentElement.dataset.cmuxPopup = `error:${String(error)}`;
        });
        """.write(
            to: extensionDirectory.appendingPathComponent("popup.js"),
            atomically: true,
            encoding: .utf8
        )

        let profileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: profileID,
            browserServices: services
        )
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPriority: { 2 },
            focusPanel: { _ in }
        )
        defer {
            manager.unregister(panelID: panel.id)
            panel.close()
            manager.shutdown()
        }
        try await manager.approveInstalledCandidate(extensionDirectory)
        await manager.loadExtensions()

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 720, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentLayoutRect)
        panel.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 470)
        host.addSubview(panel.webView)
        let anchor = NSButton(frame: NSRect(x: 640, y: 480, width: 40, height: 24))
        host.addSubview(anchor)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        manager.activateTab(panelID: panel.id, previousPanelID: nil)

        panel.navigate(to: server.url(path: "/popup-probe"))
        try await Self.waitForJavaScriptString(
            "document.documentElement.dataset.cmuxPopupReceiver || ''",
            toEqual: "ready",
            in: panel.webView
        )
        let context = try #require(manager.loadedContexts.first)
        let tabs = manager
            .webExtensionController(manager.controller, openWindowsFor: context)
            .flatMap { $0.tabs?(for: context) ?? [] }
        let tab = try #require(tabs.first)
        let action = try #require(context.action(for: tab))

        #expect(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: anchor
        ))
        try await Self.waitUntil("action popup presentation") {
            action.popupPopover?.isShown == true && action.popupWebView != nil
        }
        let popupWebView = try #require(action.popupWebView)
        try await Self.waitForJavaScriptString(
            "document.documentElement.dataset.cmuxPopup || ''",
            toEqual: "delivered",
            in: popupWebView
        )
        try await Self.waitForJavaScriptString(
            "document.documentElement.dataset.cmuxPopupReceiver || ''",
            toEqual: "delivered",
            in: panel.webView
        )
        action.popupPopover?.performClose(nil)
        for _ in 0..<4 { await Task.yield() }
        #expect(action.popupPopover?.isShown != true)
    }

    @available(macOS 15.4, *)
    @Test func browserStorageLocalPersistsWhileSessionClearsAndBothRemainProfileIsolated() async throws {
        let firstRoot = try Self.makeExtensionsRoot()
        let secondRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let firstExtension = try Self.writeStorageBehaviorExtension(in: firstRoot)
        let secondExtension = try Self.writeStorageBehaviorExtension(in: secondRoot)
        let firstControllerID = UUID()
        let secondControllerID = UUID()

        try await Self.setStorageBehaviorValues(
            marker: "first-profile",
            extensionDirectory: firstExtension,
            root: firstRoot,
            controllerID: firstControllerID
        )
        try await Self.setStorageBehaviorValues(
            marker: "second-profile",
            extensionDirectory: secondExtension,
            root: secondRoot,
            controllerID: secondControllerID
        )

        let firstValues = try await Self.readStorageBehaviorValues(
            root: firstRoot,
            controllerID: firstControllerID
        )
        let secondValues = try await Self.readStorageBehaviorValues(
            root: secondRoot,
            controllerID: secondControllerID
        )
        #expect(firstValues.local == "first-profile")
        #expect(secondValues.local == "second-profile")
        #expect(firstValues.session == nil)
        #expect(secondValues.session == nil)
    }

    @available(macOS 15.4, *)
    private static func writeStorageBehaviorExtension(in root: URL) throws -> URL {
        let directory = try writeExtension(
            named: "storage-behavior",
            in: root,
            manifest: [
                "manifest_version": 3,
                "name": "Storage behavior fixture",
                "version": "1.0",
                "permissions": ["storage"],
            ]
        )
        try "<html><body>storage behavior</body></html>".write(
            to: directory.appendingPathComponent("probe.html"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    @available(macOS 15.4, *)
    private static func setStorageBehaviorValues(
        marker: String,
        extensionDirectory: URL,
        root: URL,
        controllerID: UUID
    ) async throws {
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerIdentifier: controllerID
        )
        try await manager.approveInstalledCandidate(extensionDirectory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let webView = try await loadExtensionPage(
            "probe.html",
            context: context,
            manager: manager
        )
        let result = try await webView.callAsyncJavaScript(
            """
            const api = globalThis.browser ?? globalThis.chrome;
            await api.storage.local.set({ profileMarker: marker });
            await api.storage.session.set({ sessionMarker: marker });
            const local = await api.storage.local.get('profileMarker');
            const session = await api.storage.session.get('sessionMarker');
            return {
              local: local.profileMarker ?? null,
              session: session.sessionMarker ?? null,
            };
            """,
            arguments: ["marker": marker],
            in: nil,
            contentWorld: .page
        )
        guard let values = result as? [String: Any],
              values["local"] as? String == marker,
              values["session"] as? String == marker else {
            throw BehaviorFixtureError.invalidJavaScriptResult
        }
        manager.shutdown()
    }

    @available(macOS 15.4, *)
    private static func readStorageBehaviorValues(
        root: URL,
        controllerID: UUID
    ) async throws -> (local: String?, session: String?) {
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerIdentifier: controllerID
        )
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let webView = try await loadExtensionPage(
            "probe.html",
            context: context,
            manager: manager
        )
        let result = try await webView.callAsyncJavaScript(
            """
            const api = globalThis.browser ?? globalThis.chrome;
            const local = await api.storage.local.get('profileMarker');
            const session = await api.storage.session.get('sessionMarker');
            return {
              local: local.profileMarker ?? null,
              session: session.sessionMarker ?? null,
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        manager.shutdown()
        guard let values = result as? [String: Any] else {
            throw BehaviorFixtureError.invalidJavaScriptResult
        }
        return (
            values["local"] as? String,
            values["session"] as? String
        )
    }

    @available(macOS 15.4, *)
    @Test func declarativeRulesPersistUpdateAndRemainProfileIsolated() async throws {
        let firstRoot = try Self.makeExtensionsRoot()
        let secondRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let server = try ExtensionHTTPFixtureServer(routes: [
            "/dnr-probe": ("text/html; charset=utf-8", "<html><body>dnr probe</body></html>"),
            "/control": ("text/plain; charset=utf-8", "control-ok"),
            "/cmux-static-blocked": ("text/plain; charset=utf-8", "static-server"),
            "/cmux-dynamic-blocked": ("text/plain; charset=utf-8", "dynamic-server"),
            "/cmux-updated-blocked": ("text/plain; charset=utf-8", "updated-server"),
        ])
        defer { server.stop() }
        let firstExtension = try Self.writeDNRBehaviorExtension(in: firstRoot)
        let secondExtension = try Self.writeDNRBehaviorExtension(in: secondRoot)
        let firstControllerID = UUID()
        let secondControllerID = UUID()

        try await Self.withDNRBehaviorHarness(
            root: firstRoot,
            controllerID: firstControllerID,
            approving: firstExtension
        ) { manager, panel, context in
            let dynamicRuleIDs = try await Self.updateDynamicDNRRules(
                remove: [],
                add: (id: 900, fragment: "cmux-dynamic-blocked"),
                context: context,
                manager: manager
            )
            #expect(dynamicRuleIDs == [900])
            let responses = try await Self.fetchDNRPaths(
                ["/control", "/cmux-static-blocked", "/cmux-dynamic-blocked"],
                server: server,
                panel: panel
            )
            #expect(responses == ["control-ok", "blocked", "blocked"])
        }

        try await Self.withDNRBehaviorHarness(
            root: secondRoot,
            controllerID: secondControllerID,
            approving: secondExtension
        ) { manager, panel, context in
            let dynamicRuleIDs = try await Self.dynamicDNRRuleIDs(
                context: context,
                manager: manager
            )
            #expect(dynamicRuleIDs.isEmpty)
            let responses = try await Self.fetchDNRPaths(
                ["/cmux-static-blocked", "/cmux-dynamic-blocked"],
                server: server,
                panel: panel
            )
            #expect(responses == ["blocked", "dynamic-server"])
        }

        try await Self.withDNRBehaviorHarness(
            root: firstRoot,
            controllerID: firstControllerID,
            approving: nil
        ) { manager, panel, context in
            let persistedRuleIDs = try await Self.dynamicDNRRuleIDs(
                context: context,
                manager: manager
            )
            #expect(persistedRuleIDs == [900])
            let persistedResponses = try await Self.fetchDNRPaths(
                ["/cmux-static-blocked", "/cmux-dynamic-blocked"],
                server: server,
                panel: panel
            )
            #expect(persistedResponses == ["blocked", "blocked"])
            let updatedRuleIDs = try await Self.updateDynamicDNRRules(
                remove: [900],
                add: (id: 901, fragment: "cmux-updated-blocked"),
                context: context,
                manager: manager
            )
            #expect(updatedRuleIDs == [901])
            let updatedResponses = try await Self.fetchDNRPaths(
                ["/cmux-dynamic-blocked", "/cmux-updated-blocked"],
                server: server,
                panel: panel
            )
            #expect(updatedResponses == ["dynamic-server", "blocked"])
        }

        #expect(server.requestCount(for: "/control") == 1)
        #expect(server.requestCount(for: "/cmux-static-blocked") == 0)
        #expect(server.requestCount(for: "/cmux-dynamic-blocked") == 2)
        #expect(server.requestCount(for: "/cmux-updated-blocked") == 0)
    }

    @available(macOS 15.4, *)
    private static func writeDNRBehaviorExtension(in root: URL) throws -> URL {
        let directory = try writeExtension(
            named: "dnr-behavior",
            in: root,
            manifest: [
                "manifest_version": 3,
                "name": "DNR behavior fixture",
                "version": "1.0",
                "permissions": ["declarativeNetRequest"],
                "host_permissions": ["http://127.0.0.1/*"],
                "background": ["service_worker": "background.js"],
                "declarative_net_request": [
                    "rule_resources": [[
                        "id": "cmux_rules",
                        "enabled": true,
                        "path": "rules.json",
                    ]],
                ],
            ]
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("background.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<html><body>dnr extension probe</body></html>".write(
            to: directory.appendingPathComponent("probe.html"),
            atomically: true,
            encoding: .utf8
        )
        let rules: [[String: Any]] = [[
            "id": 1,
            "priority": 1,
            "action": ["type": "block"],
            "condition": [
                "urlFilter": "cmux-static-blocked",
                "resourceTypes": ["xmlhttprequest"],
            ],
        ]]
        try JSONSerialization.data(withJSONObject: rules).write(
            to: directory.appendingPathComponent("rules.json")
        )
        return directory
    }

    @available(macOS 15.4, *)
    private static func withDNRBehaviorHarness<T>(
        root: URL,
        controllerID: UUID,
        approving extensionDirectory: URL?,
        operation: @MainActor (
            BrowserWebExtensionsManager,
            BrowserPanel,
            WKWebExtensionContext
        ) async throws -> T
    ) async throws -> T {
        let profileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerIdentifier: controllerID,
            profileID: profileID
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: profileID,
            browserServices: services
        )
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer {
            manager.unregister(panelID: panel.id)
            panel.close()
            manager.shutdown()
        }
        if let extensionDirectory {
            try await manager.approveInstalledCandidate(extensionDirectory)
        }
        await manager.loadExtensions()
        #expect(manager.loadErrors.isEmpty)
        return try await operation(manager, panel, try #require(manager.loadedContexts.first))
    }

    @available(macOS 15.4, *)
    private static func dynamicDNRRuleIDs(
        context: WKWebExtensionContext,
        manager: BrowserWebExtensionsManager
    ) async throws -> [Int] {
        let webView = try await loadExtensionPage(
            "probe.html",
            context: context,
            manager: manager
        )
        let result = try await webView.callAsyncJavaScript(
            """
            const api = globalThis.browser ?? globalThis.chrome;
            return (await api.declarativeNetRequest.getDynamicRules())
              .map((rule) => rule.id)
              .sort((left, right) => left - right);
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let numbers = result as? [NSNumber] else {
            throw BehaviorFixtureError.invalidJavaScriptResult
        }
        return numbers.map(\.intValue)
    }

    @available(macOS 15.4, *)
    private static func updateDynamicDNRRules(
        remove ruleIDs: [Int],
        add rule: (id: Int, fragment: String),
        context: WKWebExtensionContext,
        manager: BrowserWebExtensionsManager
    ) async throws -> [Int] {
        let webView = try await loadExtensionPage(
            "probe.html",
            context: context,
            manager: manager
        )
        let result = try await webView.callAsyncJavaScript(
            """
            const api = globalThis.browser ?? globalThis.chrome;
            await api.declarativeNetRequest.updateDynamicRules({
              removeRuleIds: ruleIDs,
              addRules: [{
                id: ruleID,
                priority: 1,
                action: { type: 'block' },
                condition: {
                  urlFilter: fragment,
                  resourceTypes: ['xmlhttprequest'],
                },
              }],
            });
            return (await api.declarativeNetRequest.getDynamicRules())
              .map((item) => item.id)
              .sort((left, right) => left - right);
            """,
            arguments: [
                "ruleIDs": ruleIDs,
                "ruleID": rule.id,
                "fragment": rule.fragment,
            ],
            in: nil,
            contentWorld: .page
        )
        guard let numbers = result as? [NSNumber] else {
            throw BehaviorFixtureError.invalidJavaScriptResult
        }
        return numbers.map(\.intValue)
    }

    @available(macOS 15.4, *)
    private static func fetchDNRPaths(
        _ paths: [String],
        server: ExtensionHTTPFixtureServer,
        panel: BrowserPanel
    ) async throws -> [String] {
        panel.navigate(to: server.url(path: "/dnr-probe"))
        try await waitForJavaScriptString(
            "document.readyState",
            toEqual: "complete",
            in: panel.webView
        )
        let result = try await panel.webView.callAsyncJavaScript(
            """
            return await Promise.all(paths.map(async (path) => {
              try {
                const response = await fetch(path, { cache: 'no-store' });
                return await response.text();
              } catch (_) {
                return 'blocked';
              }
            }));
            """,
            arguments: ["paths": paths],
            in: nil,
            contentWorld: .page
        )
        guard let values = result as? [String] else {
            throw BehaviorFixtureError.invalidJavaScriptResult
        }
        return values
    }

    @available(macOS 15.4, *)
    @Test func noPopupMV2ActionOpensBrowserOnlyWelcomeInNewActiveTab() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = try Self.writeExtension(
            named: "browser-only-welcome",
            in: root,
            manifest: [
                "manifest_version": 2,
                "name": "Browser-only welcome fixture",
                "version": "1.0",
                "permissions": ["tabs"],
                "background": [
                    "page": "background.html",
                ],
                "browser_action": ["default_title": "Open welcome"],
            ]
        )
        try """
        chrome.browserAction.onClicked.addListener(() => {
          chrome.tabs.create({
            active: true,
            url: chrome.runtime.getURL("app/app.html#/page/welcome?language=en")
          });
        });
        """.write(
            to: extensionDirectory.appendingPathComponent("background.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<script src=\"background.js\"></script>".write(
            to: extensionDirectory.appendingPathComponent("background.html"),
            atomically: true,
            encoding: .utf8
        )
        let appDirectory = extensionDirectory.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try "<title>Browser-only welcome</title>".write(
            to: appDirectory.appendingPathComponent("app.html"),
            atomically: true,
            encoding: .utf8
        )

        let profileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        try await manager.approveInstalledCandidate(extensionDirectory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: profileID,
            browserServices: services
        )
        let ownerID = UUID()
        let newTabGate = NewTabGate()
        var activePanelID: UUID? = panel.id
        var createdPanels: [BrowserPanel] = []
        var createRequests: [(index: Int, active: Bool, selected: Bool)] = []
        manager.register(
            panel: panel,
            ownerID: ownerID,
            activePanelID: { activePanelID },
            focusPriority: { 2 },
            focusPanel: { activePanelID = $0 },
            orderedPanelIDs: { [panel.id] + createdPanels.map(\.id) },
            createTab: { index, shouldBeActive, shouldAddToSelection in
                createRequests.append((index, shouldBeActive, shouldAddToSelection))
                let created = BrowserPanel(
                    workspaceId: panel.workspaceId,
                    profileID: profileID,
                    browserServices: services
                )
                createdPanels.append(created)
                manager.register(
                    panel: created,
                    ownerID: ownerID,
                    activePanelID: { activePanelID },
                    focusPanel: { activePanelID = $0 }
                )
                if shouldBeActive { activePanelID = created.id }
                newTabGate.resume(returning: created)
                return created
            },
            closePanel: { panelID in
                guard let index = createdPanels.firstIndex(where: { $0.id == panelID }) else {
                    return false
                }
                let removed = createdPanels.remove(at: index)
                manager.unregister(panelID: removed.id)
                removed.close()
                return true
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = panel.webView
        window.makeKeyAndOrderFront(nil)
        manager.activateTab(panelID: panel.id, previousPanelID: nil)
        defer {
            window.close()
            for created in createdPanels {
                manager.unregister(panelID: created.id)
                created.close()
            }
            manager.unregister(panelID: panel.id)
            panel.close()
            manager.shutdown()
        }

        let backgroundError = await withCheckedContinuation { continuation in
            context.loadBackgroundContent { error in
                continuation.resume(returning: error)
            }
        }
        if let backgroundError { throw backgroundError }

        try #require(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: nil
        ))
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            newTabGate.resume(returning: nil)
        }
        let resolvedPanel = await newTabGate.wait()
        timeoutTask.cancel()
        let created = try #require(resolvedPanel)
        let request = try #require(createRequests.first)
        #expect(request.active)
        #expect(activePanelID == created.id)
        #expect(created.webView.configuration.webExtensionController === manager.controller)

        let openedURL = created.currentURLForTabDuplication
            ?? created.pendingURLForWebExtension
        let url = try #require(openedURL)
        #expect(url.path == "/app/app.html")
        #expect(url.fragment == "/page/welcome?language=en")
        #expect(url.scheme == context.baseURL.scheme)
        #expect(url.host == context.baseURL.host)

        let item = try #require(manager.presentationSnapshot(for: panel.id).extensions.first)
        #expect(item.actionFailure == nil)
    }

    @available(macOS 15.4, *)
    @Test func staleTabActionSurfacesVisibleUnavailableFailure() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Stale tab probe"]
        let directory = try Self.writeExtension(
            named: "stale-tab-action-probe",
            in: root,
            manifest: manifest
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        let context = try #require(manager.loadedContexts.first)

        manager.unregister(panelID: panel.id)
        #expect(!manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: nil
        ))

        let item = try #require(manager.presentationSnapshot(for: panel.id).extensions.first)
        #expect(item.actionFailure == .actionUnavailable)
        #expect(!item.isAwaitingPopup)
    }

    @available(macOS 15.4, *)
    @Test func popupWaitsForWebKitReadyCallbackAndPresentsOnceFromUserAnchor() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_popup": "popup.html"]
        let directory = try Self.writeExtension(
            named: "direct-popup-probe",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<main>Popup ready</main>".write(
            to: directory.appendingPathComponent("popup.html"),
            atomically: true,
            encoding: .utf8
        )

        let performCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            performExtensionAction: { _, _ in
                performCount.withLock { $0 += 1 }
            }
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = NSButton(frame: NSRect(x: 20, y: 20, width: 40, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.close() }

        let context = try #require(manager.loadedContexts.first)
        let openWindows = manager.webExtensionController(
            manager.controller,
            openWindowsFor: context
        )
        let openTabs = openWindows.flatMap { window in
            window.tabs?(for: context) ?? []
        }
        let tab = try #require(openTabs.first)
        let action = try #require(context.action(for: tab))
        let popover = try #require(action.popupPopover)

        #expect(!popover.isShown)
        #expect(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: anchor
        ))
        #expect(performCount.withLock { $0 } == 1)
        #expect(!popover.isShown)

        var presentationError: (any Error)?
        manager.webExtensionController(
            manager.controller,
            presentActionPopup: action,
            for: context
        ) { error in
            presentationError = error
        }

        #expect(presentationError == nil)
        #expect(popover.isShown)
        #expect(popover.positioningRect == anchor.bounds)
        #expect(performCount.withLock { $0 } == 1)
    }

    @available(macOS 15.4, *)
    @Test func unregisteringPanelClosesShownPopupBeforeReleasingItsWebKitAdapters() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_popup": "popup.html"]
        let directory = try Self.writeExtension(
            named: "popup-unregister-probe",
            in: root,
            manifest: manifest
        )
        try "<main>Popup teardown</main>".write(
            to: directory.appendingPathComponent("popup.html"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        defer {
            manager.shutdown()
            panel.close()
        }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = NSButton(frame: NSRect(x: 120, y: 160, width: 40, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.close() }

        let context = try #require(manager.loadedContexts.first)
        let tabs = manager
            .webExtensionController(manager.controller, openWindowsFor: context)
            .flatMap { $0.tabs?(for: context) ?? [] }
        let tab = try #require(tabs.first)
        let action = try #require(context.action(for: tab))
        #expect(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: anchor
        ))
        manager.webExtensionController(
            manager.controller,
            presentActionPopup: action,
            for: context
        ) { error in
            #expect(error == nil)
        }
        let popover = try #require(action.popupPopover)
        #expect(popover.isShown)

        manager.unregister(panelID: panel.id)

        #expect(!popover.isShown)
        for _ in 0..<4 { await Task.yield() }
        #expect(manager.transientStateCountsForTesting(
            panelID: panel.id,
            extensionIdentifier: context.uniqueIdentifier
        ).total == 0)
    }

    @available(macOS 15.4, *)
    @Test func movingShownPopupTabToNewOwnerPreservesItsAdapterUntilClose() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_popup": "popup.html"]
        let directory = try Self.writeExtension(
            named: "popup-owner-move-probe",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<main>Popup owner move</main>".write(
            to: directory.appendingPathComponent("popup.html"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()
        manager.register(
            panel: panel,
            ownerID: firstOwnerID,
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer {
            manager.unregister(panelID: panel.id)
            manager.shutdown()
            panel.close()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = NSButton(frame: NSRect(x: 120, y: 160, width: 40, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.close() }

        let context = try #require(manager.loadedContexts.first)
        let tabs = manager
            .webExtensionController(manager.controller, openWindowsFor: context)
            .flatMap { $0.tabs?(for: context) ?? [] }
        let tab = try #require(tabs.first)
        let action = try #require(context.action(for: tab))
        #expect(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: anchor
        ))
        manager.webExtensionController(
            manager.controller,
            presentActionPopup: action,
            for: context
        ) { error in
            #expect(error == nil)
        }
        let popover = try #require(action.popupPopover)
        #expect(popover.isShown)

        manager.register(
            panel: panel,
            ownerID: secondOwnerID,
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )

        #expect(manager.registrationOwner(for: panel.id)?.id == secondOwnerID)
        #expect(popover.isShown)
        let normalWindows = manager
            .webExtensionController(manager.controller, openWindowsFor: context)
            .compactMap { $0 as? BrowserWebExtensionWindowAdapter }
        #expect(normalWindows.map(\.ownerID) == [secondOwnerID])

        popover.performClose(nil)
        for _ in 0..<4 { await Task.yield() }
        #expect(!popover.isShown)
    }

    @available(macOS 15.4, *)
    @Test func mv2DefaultActionUpdateHandsPendingClickToDynamicPopupExactlyOnce() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "mv2-dynamic-popup",
            in: root,
            manifest: [
                "manifest_version": 2,
                "name": "Dynamic popup fixture",
                "version": "1.0",
                "browser_action": ["default_popup": "popup.html"],
            ]
        )
        try "<main>Dynamic popup ready</main>".write(
            to: directory.appendingPathComponent("popup.html"),
            atomically: true,
            encoding: .utf8
        )

        let performCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            performExtensionAction: { _, _ in
                performCount.withLock { $0 += 1 }
            }
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = NSButton(frame: NSRect(x: 120, y: 160, width: 40, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.close() }

        let openWindows = manager.webExtensionController(
            manager.controller,
            openWindowsFor: context
        )
        let openTabs = openWindows.flatMap { window in
            window.tabs?(for: context) ?? []
        }
        let tab = try #require(openTabs.first)
        let defaultUpdatedAction = try #require(context.action(for: nil))
        #expect(defaultUpdatedAction.associatedTab == nil)
        manager.seedPendingActionInvocationForTesting(
            panelID: panel.id,
            extensionIdentifier: context.uniqueIdentifier,
            anchorView: anchor
        )
        manager.webExtensionController(
            manager.controller,
            didUpdate: defaultUpdatedAction,
            forExtensionContext: context
        )
        manager.webExtensionController(
            manager.controller,
            didUpdate: defaultUpdatedAction,
            forExtensionContext: context
        )
        #expect(performCount.withLock { $0 } == 1)

        let updatedAction = try #require(context.action(for: tab))
        #expect(updatedAction.presentsPopup)
        var presentationError: (any Error)?
        manager.webExtensionController(
            manager.controller,
            presentActionPopup: updatedAction,
            for: context
        ) { presentationError = $0 }

        #expect(presentationError == nil)
        let updatedPopover = try #require(updatedAction.popupPopover)
        defer { updatedPopover.performClose(nil) }
        #expect(updatedPopover.isShown)
        #expect(updatedPopover.positioningRect == anchor.bounds)
        #expect(performCount.withLock { $0 } == 1)

        manager.webExtensionController(
            manager.controller,
            didUpdate: defaultUpdatedAction,
            forExtensionContext: context
        )
        #expect(performCount.withLock { $0 } == 1)
    }

    @available(macOS 15.4, *)
    @Test func nativeInstallTargetsRequestedProfileDirectory() async throws {
        let managedRoot = try Self.makeExtensionsRoot()
        let sourceRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: managedRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = try Self.writeExtension(
            named: "profile-install",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let services = BrowserServices(extensionDirectory: managedRoot)
        let profileID = UUID()

        let preview = try await services.prepareWebExtensionInstall(
            from: source,
            profileID: profileID
        )
        _ = try await services.confirmPreparedWebExtensionInstall(
            id: preview.id,
            grantedOptionalPermissions: [],
            grantedOptionalHosts: [],
            profileID: profileID
        )

        let profileDirectory = BrowserServices.extensionDirectory(
            for: profileID,
            defaultProfileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            root: managedRoot
        )
        let ledger = try await BrowserWebExtensionDirectoryRepository()
            .managementLedger(in: profileDirectory)
        let record = try #require(ledger.records[source.lastPathComponent])
        guard case .directory(let filename, _) = record.source else {
            Issue.record("Expected an immutable managed directory")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: profileDirectory.appendingPathComponent(filename).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: managedRoot.appendingPathComponent(source.lastPathComponent).path
        ))
        #expect(services.webExtensionsManager(for: profileID).directory == profileDirectory)
    }

    @available(macOS 15.4, *)
    @Test func replacementWebViewPreservesInjectedController() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let panel = BrowserPanel(workspaceId: UUID(), browserServices: services)

        let replacement = panel.makeReplacementWebView(
            profileID: panel.profileID,
            websiteDataStore: .nonPersistent()
        )

        #expect(replacement.configuration.webExtensionController === services.webExtensionsManager?.controller)
    }

    @available(macOS 15.4, *)
    @Test func dockBrowserUsesDockWindowOwnershipAndUnregisters() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let services = BrowserServices(extensionDirectory: root)
        let manager = try #require(services.webExtensionsManager)
        let extensionContext = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: directory))
        let store = DockSplitStore(
            workspaceId: UUID(),
            browserServices: services,
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let firstPanelID = try #require(store.newSurface(
            kind: .browser,
            inPane: rootPane,
            url: URL(string: "https://example.com"),
            focus: false
        ))
        let secondPanelID = try #require(store.newSurface(
            kind: .browser,
            inPane: rootPane,
            url: URL(string: "https://example.com/second"),
            focus: false
        ))
        let firstPanel = try #require(store.browserPanel(for: firstPanelID))
        let secondPanel = try #require(store.browserPanel(for: secondPanelID))
        store.focusPanel(firstPanelID)

        let windows = manager.webExtensionController(manager.controller, openWindowsFor: extensionContext)
        let dockWindow = try #require(windows.first(where: { window in
            (window.tabs?(for: extensionContext) ?? []).contains {
                $0.webView?(for: extensionContext) === firstPanel.webView
            }
        }))
        let registeredTabs = dockWindow.tabs?(for: extensionContext) ?? []
        #expect(registeredTabs.contains { $0.webView?(for: extensionContext) === firstPanel.webView })
        #expect(registeredTabs.contains { $0.webView?(for: extensionContext) === secondPanel.webView })
        #expect(dockWindow.activeTab?(for: extensionContext)?.webView?(for: extensionContext) === firstPanel.webView)

        let secondTab = try #require(registeredTabs.first {
            $0.webView?(for: extensionContext) === secondPanel.webView
        })
        let secondTabAdapter = try #require(secondTab as? BrowserWebExtensionTabAdapter)
        await confirmation("Dock-owned extension tab activated") { activated in
            secondTabAdapter.activate(for: extensionContext) { error in
                #expect(error == nil)
                activated()
            }
        }
        #expect(store.focusedPanelId == secondPanelID)

        let openEventsBeforeManagerPage = manager.debugDidOpenTabEventCount
        let closeEventsBeforeManagerPage = manager.debugDidCloseTabEventCount
        let managerPage = try #require(store.openBrowserExtensionsManager(from: secondPanelID))
        #expect(managerPage !== secondPanel)
        #expect(managerPage.internalPage == .extensions)
        #expect(secondPanel.internalPage == nil)
        #expect(store.browserPanel(for: managerPage.id) === managerPage)
        #expect(store.openBrowserExtensionsManager(from: secondPanelID) === managerPage)
        #expect(manager.debugDidOpenTabEventCount == openEventsBeforeManagerPage)
        #expect(manager.debugDidCloseTabEventCount == closeEventsBeforeManagerPage)

        #expect(store.closePanel(firstPanelID, force: true))
        let remainingTabs = manager
            .webExtensionController(manager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
        #expect(!remainingTabs.contains { $0.webView?(for: extensionContext) === firstPanel.webView })
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedAwaitsStartedLoadTask() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        try await manager.approveInstalledCandidate(dir)
        manager.startLoading()
        await manager.waitUntilLoaded()

        #expect(manager.isLoaded)
        #expect(manager.loadErrors.isEmpty)
        #expect(manager.loadedContexts.count == 1)
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedReturnsPromptlyWhenCallerIsCancelled() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let profileID = UUID()
        let loadGate = RuntimeLoadGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        runtime.start { await loadGate.wait() }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID,
            profileRuntime: runtime
        )

        let waiter = Task { @MainActor in
            await manager.waitUntilLoaded()
        }
        await Task.yield()
        waiter.cancel()
        await waiter.value
        loadGate.resume()
    }

    @available(macOS 15.4, *)
    @Test func mixedDeclaredAndUndeclaredPermissionRequestFailsClosedWithoutPresenting() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["optional_permissions"] = ["cookies"]
        manifest["optional_host_permissions"] = ["https://optional.example/*"]
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: manifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let promptCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            permissionPromptPresenter: { _, _ in
                promptCount.withLock { $0 += 1 }
                return .grant
            }
        )
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)

        let granted = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissions: [.cookies, .nativeMessaging],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        #expect(granted.isEmpty)
        let optionalURL = try #require(URL(string: "https://optional.example/page"))
        let undeclaredURL = try #require(URL(string: "https://undeclared.example/page"))
        let grantedURLs = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionToAccess: [optionalURL, undeclaredURL],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let optionalPattern = try #require(
            context.webExtension.optionalPermissionMatchPatterns.first
        )
        let undeclaredPattern = try WKWebExtension.MatchPattern(
            string: "https://undeclared.example/*"
        )
        let grantedPatterns = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionMatchPatterns: [optionalPattern, undeclaredPattern],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        #expect(grantedURLs.isEmpty)
        #expect(grantedPatterns.isEmpty)
        #expect(promptCount.withLock { $0 } == 0)
    }

    @available(macOS 15.4, *)
    @Test func permissionDecisionFromReplacedContextCannotMutateReplacement() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        var manifest = Self.minimalManifest
        manifest["optional_permissions"] = ["cookies"]
        let source = try Self.writeExtension(
            named: "permission-generation",
            in: sourceRoot,
            manifest: manifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let promptGate = PermissionPromptGate()
        let repository = BrowserWebExtensionDirectoryRepository()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            permissionPromptPresenter: { _, _ in
                await promptGate.present()
            }
        )
        _ = try await manager.installExtension(from: source)
        let oldContext = try #require(manager.loadedContexts.first)
        let permissionTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                manager.webExtensionController(
                    manager.controller,
                    promptForPermissions: [.cookies],
                    in: nil,
                    for: oldContext
                ) { allowed, _ in
                    continuation.resume(returning: allowed)
                }
            }
        }
        await promptGate.waitUntilEntered()

        let replacementPreview = try await manager.prepareInstall(from: source)
        #expect(replacementPreview.isUpdate)
        _ = try await manager.confirmPreparedInstall(id: replacementPreview.id)
        await promptGate.resolve(.grant)
        let allowed = await permissionTask.value

        #expect(allowed.isEmpty)
        let replacementContext = try #require(manager.loadedContexts.first)
        #expect(replacementContext !== oldContext)
        let managementID = try #require(
            try await repository.managementLedger(in: managedRoot).records.keys.first
        )
        let replacementRecord = try #require(
            try await repository.managementLedger(in: managedRoot).records[managementID]
        )
        #expect(
            replacementRecord.grantedPermissions[
                WKWebExtension.Permission.cookies.rawValue
            ] == nil
        )
    }

    @available(macOS 15.4, *)
    @Test func optionalPermissionCanBeRequestedGrantedRelaunchedAndRevoked() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["optional_permissions"] = ["cookies"]
        manifest["optional_host_permissions"] = ["https://optional.example/*"]
        let directory = try Self.writeExtension(
            named: "optional-lifecycle",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let promptCount = OSAllocatedUnfairLock(initialState: 0)
        let firstManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            permissionPromptPresenter: { _, _ in
                promptCount.withLock { $0 += 1 }
                return .grant
            }
        )
        try await firstManager.approveInstalledCandidate(directory)
        await firstManager.loadExtensions()
        let firstContext = try #require(firstManager.loadedContexts.first)
        let optionalPattern = try #require(
            firstContext.webExtension.optionalPermissionMatchPatterns.first
        )
        #expect(firstContext.permissionStatus(for: .cookies) != .deniedExplicitly)
        #expect(firstContext.permissionStatus(for: optionalPattern) != .deniedExplicitly)
        #expect(firstContext.deniedPermissions[.cookies] == nil)
        #expect(firstContext.deniedPermissionMatchPatterns[optionalPattern] == nil)

        let grantedPermissions = await withCheckedContinuation { continuation in
            firstManager.webExtensionController(
                firstManager.controller,
                promptForPermissions: [.cookies],
                in: nil,
                for: firstContext
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let grantedPatterns = await withCheckedContinuation { continuation in
            firstManager.webExtensionController(
                firstManager.controller,
                promptForPermissionMatchPatterns: [optionalPattern],
                in: nil,
                for: firstContext
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let optionalURL = try #require(URL(string: "https://optional.example/page"))
        let grantedURLs = await withCheckedContinuation { continuation in
            firstManager.webExtensionController(
                firstManager.controller,
                promptForPermissionToAccess: [optionalURL],
                in: nil,
                for: firstContext
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        #expect(grantedPermissions == [.cookies])
        #expect(grantedPatterns == [optionalPattern])
        #expect(grantedURLs == [optionalURL])
        #expect(promptCount.withLock { $0 } == 3)

        let repository = BrowserWebExtensionDirectoryRepository()
        let grantedRecord = try #require(
            try await repository.managementLedger(in: root).records["optional-lifecycle"]
        )
        #expect(grantedRecord.grantedPermissions[WKWebExtension.Permission.cookies.rawValue] != nil)
        #expect(grantedRecord.grantedMatchPatterns[optionalPattern.string] != nil)
        #expect(grantedRecord.deniedPermissions.isEmpty)
        #expect(grantedRecord.deniedMatchPatterns.isEmpty)
        firstManager.shutdown()

        let relaunchedManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        await relaunchedManager.loadExtensions()
        let relaunchedContext = try #require(relaunchedManager.loadedContexts.first)
        let relaunchedPattern = try #require(
            relaunchedContext.webExtension.optionalPermissionMatchPatterns.first
        )
        #expect(relaunchedContext.permissionStatus(for: .cookies) == .grantedExplicitly)
        #expect(relaunchedContext.permissionStatus(for: relaunchedPattern) == .grantedExplicitly)

        try await relaunchedManager.revokeOptionalPermissions(
            managementID: "optional-lifecycle"
        )
        #expect(relaunchedContext.permissionStatus(for: .cookies) != .grantedExplicitly)
        #expect(relaunchedContext.permissionStatus(for: relaunchedPattern) != .grantedExplicitly)
        let revokedRecord = try #require(
            try await repository.managementLedger(in: root).records["optional-lifecycle"]
        )
        #expect(revokedRecord.grantedPermissions[WKWebExtension.Permission.cookies.rawValue] == nil)
        #expect(revokedRecord.grantedMatchPatterns[relaunchedPattern.string] == nil)
        #expect(revokedRecord.deniedPermissions.isEmpty)
        #expect(revokedRecord.deniedMatchPatterns.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func allHostsOptionalPermissionCoversURLAndNarrowerPattern() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["optional_host_permissions"] = ["<all_urls>"]
        let directory = try Self.writeExtension(
            named: "optional-all-hosts",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let promptCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            permissionPromptPresenter: { _, _ in
                promptCount.withLock { $0 += 1 }
                return .grant
            }
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let requestedURL = try #require(URL(string: "https://narrow.example/page"))
        let requestedPattern = try WKWebExtension.MatchPattern(
            string: "https://narrow.example/*"
        )

        let grantedURLs = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionToAccess: [requestedURL],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let grantedPatterns = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionMatchPatterns: [requestedPattern],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }

        #expect(grantedURLs == [requestedURL])
        #expect(grantedPatterns == [requestedPattern])
        #expect(promptCount.withLock { $0 } == 2)
    }

    @available(macOS 15.4, *)
    @Test func requiredRuntimeRequestsFailClosedEvenWithGrantPresenter() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(
            to: dir.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let promptCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            permissionPromptPresenter: { _, _ in
                promptCount.withLock { $0 += 1 }
                return .grant
            }
        )
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let pageURL = try #require(URL(string: "https://example.com/page"))
        let matchPattern = try #require(context.webExtension.allRequestedMatchPatterns.first)

        let permissions = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissions: [.storage],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let urls = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionToAccess: [pageURL],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let patterns = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionMatchPatterns: [matchPattern],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }

        #expect(permissions.isEmpty)
        #expect(urls.isEmpty)
        #expect(patterns.isEmpty)
        #expect(promptCount.withLock { $0 } == 0)
    }

    @available(macOS 15.4, *)
    @Test func recordsErrorForInvalidManifestAndKeepsLoadingOthers() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        try await Self.recordRawManagedPackageForLoadTesting(broken, in: root)
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()

        #expect(manager.loadErrors.count == 1)
        #expect(manager.loadErrors.first?.url.lastPathComponent == "broken")
        #expect(manager.loadedContexts.count == 1)

        let snapshot = manager.presentationSnapshot()
        #expect(snapshot.state == .ready)
        #expect(snapshot.extensions.map(\.name) == ["cmux test extension"])
        #expect(snapshot.failures.map(\.entryName) == ["broken"])
    }

    @available(macOS 15.4, *)
    @Test func userFacingAndDiagnosticLoadFailuresDoNotExposeRawErrorDetails() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("private-package-name", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await Self.recordRawManagedPackageForLoadTesting(broken, in: root)

        await manager.loadExtensions()

        let failure = try #require(manager.presentationSnapshot().failures.first)
        #expect(failure.message == String(
            localized: "browser.extensions.load.failed",
            defaultValue: "The extension could not be loaded."
        ))
        let payload = manager.diagnosticPayload()
        let loadErrors = try #require(payload["load_errors"] as? [[String: Any]])
        let loadError = try #require(loadErrors.first)
        #expect(loadError["message"] == nil)
        let error = try #require(loadError["error"] as? [String: Any])
        #expect(error["domain"] is String)
        #expect(error["code"] is Int)
        #expect(error["message"] == nil)
        #expect(error["user_info"] == nil)
    }

    @available(macOS 15.4, *)
    @Test func invalidApprovedPackageDoesNotBlockHealthyExtensions() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = try Self.writeExtension(
            named: "healthy",
            in: root,
            manifest: Self.minimalManifest
        )
        let damaged = try Self.writeExtension(
            named: "damaged",
            in: root,
            manifest: Self.minimalManifest
        )
        for directory in [healthy, damaged] {
            try "// no-op".write(
                to: directory.appendingPathComponent("content.js"),
                atomically: true,
                encoding: .utf8
            )
        }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(healthy)
        try await manager.approveInstalledCandidate(damaged)
        try FileManager.default.createSymbolicLink(
            at: damaged.appendingPathComponent("post-approval-link"),
            withDestinationURL: healthy.appendingPathComponent("content.js")
        )

        await manager.loadExtensions()

        #expect(manager.loadedContexts.map(\.uniqueIdentifier) == [
            BrowserWebExtensionsManager.contextIdentifier(for: "healthy"),
        ])
        #expect(manager.loadErrors.map { $0.url.lastPathComponent } == ["damaged"])
    }
}

private struct CountingByteSequence: AsyncSequence, Sendable {
    typealias Element = UInt8

    struct AsyncIterator: AsyncIteratorProtocol {
        let bytes: [UInt8]
        let state: CountingByteSequenceState
        var index = 0

        mutating func next() async -> UInt8? {
            state.recordNext()
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }
    }

    let bytes: [UInt8]
    let state: CountingByteSequenceState

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes, state: state)
    }
}

private final class CountingByteSequenceState: @unchecked Sendable {
    private let lock = NSLock()
    private var nextCount = 0
    private var cancellationCount = 0

    var snapshot: (nextCount: Int, cancellationCount: Int) {
        lock.withLock { (nextCount, cancellationCount) }
    }

    func recordNext() {
        lock.withLock { nextCount += 1 }
    }

    func recordCancellation() {
        lock.withLock { cancellationCount += 1 }
    }
}
