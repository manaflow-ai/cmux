import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@MainActor
struct BrowserWebExtensionsManagerTests {
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

    @Test func verifiedCatalogUsesUniqueHTTPSVersionPinnedPackages() throws {
        let entries = BrowserWebExtensionCatalog.verifiedEntries

        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.allSatisfy { $0.packageURL.scheme == "https" })
        #expect(entries.allSatisfy { !$0.version.isEmpty })
        #expect(entries.allSatisfy { $0.packageSHA256.count == 64 })
    }

    @Test func packageVerifierAcceptsPinnedDigestAndRejectsChangedBytes() throws {
        let data = Data("cmux".utf8)
        let digest = "548d4fabc56e7b556bbd7d01c3bcb6288fc8de3078dcb38fc3698fb3c26508c9"

        try BrowserWebExtensionPackageVerifier.verify(data, expectedSHA256: digest)
        #expect(throws: BrowserWebExtensionCatalogInstallError.integrityMismatch) {
            try BrowserWebExtensionPackageVerifier.verify(data + Data([0]), expectedSHA256: digest)
        }
    }

    @Test func catalogPackageSessionRejectsDeclaredOversizedResponseBeforeBuffering() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeclaredOversizedWebExtensionURLProtocol.self]
        let session = BrowserWebExtensionPackageSession(
            configuration: configuration,
            maximumResponseByteCount: 8
        )
        let url = try #require(URL(string: "https://extensions.example/package.zip"))

        await confirmation("declared oversized package transfer was cancelled") { cancelled in
            DeclaredOversizedWebExtensionURLProtocol.observeCancellation {
                cancelled()
            }
            await #expect(throws: BrowserWebExtensionCatalogInstallError.packageTooLarge) {
                _ = try await session.data(from: url)
            }
        }
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
    @Test func loadsUnpackedExtensionAndGrantsRequestedPermissions() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        await manager.loadExtensions()

        #expect(manager.loadErrors.isEmpty)
        #expect(manager.loadedContexts.count == 1)
        let context = try #require(manager.loadedContexts.first)
        #expect(context.uniqueIdentifier == "cmux-browser-extension-sample")
        #expect(context.currentPermissions.contains(.storage))
        #expect(!context.grantedPermissionMatchPatterns.isEmpty)
        #expect(manager.controller.extensionContexts.contains(context))
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
        #expect(FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("sample/manifest.json").path))
        #expect(manager.loadedContexts.count == 1)
        #expect(manager.presentationSnapshot().extensions.map(\.name) == ["cmux test extension"])
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

        await manager.loadExtensions()

        let item = try #require(manager.presentationSnapshot().extensions.first)
        let iconData = try #require(item.iconData)
        #expect(NSImage(data: iconData) != nil)
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

        await manager.loadExtensions()

        let itemsByName = Dictionary(
            uniqueKeysWithValues: manager.presentationSnapshot().extensions.map { ($0.name, $0) }
        )
        let alpha = try #require(itemsByName["Arbitrary Alpha"]?.iconData)
        let beta = try #require(itemsByName["Arbitrary Beta"]?.iconData)
        let alphaColor = try Self.centerColor(in: alpha)
        let betaColor = try Self.centerColor(in: beta)
        #expect(abs(alphaColor.redComponent) < 0.05)
        #expect(abs(alphaColor.greenComponent) < 0.05)
        #expect(abs(alphaColor.blueComponent - 1) < 0.05)
        #expect(abs(betaColor.redComponent) < 0.05)
        #expect(abs(betaColor.greenComponent - 1) < 0.05)
        #expect(abs(betaColor.blueComponent) < 0.05)
        #expect(itemsByName["Arbitrary Iconless"]?.iconData == nil)
    }

    @available(macOS 15.4, *)
    @Test func duplicateInstallPreservesExistingExtension() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(named: "sample", in: sourceRoot, manifest: Self.minimalManifest)
        try "// no-op".write(to: source.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        let manager = BrowserWebExtensionsManager(directory: managedRoot, controllerConfiguration: .nonPersistent())
        _ = try await manager.installExtension(from: source)

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            _ = try await manager.installExtension(from: source)
        }
        #expect(manager.loadedContexts.count == 1)
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
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )

        #expect(configuration.webExtensionController === services.webExtensionsManager?.controller)
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
    @Test func waitUntilLoadedAwaitsStartedLoadTask() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        manager.startLoading()
        await manager.waitUntilLoaded()

        #expect(manager.isLoaded)
        #expect(manager.loadErrors.isEmpty)
        #expect(manager.loadedContexts.count == 1)
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedTimesOutWhenLoadHangs() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        let hungLoad = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        defer { hungLoad.cancel() }
        manager.loadTask = hungLoad

        // Must return via the timeout even though the load task never finishes,
        // so a hung extension load cannot block panel navigation forever.
        await manager.waitUntilLoaded(timeout: .milliseconds(50))

        #expect(!manager.isLoaded)
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedKeepsEachWaiterTimeoutIndependent() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        manager.loadTask = Task {}

        let longClock = BrowserWebExtensionsTestClock()
        let shortClock = BrowserWebExtensionsTestClock()
        let longWaiter = Task { @MainActor in
            await manager.waitUntilLoaded(timeout: .seconds(2), clock: longClock)
        }
        await longClock.waitUntilSleepers()

        let shortWaiter = Task { @MainActor in
            await manager.waitUntilLoaded(timeout: .seconds(1), clock: shortClock)
        }
        await shortClock.waitUntilSleepers()
        shortClock.advance(by: .seconds(1))
        await shortWaiter.value
        await Task.yield()

        #expect(longClock.sleeperCount == 1)
        longClock.advance(by: .seconds(2))
        await longWaiter.value
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedReturnsPromptlyWhenCallerIsCancelled() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        manager.loadTask = Task {}

        let clock = BrowserWebExtensionsTestClock()
        let waiter = Task { @MainActor in
            await manager.waitUntilLoaded(timeout: .seconds(1), clock: clock)
        }
        await clock.waitUntilSleepers()
        waiter.cancel()
        await Task.yield()

        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(1))
        await waiter.value
    }

    @available(macOS 15.4, *)
    @Test func runtimePermissionPromptsGrantOnlyManifestDeclaredSet() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["optional_permissions"] = ["cookies"]
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: manifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
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
        #expect(granted == [.cookies])
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
        await manager.loadExtensions()

        #expect(manager.loadErrors.count == 1)
        #expect(manager.loadErrors.first?.url.lastPathComponent == "broken")
        #expect(manager.loadedContexts.count == 1)

        let snapshot = manager.presentationSnapshot()
        #expect(snapshot.state == .ready)
        #expect(snapshot.extensions.map(\.name) == ["cmux test extension"])
        #expect(snapshot.failures.map(\.entryName) == ["broken"])
        #expect(snapshot.directoryPath == root.path)
    }
}

private final class DeclaredOversizedWebExtensionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let cancellationObserver = WebExtensionURLProtocolCancellationObserver()

    static func observeCancellation(_ observer: @escaping @Sendable () -> Void) {
        cancellationObserver.install(observer)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "9"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {
        Self.cancellationObserver.fire()
    }
}

private final class WebExtensionURLProtocolCancellationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (@Sendable () -> Void)?

    func install(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { self.observer = observer }
    }

    func fire() {
        let observer = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.observer = nil }
            return self.observer
        }
        observer?()
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

private final class BrowserWebExtensionsTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []

    var now: Instant {
        lock.withLock { currentInstant }
    }

    var minimumResolution: Duration { .zero }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    if cancelledSleeperIDs.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else if deadline <= currentInstant {
                        continuation.resume()
                    } else {
                        sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    }
                    let waiters = parkWaiters
                    parkWaiters.removeAll()
                    return waiters
                }
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                let sleeper = sleepers.removeValue(forKey: id)
                if sleeper == nil { cancelledSleeperIDs.insert(id) }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleepers() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard sleepers.isEmpty else { return true }
                parkWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            currentInstant = currentInstant.advanced(by: duration)
            let dueIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadline <= currentInstant ? id : nil
            }
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
