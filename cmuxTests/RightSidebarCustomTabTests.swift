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
}
