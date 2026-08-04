import Carbon
import CmuxSettings
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
            distributedNotificationCenter: DistributedNotificationCenter(),
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

    @Test func bindingSnapshotsReloadAfterSettingsChange() {
        let notificationCenter = NotificationCenter()
        let chordAction = KeyboardShortcutSettings.Action.splitRight
        let explicitAction = KeyboardShortcutSettings.Action.showNotifications
        let firstChord = StoredShortcut(
            key: "k",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "s"
        )
        let secondChord = StoredShortcut(
            key: "j",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "v"
        )
        let firstExplicit = StoredShortcut(
            key: "i",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        let secondExplicit = StoredShortcut(
            key: "n",
            command: true,
            shift: true,
            option: false,
            control: false
        )
        var chordShortcut = firstChord
        var explicitShortcut = firstExplicit
        var whenClauses: [KeyboardShortcutSettings.Action: ShortcutWhenClause] = [
            chordAction: .key("beforeChord"),
            explicitAction: .key("beforeExplicit"),
        ]
        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: notificationCenter,
            distributedNotificationCenter: DistributedNotificationCenter(),
            shortcutProvider: { action in
                action == chordAction ? chordShortcut : .unbound
            },
            explicitShortcutProvider: { action in
                action == explicitAction ? explicitShortcut : nil
            },
            whenClauseProvider: { action in
                whenClauses[action] ?? .always
            }
        )

        #expect(observer.configuredChordBindings == [
            KeyboardShortcutBinding(
                action: chordAction,
                shortcut: firstChord,
                whenClause: .key("beforeChord")
            ),
        ])
        #expect(observer.applicationPaneExplicitShortcutBindings == [
            KeyboardShortcutBinding(
                action: explicitAction,
                shortcut: firstExplicit,
                whenClause: .key("beforeExplicit")
            ),
        ])

        chordShortcut = secondChord
        explicitShortcut = secondExplicit
        whenClauses = [
            chordAction: .key("afterChord"),
            explicitAction: .key("afterExplicit"),
        ]

        #expect(observer.configuredChordBindings.first?.shortcut == firstChord)
        #expect(
            observer.applicationPaneExplicitShortcutBindings.first?.shortcut
                == firstExplicit
        )

        notificationCenter.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )

        #expect(observer.configuredChordBindings == [
            KeyboardShortcutBinding(
                action: chordAction,
                shortcut: secondChord,
                whenClause: .key("afterChord")
            ),
        ])
        #expect(observer.applicationPaneExplicitShortcutBindings == [
            KeyboardShortcutBinding(
                action: explicitAction,
                shortcut: secondExplicit,
                whenClause: .key("afterExplicit")
            ),
        ])
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

    @Test func inputSourceChangeRefreshesGlobalSearchSnapshot() async {
        let notificationCenter = NotificationCenter()
        let distributedNotificationCenter = DistributedNotificationCenter.default()
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
            distributedNotificationCenter: distributedNotificationCenter,
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

        distributedNotificationCenter.postNotificationName(
            Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        var yields = 0
        while globalSearchLookupCount == initialLookupCount, yields < 1_000 {
            await Task.yield()
            yields += 1
        }

        #expect(observer.globalSearchShortcut == configuredShortcut)
        #expect(globalSearchLookupCount == initialLookupCount + 1)
        #expect(observer.revision == 1)
    }

    }
}
