import AppKit
import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor
struct RightSidebarCustomTabTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "RightSidebarCustomTabTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "cloud.beta.machines.enabled")
        defaults.set(true, forKey: "customSidebars.beta.enabled")
        defaults.set("status-board", forKey: "rightSidebar.customSidebarName")
        try body(defaults)
    }

    @Test func customTabIsAppendedToExistingOrder() {
        withDefaults { defaults in
            defaults.set(["find", "files", "sessions", "feed", "dock", "machines"], forKey: RightSidebarTabPreferences.orderKey)
            #expect(RightSidebarTabPreferences.orderedModes(defaults: defaults).last == .customSidebar)
            #expect(RightSidebarMode.visibleModes(defaults: defaults).contains(.customSidebar))
        }
    }

    @Test func customAvailabilityUsesTheSuppliedDefaults() {
        withDefaults { defaults in
            #expect(RightSidebarMode.customSidebar.isAvailable(defaults: defaults))
            defaults.set(false, forKey: "customSidebars.beta.enabled")
            #expect(!RightSidebarMode.visibleModes(defaults: defaults).contains(.customSidebar))
            defaults.set(true, forKey: "customSidebars.beta.enabled")
            defaults.removeObject(forKey: "rightSidebar.customSidebarName")
            #expect(!RightSidebarMode.customSidebar.isAvailable(defaults: defaults))
        }
    }

    @Test func customTabCanBeHiddenAndRestored() {
        withDefaults { defaults in
            #expect(RightSidebarTabPreferences.setHidden(true, mode: .customSidebar, defaults: defaults))
            #expect(!RightSidebarMode.visibleModes(defaults: defaults).contains(.customSidebar))
            #expect(RightSidebarTabPreferences.setHidden(false, mode: .customSidebar, defaults: defaults))
            #expect(RightSidebarMode.visibleModes(defaults: defaults).contains(.customSidebar))
        }
    }

    @Test func customTabCanBeTheOnlyVisibleTab() {
        withDefaults { defaults in
            for mode in RightSidebarMode.allCases where mode != .customSidebar {
                #expect(RightSidebarTabPreferences.setHidden(true, mode: mode, defaults: defaults))
            }
            #expect(RightSidebarMode.visibleModes(defaults: defaults) == [.customSidebar])
            #expect(!RightSidebarTabPreferences.setHidden(true, mode: .customSidebar, defaults: defaults))
        }
    }

    @Test func customTabParticipatesInDragAndSettingsReordering() {
        withDefaults { defaults in
            RightSidebarTabPreferences.setDisplayedOrder([.customSidebar, .files, .find, .sessions], defaults: defaults)
            #expect(RightSidebarTabPreferences.orderedModes(defaults: defaults) == [.customSidebar, .files, .find, .feed, .dock, .machines, .sessions])
            RightSidebarTabPreferences.move(.customSidebar, offset: 1, defaults: defaults)
            #expect(RightSidebarTabPreferences.orderedModes(defaults: defaults).prefix(2) == [.files, .customSidebar])
            #expect(RightSidebarMode.positionalDigit(for: .customSidebar, defaults: defaults) == 2)
        }
    }

    @Test func selectingCustomSidebarKeepsItReachableAfterSwitchingToFiles() {
        withDefaults { defaults in
            defaults.removeObject(forKey: "rightSidebar.customSidebarName")
            let firstWindow = FileExplorerState(defaults: defaults)
            let secondWindow = FileExplorerState(defaults: defaults)

            firstWindow.selectCustomSidebar(name: " status-board ")
            firstWindow.mode = .customSidebar
            #expect(FileExplorerState(defaults: defaults).mode == .customSidebar)
            firstWindow.mode = .files

            #expect(RightSidebarMode.visibleModes(defaults: defaults).contains(.customSidebar))
            #expect(secondWindow.customSidebarName == "status-board")
            secondWindow.mode = .customSidebar
            #expect(secondWindow.mode == .customSidebar)

            firstWindow.selectCustomSidebar(name: "another-board")
            #expect(secondWindow.customSidebarName == "another-board")
        }
    }

    @Test func availableModesAndPaletteIncludeCustomExactlyOnce() throws {
        try withDefaults { defaults in
            let modes = RightSidebarMode.availableModes(defaults: defaults)
            #expect(modes.filter { $0 == .customSidebar }.count == 1)
            #expect(RightSidebarMode.availableModes(
                feedEnabled: false, machinesEnabled: false, defaults: defaults
            ).filter { $0 == .customSidebar }.count == 1)

            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions(defaults: defaults)
            let customID = ContentView.commandPaletteRightSidebarModeCommandID(.customSidebar)
            let custom = try #require(contributions.first { $0.commandId == customID })
            #expect(custom.title(CommandPaletteContextSnapshot()) == RightSidebarMode.customSidebar.label)
            #expect(Set(contributions.map(\.commandId)).count == contributions.count)

            defaults.set(false, forKey: "customSidebars.beta.enabled")
            #expect(!RightSidebarMode.availableModes(
                feedEnabled: false, machinesEnabled: false, defaults: defaults
            ).contains(.customSidebar))
            #expect(!ContentView.commandPaletteRightSidebarModeCommandContributions(defaults: defaults)
                .contains { $0.commandId == customID })
        }
    }

    @Test func disablingCustomWhenItIsTheOnlyVisibleTabRecoversBuiltInTabs() {
        withDefaults { defaults in
            let state = FileExplorerState(defaults: defaults)
            state.mode = .customSidebar
            for mode in RightSidebarMode.allCases where mode != .customSidebar {
                RightSidebarTabPreferences.setHidden(true, mode: mode, defaults: defaults)
            }
            defaults.set(false, forKey: "customSidebars.beta.enabled")
            state.refreshModeAvailability()
            #expect(state.mode == .files)
            #expect(!RightSidebarMode.visibleModes(defaults: defaults).contains(.customSidebar))
            #expect(!RightSidebarMode.visibleModes(defaults: defaults).isEmpty)
        }
    }

    @Test func customAvailabilityChangesRefreshCachedBuiltInShortcuts() throws {
        try withDefaults { defaults in
            defaults.removeObject(forKey: "rightSidebar.customSidebarName")
            defaults.set(["custom-sidebar", "files"], forKey: RightSidebarTabPreferences.orderKey)
            let center = NotificationCenter()
            let observer = KeyboardShortcutSettingsObserver(
                notificationCenter: center,
                defaults: defaults,
                shortcutProvider: { action in
                    action == .switchRightSidebarToFiles
                        ? KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .files, defaults: defaults)
                        : .unbound
                }
            )
            let one = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .control,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
            ))
            let two = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .control,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19
            ))
            let matcher = observer.rightSidebarModeShortcutMatcher
            #expect(matcher.modeShortcut(for: one, allowingAction: { _ in true }) == .files)

            FileExplorerState(defaults: defaults).selectCustomSidebar(name: "status-board")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(matcher.modeShortcut(for: one, allowingAction: { _ in true }) == nil)
            #expect(matcher.modeShortcut(for: two, allowingAction: { _ in true }) == .files)

            defaults.set(false, forKey: "customSidebars.beta.enabled")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(matcher.modeShortcut(for: one, allowingAction: { _ in true }) == .files)
            #expect(matcher.modeShortcut(for: two, allowingAction: { _ in true }) == nil)

            let revision = observer.revision
            defaults.set("unrelated", forKey: "unrelated.preference")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(observer.revision == revision)
        }
    }
}
