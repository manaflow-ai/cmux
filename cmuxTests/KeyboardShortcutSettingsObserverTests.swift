import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension GlobalSearchShortcutBehaviorTests {
    @MainActor @Suite("Keyboard shortcut settings observer") struct KeyboardShortcutSettingsObserverTests {
    @Test func mainThreadSettingsChangeIsAuthoritativeBeforePostReturns() {
        let observer = KeyboardShortcutSettingsObserver.shared
        let expectedRevision = observer.revision &+ 1

        NotificationCenter.default.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )

        #expect(observer.revision == expectedRevision)
    }

    @Test func globalSearchShortcutUsesSnapshotAndReloadsAfterSettingsChange() async {
        let notificationCenter = NotificationCenter()
        let state = ShortcutProviderState(
            configuredShortcut: StoredShortcut(
                key: "f",
                command: true,
                shift: false,
                option: true,
                control: false
            )
        )
        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: notificationCenter,
            shortcutProvider: { action in
                state.shortcut(for: action)
            }
        )
        await observer.waitUntilShortcutSnapshotIsIdle()

        #expect(observer.globalSearchShortcut == state.configuredShortcut)
        let initialLookupCount = state.globalSearchLookupCount
        for _ in 0..<100 {
            _ = observer.globalSearchShortcut
        }
        #expect(state.globalSearchLookupCount == initialLookupCount)

        state.configuredShortcut = StoredShortcut(
            key: "g",
            command: true,
            shift: true,
            option: false,
            control: false,
            chordKey: "s"
        )
        notificationCenter.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )
        await observer.waitUntilShortcutSnapshotIsIdle()

        #expect(observer.globalSearchShortcut == state.configuredShortcut)
        #expect(state.globalSearchLookupCount == initialLookupCount + 1)

        state.configuredShortcut = .unbound
        notificationCenter.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )
        await observer.waitUntilShortcutSnapshotIsIdle()

        #expect(observer.globalSearchShortcut == .unbound)
        #expect(state.globalSearchLookupCount == initialLookupCount + 2)
    }

    @Test func legacyMediaKeyGlobalSearchBindingFallsBackToDefault() throws {
        let action = KeyboardShortcutSettings.Action.globalSearch
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: action.defaultsKey)
        let originalStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-observer-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalStore
            if let originalValue {
                defaults.set(originalValue, forKey: action.defaultsKey)
            } else {
                defaults.removeObject(forKey: action.defaultsKey)
            }
        }

        let mediaShortcut = StoredShortcut(
            key: "media.playPause",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        defaults.set(try JSONEncoder().encode(mediaShortcut), forKey: action.defaultsKey)

        #expect(KeyboardShortcutSettings.shortcut(for: action) == action.defaultShortcut)
    }

    @Test func completedKeyboardLayoutChangeRefreshesGlobalSearchSnapshot() async {
        let notificationCenter = NotificationCenter()
        let state = ShortcutProviderState(
            configuredShortcut: StoredShortcut(
                key: "f",
                command: true,
                shift: false,
                option: true,
                control: false
            )
        )
        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: notificationCenter,
            shortcutProvider: { action in
                state.shortcut(for: action)
            }
        )
        await observer.waitUntilShortcutSnapshotIsIdle()
        let initialLookupCount = state.globalSearchLookupCount
        state.configuredShortcut = StoredShortcut(
            key: "g",
            command: true,
            shift: true,
            option: false,
            control: false
        )

        notificationCenter.post(name: KeyboardLayout.didChangeNotification, object: nil)
        await observer.waitUntilShortcutSnapshotIsIdle()

        #expect(observer.globalSearchShortcut == state.configuredShortcut)
        #expect(state.globalSearchLookupCount == initialLookupCount + 1)
        #expect(observer.revision >= 2)
    }

    @Test func blockedShortcutProviderDoesNotBlockMainActorDuringObserverStartup() async {
        let probe = BlockedShortcutProviderProbe()
        Task.detached {
            probe.waitUntilProviderStarts()
            Thread.sleep(forTimeInterval: 0.2)
            probe.recordHeartbeatBeforeRelease()
            probe.releaseProvider()
        }

        Task { @MainActor in
            probe.recordMainActorHeartbeat()
        }

        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: NotificationCenter(),
            shortcutProvider: { action in
                if action == .globalSearch {
                    probe.blockProvider()
                }
                return action.defaultShortcut
            }
        )

        await Task.yield()
        await probe.waitUntilRecorded()

        #expect(
            probe.didHeartbeatBeforeProviderRelease,
            "Shortcut persistence loading blocked the MainActor during observer startup"
        )
        _ = observer
    }

    @Test func blockedKeyboardLayoutLoaderKeepsMainActorResponsiveAndReplacesSnapshot() async {
        let gate = DispatchSemaphore(value: 0)
        let initial = KeyboardLayoutSnapshot.testFixture(id: "old", character: "a")
        let replacement = KeyboardLayoutSnapshot.testFixture(id: "new", character: "q")
        let cache = KeyboardLayoutSnapshotCache(initialSnapshot: initial) {
            gate.wait()
            return replacement
        }

        cache.requestRefresh()
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !heartbeat, clock.now < deadline {
            await Task.yield()
        }
        #expect(heartbeat, "MainActor heartbeat did not run before the deadline")

        #expect(cache.snapshot.inputSourceID == "old")
        #expect(cache.snapshot.shortcutCharacter(forKeyCode: 0, modifierFlags: []) == "a")

        gate.signal()
        await cache.waitUntilIdle()

        #expect(cache.snapshot.inputSourceID == "new")
        #expect(cache.snapshot.shortcutCharacter(forKeyCode: 0, modifierFlags: []) == "q")
    }

    @Test func keyboardLayoutRefreshStormDropsStaleResultAndCoalescesReloads() async {
        let loader = SequencedKeyboardLayoutSnapshotLoader()
        let cache = KeyboardLayoutSnapshotCache(
            initialSnapshot: .testFixture(id: "initial", character: "a"),
            loader: loader.load
        )

        cache.requestRefresh()
        for _ in 0..<100 {
            cache.requestRefresh()
        }
        loader.releaseFirstLoad()
        await cache.waitUntilIdle()

        #expect(loader.loadCount == 2)
        #expect(cache.snapshot.inputSourceID == "fresh")
        #expect(cache.snapshot.shortcutCharacter(forKeyCode: 0, modifierFlags: []) == "f")
    }

    @Test func refreshRequestedByInstallHandlerRunsBeforeCacheBecomesIdle() async {
        let harness = ReentrantSnapshotCacheHarness()

        harness.cache.requestRefresh()
        await harness.cache.waitUntilIdle()

        #expect(harness.loader.loadCount == 2)
        #expect(harness.cache.snapshot == 2)
        #expect(harness.installedSnapshots == [1, 2])
    }

    }
}

