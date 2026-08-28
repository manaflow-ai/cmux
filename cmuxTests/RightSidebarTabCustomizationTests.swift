import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior of the customizable right-sidebar tabs: user-defined order and
/// visibility, and the positional `ctrl+digit` shortcut defaults that follow
/// the visible order (the Nth visible tab answers ctrl+N).
@MainActor
final class RightSidebarTabCustomizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RightSidebarTabCustomizationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func enableAllModeGates() {
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
    }

    private func enableMachinesGate() {
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
    }

    // MARK: - Ordering and visibility

    func testDefaultOrderIsCanonical() {
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.files, .find, .sessions, .feed, .dock, .machines]
        )
    }

    func testStoredOrderIgnoresUnknownEntriesAndAppendsMissingModes() {
        defaults.set(["machines", "bogus", "files", "custom-sidebar"], forKey: RightSidebarTabPreferences.orderKey)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.machines, .files, .find, .sessions, .feed, .dock]
        )
    }

    func testVisibleModesDropUserHiddenTabs() {
        enableAllModeGates()
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults))
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.files, .sessions, .feed, .dock, .machines]
        )
    }

    func testHidingLastVisibleTabIsRefused() {
        // Feed and Dock are feature-gated off in this suite; Cloud may be on
        // through the process-global rollout flag, so hide it explicitly.
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .files, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .machines, defaults: defaults))
        XCTAssertFalse(
            RightSidebarTabPreferences.setHidden(true, mode: .sessions, defaults: defaults),
            "the last visible tab must stay visible"
        )
        XCTAssertEqual(RightSidebarMode.visibleModes(defaults: defaults), [.sessions])
    }

    func testMoveReordersAndClampsAtEdges() {
        RightSidebarTabPreferences.move(.machines, offset: -5, defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.machines, .files, .find, .sessions, .feed, .dock]
        )
        RightSidebarTabPreferences.move(.machines, offset: -1, defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults).first,
            .machines,
            "moving past the front clamps"
        )
    }

    func testSetDisplayedOrderPermutesOnlyTheDisplayedSlots() {
        // Hide Feed; Dock stays hidden-by-gate but keeps its slot in the full
        // order. Dragging Cloud before Files must not move Feed or Dock.
        enableAllModeGates()
        RightSidebarTabPreferences.setHidden(true, mode: .feed, defaults: defaults)
        RightSidebarTabPreferences.setDisplayedOrder(
            [.machines, .files, .find, .sessions, .dock],
            defaults: defaults
        )
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.machines, .files, .find, .feed, .sessions, .dock],
            "hidden Feed keeps its 4th slot while the displayed tabs permute around it"
        )
    }

    func testModeBarReorderPolicyMovesDraggedPillOverTarget() {
        let displayed: [RightSidebarMode] = [.files, .find, .sessions, .machines]
        XCTAssertEqual(
            RightSidebarModeBarReorderPolicy.displayedOrder(moving: .machines, over: .files, in: displayed),
            [.machines, .files, .find, .sessions]
        )
        XCTAssertEqual(
            RightSidebarModeBarReorderPolicy.displayedOrder(moving: .files, over: .sessions, in: displayed),
            [.find, .sessions, .files, .machines]
        )
        XCTAssertNil(
            RightSidebarModeBarReorderPolicy.displayedOrder(moving: .files, over: .files, in: displayed)
        )
        XCTAssertNil(
            RightSidebarModeBarReorderPolicy.displayedOrder(moving: .feed, over: .files, in: displayed),
            "a mode absent from the bar cannot reorder it"
        )
    }

    func testResetRestoresCanonicalOrderAndVisibility() {
        RightSidebarTabPreferences.move(.machines, offset: -5, defaults: defaults)
        RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults)
        RightSidebarTabPreferences.resetToDefaults(defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.files, .find, .sessions, .feed, .dock, .machines]
        )
        XCTAssertTrue(RightSidebarTabPreferences.hiddenModes(defaults: defaults).isEmpty)
    }

    // MARK: - Positional shortcut defaults

    /// The reported bug: with Feed and Dock hidden (their beta gates default
    /// off), Cloud is the 4th visible tab, so ctrl+4 must focus it. The old
    /// static table pinned Cloud to ctrl+6, three positions past what the mode
    /// bar showed.
    func testCloudDefaultsToControlFourWhenFeedAndDockAreHidden() {
        enableMachinesGate()
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.files, .find, .sessions, .machines]
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .machines, defaults: defaults),
            StoredShortcut(key: "4", command: false, shift: false, option: false, control: true)
        )
    }

    func testAllTabsVisibleKeepsHistoricDigits() {
        enableAllModeGates()
        let expected: [(RightSidebarMode, String)] = [
            (.files, "1"), (.find, "2"), (.sessions, "3"), (.feed, "4"), (.dock, "5"), (.machines, "6"),
        ]
        for (mode, digit) in expected {
            XCTAssertEqual(
                KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: mode, defaults: defaults),
                StoredShortcut(key: digit, command: false, shift: false, option: false, control: true),
                "\(mode) should default to ctrl+\(digit)"
            )
        }
    }

    func testHiddenTabDefaultsToUnboundAndLaterDigitsShift() {
        enableAllModeGates()
        RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults)
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .find, defaults: defaults),
            .unbound
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .sessions, defaults: defaults),
            StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
        )
    }

    func testReorderMovesDigitsWithTheTabs() {
        enableAllModeGates()
        RightSidebarTabPreferences.move(.machines, offset: -5, defaults: defaults)
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .machines, defaults: defaults),
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .files, defaults: defaults),
            StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
        )
    }

    func testPositionalDigitStopsAtNine() {
        enableAllModeGates()
        for (index, mode) in RightSidebarMode.visibleModes(defaults: defaults).enumerated() {
            XCTAssertEqual(
                RightSidebarMode.positionalDigit(for: mode, defaults: defaults),
                index < 9 ? index + 1 : nil
            )
        }
    }

    func testMutationsPostShortcutSettingsDidChange() {
        enableAllModeGates()
        let expectation = expectation(
            forNotification: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )
        RightSidebarTabPreferences.setHidden(true, mode: .feed, defaults: defaults)
        wait(for: [expectation], timeout: 1)
    }
}
