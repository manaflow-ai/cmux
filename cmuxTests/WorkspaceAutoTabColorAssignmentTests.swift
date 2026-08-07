import AppKit
import CmuxSettings
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for auto-assigned workspace rail colors
/// (`workspaceColors.autoAssignColors`).
///
/// Two properties are load-bearing:
/// 1. Every palette color is used once before any repeats, so rails stay
///    distinct at realistic workspace counts.
/// 2. Auto colors reach the **rail only**. The selected workspace is identified
///    by its filled row background, so an auto color that leaked into
///    `sidebarWorkspaceRowBackgroundStyle` would make the selected row just one
///    more colored row.
@Suite struct WorkspaceAutoTabColorAssignmentTests {
    private static let palette: [WorkspaceTabColorEntry] = [
        WorkspaceTabColorEntry(name: "Red", hex: "#C0392B"),
        WorkspaceTabColorEntry(name: "Green", hex: "#196F3D"),
        WorkspaceTabColorEntry(name: "Blue", hex: "#1565C0"),
    ]

    private static func suite() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    /// Assigns `count` fresh workspaces and returns their colors in order.
    @discardableResult
    private static func assign(
        count: Int,
        defaults: UserDefaults,
        palette: [WorkspaceTabColorEntry] = palette,
        ids: [UUID]? = nil,
        manualColorHexes: [String] = []
    ) -> [UUID: String] {
        let ids = ids ?? (0..<count).map { _ in UUID() }
        return WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: manualColorHexes,
            palette: palette,
            defaults: defaults
        ).reduce(into: [UUID: String]()) { out, pair in
            if let id = UUID(uuidString: pair.key) { out[id] = pair.value }
        }
    }

    // MARK: - Allocation rules

    /// The core promise: no duplicates while colors remain unused.
    @Test
    func usesEveryPaletteColorBeforeRepeatingAny() {
        let defaults = Self.suite()
        let assigned = Self.assign(count: 3, defaults: defaults)

        #expect(assigned.count == 3)
        #expect(Set(assigned.values).count == 3)
    }

    @Test
    func recyclesTheLeastUsedColorOnceThePaletteIsExhausted() {
        let defaults = Self.suite()
        let assigned = Self.assign(count: 7, defaults: defaults)
        var counts: [String: Int] = [:]
        for hex in assigned.values { counts[hex, default: 0] += 1 }

        #expect(assigned.count == 7)
        // 7 workspaces over 3 colors: 3/2/2, never 4/2/1.
        #expect(counts.count == 3)
        #expect(counts.values.max()! - counts.values.min()! <= 1)
    }

    @Test
    func doesNotDuplicateAColorTheUserChoseManually() {
        let defaults = Self.suite()
        let assigned = Self.assign(count: 2, defaults: defaults, manualColorHexes: ["#C0392B"])

        #expect(!assigned.values.contains("#C0392B"))
    }

    @Test
    func ignoresManualColorsOutsideThePalette() {
        let defaults = Self.suite()
        let assigned = Self.assign(count: 3, defaults: defaults, manualColorHexes: ["#ABCDEF"])

        #expect(Set(assigned.values).count == 3)
    }

    @Test
    func returnsNilForAnEmptyPalette() {
        #expect(WorkspaceAutoTabColorAssignment.nextColorHex(palette: [], usedHexes: []) == nil)
    }

    @Test
    func allocationIsCaseInsensitiveAboutHexes() {
        let hex = WorkspaceAutoTabColorAssignment.nextColorHex(
            palette: Self.palette,
            usedHexes: ["#c0392b", "#196f3d"]
        )

        #expect(hex == "#1565C0")
    }

    // MARK: - Stability

    /// The reason assignments are persisted rather than recomputed.
    @Test
    func deletingAWorkspaceDoesNotRecolorTheSurvivors() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let before = Self.assign(count: 3, defaults: defaults, ids: ids)

        let survivors = Array(ids.dropFirst())
        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: survivors,
            liveIds: Set(survivors),
            manualColorHexes: [],
            palette: Self.palette,
            defaults: defaults
        )

        for id in survivors {
            #expect(after[id.uuidString] == before[id])
        }
    }

    @Test
    func reorderingDoesNotRecolorWorkspaces() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let before = Self.assign(count: 3, defaults: defaults, ids: ids)

        let reversed = Array(ids.reversed())
        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: reversed,
            liveIds: Set(reversed),
            manualColorHexes: [],
            palette: Self.palette,
            defaults: defaults
        )

        for id in ids {
            #expect(after[id.uuidString] == before[id])
        }
    }

    @Test
    func addingAWorkspaceKeepsExistingColorsAndTakesAnUnusedOne() {
        let defaults = Self.suite()
        let ids = (0..<2).map { _ in UUID() }
        let before = Self.assign(count: 2, defaults: defaults, ids: ids)

        let newId = UUID()
        let all = ids + [newId]
        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: all,
            liveIds: Set(all),
            manualColorHexes: [],
            palette: Self.palette,
            defaults: defaults
        )

        for id in ids { #expect(after[id.uuidString] == before[id]) }
        #expect(Set(after.values).count == 3)
    }

    /// A deleted workspace's color must go back into circulation, otherwise a
    /// long-lived install slowly runs out of colors.
    @Test
    func aDeletedWorkspaceReleasesItsColorForReuse() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let before = Self.assign(count: 3, defaults: defaults, ids: ids)

        let survivor = ids[0]
        let newId = UUID()
        let live = [survivor, newId]
        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: live,
            liveIds: Set(live),
            manualColorHexes: [],
            palette: Self.palette,
            defaults: defaults
        )

        #expect(after[survivor.uuidString] == before[survivor])
        let freed = [before[ids[1]], before[ids[2]]].compactMap { $0 }
        #expect(freed.contains(after[newId.uuidString] ?? ""))
    }

    /// Entries for workspaces the caller cannot see are kept, because a caller
    /// only sees one window and a partial list would otherwise delete the rest.
    @Test
    func doesNotDeleteAssignmentsForWorkspacesItCannotSee() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let before = Self.assign(count: 3, defaults: defaults, ids: ids)

        let visible = [ids[0]]
        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: visible,
            liveIds: Set(visible),
            manualColorHexes: [],
            palette: Self.palette,
            defaults: defaults
        )

        #expect(after.count == 3)
        for id in ids {
            #expect(after[id.uuidString] == before[id])
        }
    }

    @Test
    func reassignsWhenTheStoredColorLeavesThePalette() {
        let defaults = Self.suite()
        let ids = [UUID()]
        Self.assign(count: 1, defaults: defaults, palette: [Self.palette[0]], ids: ids)

        let replacement = [WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B")]
        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: replacement,
            defaults: defaults
        )

        #expect(after[ids[0].uuidString] == "#006B6B")
    }

    // MARK: - Enablement rules

    @Test
    func railColorIsNilWhenTheFeatureIsOff() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            isEnabled: false,
            indicatorStyle: .leftRail,
            customColorHex: nil,
            assignedColorHex: "#1565C0"
        ) == nil)
    }

    /// Solid fill paints the whole row, which would collide with the selected
    /// row's background.
    @Test
    func railColorIsNilUnderSolidFill() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            isEnabled: true,
            indicatorStyle: .solidFill,
            customColorHex: nil,
            assignedColorHex: "#1565C0"
        ) == nil)
    }

    @Test
    func manualColorWinsOverTheAutoAssignedColor() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            isEnabled: true,
            indicatorStyle: .leftRail,
            customColorHex: "#ABCDEF",
            assignedColorHex: "#1565C0"
        ) == nil)
    }

    @Test
    func railColorResolvesWhenEnabledOnLeftRailWithoutAManualColor() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            isEnabled: true,
            indicatorStyle: .leftRail,
            customColorHex: nil,
            assignedColorHex: "#1565C0"
        ) == "#1565C0")
    }

    @Test
    func railColorIsNilWithoutAnAssignment() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            isEnabled: true,
            indicatorStyle: .leftRail,
            customColorHex: nil,
            assignedColorHex: nil
        ) == nil)
    }

    // MARK: - Manual colors

    /// Auto-assigning must not take the color picker away: the user can still
    /// right-click a workspace and choose a color, and that choice wins.
    @Test
    func settingAManualColorDoesNotRecolorTheOtherWorkspaces() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let before = Self.assign(count: 3, defaults: defaults, ids: ids)

        // Workspace 0 gets a manual color, so it drops out of `needingAssignment`.
        let stillAuto = Array(ids.dropFirst())
        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: stillAuto,
            liveIds: Set(ids),
            manualColorHexes: ["#ABCDEF"],
            palette: Self.palette,
            defaults: defaults
        )

        for id in stillAuto {
            #expect(after[id.uuidString] == before[id])
        }
    }

    /// The manually colored workspace keeps its reservation, so clearing the
    /// manual color hands back the color it had before.
    @Test
    func clearingAManualColorRestoresTheOriginalAutoColor() {
        let defaults = Self.suite()
        let ids = (0..<2).map { _ in UUID() }
        let before = Self.assign(count: 2, defaults: defaults, ids: ids)

        WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: [ids[1]],
            liveIds: Set(ids),
            manualColorHexes: ["#ABCDEF"],
            palette: Self.palette,
            defaults: defaults
        )
        let restored = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: Self.palette,
            defaults: defaults
        )

        #expect(restored[ids[0].uuidString] == before[ids[0]])
    }

    /// The failure this guards against: a reconcile that ran mid-restore, when
    /// no workspaces were loaded yet, used to wipe the table and hand every
    /// workspace a different color on the next pass.
    @Test
    func reconcileWithNoLiveWorkspacesKeepsEverything() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let before = Self.assign(count: 3, defaults: defaults, ids: ids)

        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: [],
            liveIds: [],
            manualColorHexes: [],
            palette: Self.palette,
            defaults: defaults
        )

        for id in ids {
            #expect(after[id.uuidString] == before[id])
        }
    }

    /// The table still cannot grow without bound.
    @Test
    func collectsStaleEntriesOnceTheTableGrowsPastTheThreshold() {
        let defaults = Self.suite()
        let ids = (0..<(WorkspaceAutoColorAssignmentStore.pruneThreshold + 1)).map { _ in UUID() }
        Self.assign(count: ids.count, defaults: defaults, ids: ids)

        let survivor = [ids[0]]
        let after = WorkspaceAutoColorAssignmentStore.reconcile(
            needingAssignment: survivor,
            liveIds: Set(survivor),
            manualColorHexes: [],
            palette: Self.palette,
            defaults: defaults
        )

        #expect(after.count == 1)
    }

    // MARK: - Perceptual spread

    /// The first two workspaces are the common case, so they must not get two
    /// shades of the same color. Straight palette order hands out Red then
    /// Crimson (ΔE 7.7), which reads as one color on a 3pt rail.
    @Test
    func firstTwoWorkspacesGetObviouslyDifferentColors() throws {
        let defaults = Self.suite()
        let assigned = Self.assign(count: 2, defaults: defaults, palette: WorkspaceTabColorSettings.palette(defaults: defaults))
        let hexes = Array(assigned.values)
        let first = try #require(LabColor(hex: hexes[0]))
        let second = try #require(LabColor(hex: hexes[1]))

        #expect(first.distance(to: second) > 100)
    }

    /// A 3pt rail needs roughly ΔE 10 to read as a different color at a glance.
    @Test
    func everyPairOfAssignedColorsStaysDistinguishable() throws {
        let defaults = Self.suite()
        let palette = WorkspaceTabColorSettings.palette(defaults: defaults)
        let assigned = Self.assign(count: 8, defaults: defaults, palette: palette)
        let labs = try assigned.values.map { try #require(LabColor(hex: $0)) }

        for i in labs.indices {
            for j in labs.indices where j > i {
                #expect(labs[i].distance(to: labs[j]) > 10)
            }
        }
    }

    @Test
    func allocationAvoidsColorsThatLookLikeAManualColor() throws {
        let defaults = Self.suite()
        let palette = WorkspaceTabColorSettings.palette(defaults: defaults)
        // Red is manual, so Crimson (its nearest neighbour) must not be picked.
        let assigned = Self.assign(
            count: 1,
            defaults: defaults,
            palette: palette,
            manualColorHexes: ["#C0392B"]
        )
        let firstHex = try #require(assigned.values.first)
        let picked = try #require(LabColor(hex: firstHex))
        let red = try #require(LabColor(hex: "#C0392B"))

        #expect(picked.distance(to: red) > 10)
    }

    @Test
    func labDistanceIsZeroForTheSameColorAndSymmetric() throws {
        let red = try #require(LabColor(hex: "#C0392B"))
        let blue = try #require(LabColor(hex: "#1565C0"))

        #expect(red.distance(to: red) == 0)
        #expect(red.distance(to: blue) == blue.distance(to: red))
    }

    @Test
    func labColorRejectsMalformedHexes() {
        #expect(LabColor(hex: "") == nil)
        #expect(LabColor(hex: "#12345") == nil)
        #expect(LabColor(hex: "#GGGGGG") == nil)
        #expect(LabColor(hex: "#ABC") != nil)
    }

    // MARK: - Rendering boundary

    @Test
    func autoColorDrawsTheRail() {
        let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: .leftRail,
            customColorHex: nil,
            autoRailColorHex: "#1565C0",
            colorScheme: .dark
        )

        #expect(railColor != nil)
    }

    @Test
    func manualColorTakesPrecedenceInTheRailRenderer() {
        let manual = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: .leftRail,
            customColorHex: "#C0392B",
            autoRailColorHex: "#1565C0",
            colorScheme: .dark
        )
        let expected = WorkspaceTabColorSettings.displayNSColor(
            hex: "#C0392B",
            colorScheme: .dark,
            forceBright: true
        )

        #expect(manual == expected)
    }

    /// Regression guard for the selection affordance: the selected row keeps
    /// the selection background, and an unselected auto-colored row keeps a
    /// clear background, so exactly one row reads as selected.
    @Test
    func autoColorNeverChangesTheRowBackground() {
        let selected = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: true,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: .dark,
            sidebarSelectionColorHex: nil
        )
        let unselected = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: false,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: .dark,
            sidebarSelectionColorHex: nil
        )

        #expect(selected.color != nil)
        #expect(selected.opacity == 1)
        #expect(unselected == .clear)
    }

    // MARK: - Settings wiring

    @Test
    func settingsSnapshotDefaultsToDisabledAndSkipsTheAssignmentRead() {
        let defaults = Self.suite()
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

        #expect(!settings.autoAssignsWorkspaceColors)
        #expect(settings.autoAssignedColorHexes.isEmpty)
    }

    @Test
    func settingsSnapshotLoadsAssignmentsWhenEnabled() {
        let defaults = Self.suite()
        defaults.set(true, forKey: WorkspaceColorsCatalogSection().autoAssignColors.userDefaultsKey)
        let ids = [UUID()]
        Self.assign(count: 1, defaults: defaults, ids: ids)

        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

        #expect(settings.autoAssignsWorkspaceColors)
        #expect(settings.autoAssignedColorHexes[ids[0].uuidString] != nil)
    }

    /// Disabling the feature must not discard assignments, so re-enabling it
    /// restores the same colors instead of reshuffling them.
    @Test
    func disablingKeepsStoredAssignments() {
        let defaults = Self.suite()
        let ids = [UUID()]
        let before = Self.assign(count: 1, defaults: defaults, ids: ids)

        defaults.set(false, forKey: WorkspaceColorsCatalogSection().autoAssignColors.userDefaultsKey)

        #expect(WorkspaceAutoColorAssignmentStore.assignedColorHex(
            for: ids[0],
            defaults: defaults
        ) == before[ids[0]])
    }
}
