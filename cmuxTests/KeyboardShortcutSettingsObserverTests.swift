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

    @Test func globalSearchShortcutUsesSnapshotAndReloadsAfterSettingsChange() {
        let notificationCenter = NotificationCenter()
        var configuredShortcut = StoredShortcut(
            key: "f",
            command: true,
            shift: false,
            option: true,
            control: false
        )
        var globalSearchLookupCount = 0
        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: notificationCenter,
            shortcutProvider: { action in
                guard action == .globalSearch else { return .unbound }
                globalSearchLookupCount += 1
                return configuredShortcut
            }
        )

        #expect(observer.globalSearchShortcut == configuredShortcut)
        let initialLookupCount = globalSearchLookupCount
        for _ in 0..<100 {
            _ = observer.globalSearchShortcut
        }
        #expect(globalSearchLookupCount == initialLookupCount)

        configuredShortcut = StoredShortcut(
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

        #expect(observer.globalSearchShortcut == configuredShortcut)
        #expect(globalSearchLookupCount == initialLookupCount + 1)

        configuredShortcut = .unbound
        notificationCenter.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )

        #expect(observer.globalSearchShortcut == .unbound)
        #expect(globalSearchLookupCount == initialLookupCount + 2)
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

    @Test func completedKeyboardLayoutChangeRefreshesGlobalSearchSnapshot() {
        let notificationCenter = NotificationCenter()
        var configuredShortcut = StoredShortcut(
            key: "f",
            command: true,
            shift: false,
            option: true,
            control: false
        )
        var globalSearchLookupCount = 0
        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: notificationCenter,
            shortcutProvider: { action in
                guard action == .globalSearch else { return .unbound }
                globalSearchLookupCount += 1
                return configuredShortcut
            }
        )
        let initialLookupCount = globalSearchLookupCount
        configuredShortcut = StoredShortcut(
            key: "g",
            command: true,
            shift: true,
            option: false,
            control: false
        )

        notificationCenter.post(name: KeyboardLayout.didChangeNotification, object: nil)

        #expect(observer.globalSearchShortcut == configuredShortcut)
        #expect(globalSearchLookupCount == initialLookupCount + 1)
        #expect(observer.revision == 1)
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
        while !heartbeat {
            await Task.yield()
        }

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