private final class BlockedShortcutProviderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let providerStarted = DispatchSemaphore(value: 0)
    private let providerRelease = DispatchSemaphore(value: 0)
    private var heartbeat = false
    private var recordedHeartbeat: Bool?

    var didHeartbeatBeforeProviderRelease: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedHeartbeat == true
    }

    func blockProvider() {
        providerStarted.signal()
        providerRelease.wait()
    }

    func waitUntilProviderStarts() {
        providerStarted.wait()
    }

    func releaseProvider() {
        providerRelease.signal()
    }

    func recordMainActorHeartbeat() {
        lock.lock()
        heartbeat = true
        lock.unlock()
    }

    func recordHeartbeatBeforeRelease() {
        lock.lock()
        recordedHeartbeat = heartbeat
        lock.unlock()
    }

    func waitUntilRecorded() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            lock.lock()
            let didRecord = recordedHeartbeat != nil
            lock.unlock()
            if didRecord { return }
            await Task.yield()
        }
    }
}

private final class ShortcutProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfiguredShortcut: StoredShortcut
    private var storedGlobalSearchLookupCount = 0

    init(configuredShortcut: StoredShortcut) {
        storedConfiguredShortcut = configuredShortcut
    }

    var configuredShortcut: StoredShortcut {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedConfiguredShortcut
        }
        set {
            lock.lock()
            storedConfiguredShortcut = newValue
            lock.unlock()
        }
    }

    var globalSearchLookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedGlobalSearchLookupCount
    }

    func shortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        lock.lock()
        defer { lock.unlock() }
        guard action == .globalSearch else { return .unbound }
        storedGlobalSearchLookupCount += 1
        return storedConfiguredShortcut
    }
}

@MainActor
private final class ReentrantSnapshotCacheHarness {
    let loader = IncrementingSnapshotLoader()
    private(set) var installedSnapshots: [Int] = []
    lazy var cache = GenerationCoalescingSnapshotCache(
        initialSnapshot: 0,
        loader: loader.load,
        installHandler: { [weak self] snapshot in
            guard let self else { return }
            installedSnapshots.append(snapshot)
            if snapshot == 1 {
                cache.requestRefresh()
            }
        }
    )
}

private final class IncrementingSnapshotLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLoadCount = 0

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLoadCount
    }

    func load() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        storedLoadCount += 1
        return storedLoadCount
    }
}

private extension KeyboardLayoutSnapshot {
    static func testFixture(id: String, character: String) -> Self {
        Self(
            inputSourceID: id,
            shortcutCharacters: [
                .init(keyCode: 0, modifierFlags: []): character,
            ],
            textInputCharacters: [:]
        )
    }
}

private final class SequencedKeyboardLayoutSnapshotLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let firstLoadGate = DispatchSemaphore(value: 0)
    private var storedLoadCount = 0

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLoadCount
    }

    func releaseFirstLoad() {
        firstLoadGate.signal()
    }

    func load() -> KeyboardLayoutSnapshot? {
        lock.lock()
        storedLoadCount += 1
        let loadNumber = storedLoadCount
        lock.unlock()

        if loadNumber == 1 {
            firstLoadGate.wait()
            return .testFixture(id: "stale", character: "s")
        }
        return .testFixture(id: "fresh", character: "f")
    }
}
