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
    private var savedCloudRemoteOverride: Bool?

    override func setUp() {
        super.setUp()
        suiteName = "RightSidebarTabCustomizationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        let flag = CmuxFeatureFlags.cloudMachinesFlag
        savedCloudRemoteOverride = CmuxFeatureFlags.shared.overrideValue(for: flag)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        CmuxFeatureFlags.shared.setOverride(savedCloudRemoteOverride, for: CmuxFeatureFlags.cloudMachinesFlag)
        savedCloudRemoteOverride = nil
        defaults = nil
        super.tearDown()
    }

    private func enableAllModeGates() {
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
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
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults))
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.files, .sessions, .feed, .dock, .machines]
        )
    }

    func testHidingLastVisibleTabIsRefused() {
        // Hide every tab except Sessions through the regular tab-visibility
        // control; the Dock is no longer beta-gated.
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .files, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .machines, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .dock, defaults: defaults))
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
        // Hide Feed; Dock keeps its slot in the full order. Dragging Cloud
        // before Files must not move Feed or Dock.
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

    /// Four tabs: 40, 60, 40, 50 wide, 4pt apart, from x = 0.
    private func modeBarFrames() -> [CGRect] {
        var x: CGFloat = 0
        return [40, 60, 40, 50].map { width in
            defer { x += width + 4 }
            return CGRect(x: x, y: 0, width: width, height: 24)
        }
    }

    func testModeBarDragLayoutAtRestMovesNothing() throws {
        let layout = try XCTUnwrap(RightSidebarModeBarDragLayout(frames: modeBarFrames(), source: 1))
        XCTAssertEqual(layout.slot(translation: 0), 1)
        XCTAssertEqual(layout.draggedOffset(translation: 0), 0)
        XCTAssertEqual(layout.offsets(slot: 1), [0, 0, 0, 0])
        XCTAssertEqual(layout.reordered(["a", "b", "c", "d"], slot: 1), ["a", "b", "c", "d"])
    }

    func testModeBarDragLayoutNeighbourGivesWayAtHalfTheNarrowerTab() throws {
        // Dragging the 60pt tab right over the 40pt one: it moves once 20pt is covered.
        let layout = try XCTUnwrap(RightSidebarModeBarDragLayout(frames: modeBarFrames(), source: 1))
        XCTAssertEqual(layout.slot(translation: 23), 1, "covers 19pt of the 40pt neighbour")
        XCTAssertEqual(layout.slot(translation: 25), 2, "covers 21pt")
        let offsets = layout.offsets(slot: 2)
        XCTAssertEqual(offsets[2], -64, "the neighbour shifts left by the dragged tab plus a gap")
        XCTAssertEqual(offsets[1], 44, "the dragged tab would land after the neighbour")
        XCTAssertEqual(offsets[0], 0)
        XCTAssertEqual(offsets[3], 0)
        XCTAssertEqual(layout.draggedOffset(translation: 25), 25, "the tab stays under the pointer")
        XCTAssertEqual(
            layout.reordered([RightSidebarMode.files, .find, .sessions, .machines], slot: 2),
            [.files, .sessions, .find, .machines]
        )
    }

    func testModeBarDragLayoutDraggingLeftShiftsTheTabsBefore() throws {
        let layout = try XCTUnwrap(RightSidebarModeBarDragLayout(frames: modeBarFrames(), source: 3))
        XCTAssertEqual(layout.slot(translation: -200), 0)
        let offsets = layout.offsets(slot: 0)
        XCTAssertEqual(offsets[3], -152, "the last tab lands at the bar's start")
        XCTAssertEqual(offsets[0], 54)
        XCTAssertEqual(offsets[1], 54)
        XCTAssertEqual(offsets[2], 54)
    }

    func testModeBarDragLayoutResistsPastTheBarEnds() throws {
        let layout = try XCTUnwrap(RightSidebarModeBarDragLayout(frames: modeBarFrames(), source: 0))
        let left = layout.draggedOffset(translation: -100)
        XCTAssertLessThan(left, 0)
        XCTAssertGreaterThan(left, -RightSidebarModeBarDragLayout.overscrollLimit)
        let right = layout.draggedOffset(translation: 1000)
        XCTAssertGreaterThan(right, 162, "held at the bar's end (162pt) plus some give")
        XCTAssertLessThan(right, 162 + RightSidebarModeBarDragLayout.overscrollLimit)
        XCTAssertEqual(layout.slot(translation: 1000), 3)
    }

    func testModeBarDragLayoutLeavesTheBarOnlyWellOutsideIt() {
        let tab = CGRect(x: 0, y: 7, width: 40, height: 24)
        XCTAssertFalse(RightSidebarModeBarDragLayout.leavesBar(pointerY: 40, tabFrame: tab, barHeight: 38))
        XCTAssertTrue(RightSidebarModeBarDragLayout.leavesBar(pointerY: 51, tabFrame: tab, barHeight: 38))
        XCTAssertTrue(RightSidebarModeBarDragLayout.leavesBar(pointerY: -13, tabFrame: tab, barHeight: 38))
        XCTAssertNil(RightSidebarModeBarDragLayout(frames: [], source: 0))
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

    /// With Feed and Dock hidden through the regular tab-visibility controls,
    /// Cloud is the 4th visible tab, so ctrl+4 must focus it.
    func testCloudDefaultsToControlFourWhenFeedAndDockAreHidden() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableMachinesGate()
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .feed, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .dock, defaults: defaults))
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
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
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
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
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
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
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
