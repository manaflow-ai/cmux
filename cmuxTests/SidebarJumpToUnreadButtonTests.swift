import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarJumpToUnreadButtonTests {
    private let title = KeyboardShortcutSettings.Action.jumpToUnread.label
    private let defaultShortcut = KeyboardShortcutSettings.Action.jumpToUnread.defaultShortcut
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func hidesInMinimalModeLikeOtherFooterControls() {
        #expect(!SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: .minimal))
        #expect(SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: .standard))
    }

    @Test
    func showsOnlyWhileSomethingIsUnread() {
        let unread = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 3, shortcut: defaultShortcut)
        let allRead = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 0, shortcut: defaultShortcut)

        #expect(unread.isVisible)
        #expect(!allRead.isVisible)
        #expect(unread.countText == "3")
        #expect(allRead.countText == nil)
        #expect(unread.label == "Last unread")
    }

    @Test
    func largeCountsAreCapped() {
        let atCap = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 99, shortcut: defaultShortcut)
        let overCap = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 250, shortcut: defaultShortcut)

        #expect(atCap.countText == "99")
        #expect(overCap.countText == "99+")
    }

    @Test
    func hoverShortcutAndTooltipUseTheConfiguredShortcutNotTheDefault() {
        let rebound = StoredShortcut(key: "j", command: false, shift: false, option: true, control: true)

        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 1, shortcut: rebound)

        #expect(presentation.shortcutText == rebound.displayString)
        #expect(presentation.helpText == "\(title) (\(rebound.displayString))")
        #expect(!presentation.helpText.contains(defaultShortcut.displayString))
    }

    @Test
    func unboundShortcutLeavesNoShortcutInTheHoverOrTooltip() {
        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(unreadCount: 1, shortcut: .unbound)

        #expect(presentation.shortcutText == nil)
        #expect(presentation.helpText == title)
        #expect(presentation.isVisible)
    }

    @Test
    func turningTheSettingOffHidesTheButtonEvenWithUnread() {
        let presentation = SidebarJumpToUnreadButtonPresentation.resolve(
            unreadCount: 5,
            shortcut: defaultShortcut,
            isEnabled: false
        )

        #expect(!presentation.isVisible)
    }

    @Test
    func cmuxJSONTurnsTheButtonOff() throws {
        let defaults = UserDefaults.standard
        let managedKey = SidebarJumpToUnreadButtonPresentation.setting.userDefaultsKey
        let keys = [managedKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]
        let previousValues = keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        defer {
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jump-to-unread-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try #"{ "sidebar": { "showJumpToUnreadButton": false } }"#.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.object(forKey: managedKey) as? Bool == false)
        #expect(!UserDefaultsSettingsClient(defaults: defaults).value(for: SidebarJumpToUnreadButtonPresentation.setting))
    }
}
