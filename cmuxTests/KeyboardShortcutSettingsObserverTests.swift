import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Keyboard shortcut settings observer", .serialized)
struct KeyboardShortcutSettingsObserverTests {
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
}
