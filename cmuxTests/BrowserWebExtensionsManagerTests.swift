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
        #expect(context.grantedPermissionMatchPatterns.contains { $0.matches(url) })
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
            try await withCheckedThrowingContinuation { continuation in
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
