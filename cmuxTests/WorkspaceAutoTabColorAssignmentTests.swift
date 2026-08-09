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
/// (`workspaceColors.indicatorStyle = leftRailAuto`).
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
        return WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: manualColorHexes,
            palette: palette
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

    /// Repeated used colors are deduplicated before the Lab conversion, which
    /// is what keeps allocation from doing quadratic work as workspaces are
    /// added. Deduplicating must not change the answer: distance folds with
    /// `min`, so a color counted twice is no further away than once.
    ///
    /// The repeats here are a manual color outside the palette, so they cannot
    /// move the use counts — the whole palette stays tied and the choice is
    /// decided purely by the deduplicated Lab comparison.
    @Test
    func repeatedUsedColorsDoNotChangeTheChoice() {
        let saturated = ["#C0392B", "#196F3D", "#1565C0"]
        let once = WorkspaceAutoTabColorAssignment.nextColorHex(
            palette: Self.palette,
            usedHexes: saturated + ["#FF00FF"]
        )
        let repeated = WorkspaceAutoTabColorAssignment.nextColorHex(
            palette: Self.palette,
            usedHexes: saturated + ["#FF00FF", "#FF00FF", "#ff00ff"]
        )

        #expect(once != nil)
        #expect(repeated == once)
    }

    // MARK: - Stability

    /// The reason assignments are persisted rather than recomputed.
    @Test
    func deletingAWorkspaceDoesNotRecolorTheSurvivors() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let before = Self.assign(count: 3, defaults: defaults, ids: ids)

        let survivors = Array(ids.dropFirst())
        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: survivors,
            liveIds: Set(survivors),
            manualColorHexes: [],
            palette: Self.palette
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
        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: reversed,
            liveIds: Set(reversed),
            manualColorHexes: [],
            palette: Self.palette
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
        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: all,
            liveIds: Set(all),
            manualColorHexes: [],
            palette: Self.palette
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
        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: live,
            liveIds: Set(live),
            manualColorHexes: [],
            palette: Self.palette
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
        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: visible,
            liveIds: Set(visible),
            manualColorHexes: [],
            palette: Self.palette
        )

        #expect(after.count == 3)
        for id in ids {
            #expect(after[id.uuidString] == before[id])
        }
    }

    /// Existing colors are durable user-facing identity, even if a legacy or
    /// interrupted run left two workspaces with the same assignment.
    @Test
    func preservesTwoVisibleWorkspacesSharingAStoredColor() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let clashing = Self.palette[0].hex
        defaults.set(
            [ids[0].uuidString: clashing, ids[1].uuidString: clashing, ids[2].uuidString: Self.palette[1].hex],
            forKey: WorkspaceAutoColorAssignmentStore.defaultsKey
        )

        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: Self.palette
        )

        #expect(after[ids[0].uuidString] == clashing)
        #expect(after[ids[1].uuidString] == clashing)
        #expect(after[ids[2].uuidString] == Self.palette[1].hex)
    }

    /// Healing must not be an excuse to churn colors: a workspace whose color
    /// only clashes with an entry for a workspace that is gone keeps it.
    @Test
    func doesNotRecolorAWorkspaceThatClashesOnlyWithADeadEntry() {
        let defaults = Self.suite()
        let live = UUID()
        let dead = UUID()
        let shared = Self.palette[0].hex
        defaults.set(
            [live.uuidString: shared, dead.uuidString: shared],
            forKey: WorkspaceAutoColorAssignmentStore.defaultsKey
        )

        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: [live],
            liveIds: [live],
            manualColorHexes: [],
            palette: Self.palette
        )

        #expect(after[live.uuidString] == shared)
    }

    /// A manual color affects future allocation but does not recolor another
    /// existing workspace.
    @Test
    func manualColorDoesNotRecolorAnExistingAutoWorkspace() {
        let defaults = Self.suite()
        let id = UUID()
        let manual = Self.palette[0].hex
        defaults.set(
            [id.uuidString: manual],
            forKey: WorkspaceAutoColorAssignmentStore.defaultsKey
        )

        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: [id],
            liveIds: [id],
            manualColorHexes: [manual],
            palette: Self.palette
        )

        #expect(after[id.uuidString] == manual)
    }

    /// With more workspaces than colors, duplicates are unavoidable, so the
    /// pass must settle instead of reshuffling on every reconcile.
    @Test
    func stopsChurningOnceThePaletteIsExhausted() {
        let defaults = Self.suite()
        let ids = (0..<(Self.palette.count + 4)).map { _ in UUID() }

        let first = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: Self.palette
        )
        let second = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: Self.palette
        )

        #expect(first == second)
    }

    /// Once colors repeat, deleting the only workspace using one color must
    /// not reshuffle the surviving workspaces just to fill that newly empty
    /// palette slot. Stability takes precedence; a future workspace can reuse
    /// the released color.
    @Test
    func deletingAUniqueColorAfterExhaustionDoesNotRecolorSurvivors() throws {
        let defaults = Self.suite()
        let ids = (0..<(Self.palette.count + 2)).map { _ in UUID() }
        let before = Self.assign(count: ids.count, defaults: defaults, ids: ids)
        let counts = Dictionary(grouping: before.values, by: { $0 }).mapValues(\.count)
        let uniqueColor = try #require(counts.first(where: { $0.value == 1 })?.key)
        let deleted = try #require(ids.first(where: { before[$0] == uniqueColor }))
        let survivors = ids.filter { $0 != deleted }

        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: survivors,
            liveIds: Set(survivors),
            manualColorHexes: [],
            palette: Self.palette
        )

        for id in survivors {
            #expect(after[id.uuidString] == before[id])
        }
    }

    /// An unavoidable duplicate still counts as a use of that color. Otherwise
    /// the next new workspace can reuse it again and skew a balanced 2/1/1
    /// distribution to 3/1/1.
    @Test
    func preservedDuplicateCountsTowardLeastUsedRecycling() {
        let defaults = Self.suite()
        let ids = (0..<5).map { _ in UUID() }
        defaults.set(
            [
                ids[0].uuidString: Self.palette[0].hex,
                ids[1].uuidString: Self.palette[0].hex,
                ids[2].uuidString: Self.palette[1].hex,
                ids[3].uuidString: Self.palette[2].hex,
            ],
            forKey: WorkspaceAutoColorAssignmentStore.defaultsKey
        )

        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: Self.palette
        )
        var counts: [String: Int] = [:]
        for id in ids {
            if let hex = after[id.uuidString] {
                counts[hex, default: 0] += 1
            }
        }

        #expect(counts.count == Self.palette.count)
        #expect(counts.values.max()! - counts.values.min()! <= 1)
    }

    /// New workspaces can sort ahead of older workspaces in the sidebar. The
    /// allocator must count every existing assignment before filling that new
    /// gap, or it can produce a 3/1/1 distribution.
    @Test
    func newWorkspaceBeforePreservedDuplicateStillBalancesRecycling() {
        let defaults = Self.suite()
        let ids = (0..<5).map { _ in UUID() }
        let existing = [
            ids[1].uuidString: Self.palette[0].hex,
            ids[2].uuidString: Self.palette[0].hex,
            ids[3].uuidString: Self.palette[1].hex,
            ids[4].uuidString: Self.palette[2].hex,
        ]
        defaults.set(existing, forKey: WorkspaceAutoColorAssignmentStore.defaultsKey)

        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: Self.palette
        )
        var counts: [String: Int] = [:]
        for id in ids {
            if let hex = after[id.uuidString] {
                counts[hex, default: 0] += 1
            }
        }

        #expect(counts.count == Self.palette.count)
        #expect(counts.values.max()! - counts.values.min()! <= 1)
        for id in ids.dropFirst() {
            #expect(after[id.uuidString] == existing[id.uuidString])
        }

        let settled = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: Self.palette
        )
        #expect(settled == after)
    }

    @Test
    func reassignsWhenTheStoredColorLeavesThePalette() {
        let defaults = Self.suite()
        let ids = [UUID()]
        Self.assign(count: 1, defaults: defaults, palette: [Self.palette[0]], ids: ids)

        let replacement = [WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B")]
        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: replacement
        )

        #expect(after[ids[0].uuidString] == "#006B6B")
    }

    // MARK: - Enablement rules

    @Test
    func railColorIsNilForManualLeftRail() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
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
            indicatorStyle: .solidFill,
            customColorHex: nil,
            assignedColorHex: "#1565C0"
        ) == nil)
    }

    @Test
    func manualColorWinsOverTheAutoAssignedColor() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            indicatorStyle: .leftRailAuto,
            customColorHex: "#ABCDEF",
            assignedColorHex: "#1565C0"
        ) == nil)
    }

    @Test
    func railColorResolvesForLeftRailAutoWithoutAManualColor() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            indicatorStyle: .leftRailAuto,
            customColorHex: nil,
            assignedColorHex: "#1565C0"
        ) == "#1565C0")
    }

    @Test
    func railColorIsNilWithoutAnAssignment() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            indicatorStyle: .leftRailAuto,
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
        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: stillAuto,
            liveIds: Set(ids),
            manualColorHexes: ["#ABCDEF"],
            palette: Self.palette
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

        WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: [ids[1]],
            liveIds: Set(ids),
            manualColorHexes: ["#ABCDEF"],
            palette: Self.palette
        )
        let restored = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: ids,
            liveIds: Set(ids),
            manualColorHexes: [],
            palette: Self.palette
        )

        #expect(restored[ids[0].uuidString] == before[ids[0]])
    }

    /// A manual override hides, but does not surrender, the workspace's saved
    /// auto color. Otherwise a newly created workspace can take that color and
    /// clearing the override has to recolor one of them.
    @Test
    func manualOverrideKeepsTheSavedAutoColorReserved() throws {
        let defaults = Self.suite()
        let overridden = UUID()
        let newWorkspace = UUID()
        let manualColor = "#ABCDEF"
        let reservedColor = try #require(
            WorkspaceAutoTabColorAssignment.nextColorHex(
                palette: Self.palette,
                usedHexes: [manualColor]
            )
        )
        defaults.set(
            [overridden.uuidString: reservedColor],
            forKey: WorkspaceAutoColorAssignmentStore.defaultsKey
        )

        let whileOverridden = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: [newWorkspace],
            liveIds: [overridden, newWorkspace],
            manualColorHexes: [manualColor],
            palette: Self.palette
        )
        let newWorkspaceColor = try #require(whileOverridden[newWorkspace.uuidString])

        #expect(newWorkspaceColor != reservedColor)

        let afterClearing = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: [overridden, newWorkspace],
            liveIds: [overridden, newWorkspace],
            manualColorHexes: [],
            palette: Self.palette
        )

        #expect(afterClearing[overridden.uuidString] == reservedColor)
        #expect(afterClearing[newWorkspace.uuidString] == newWorkspaceColor)
    }

    /// The reservation has to survive a saturated palette too, which is the
    /// case the override test above cannot reach: its manual color sits outside
    /// the palette, so a never-used color is always available and the reserved
    /// one is never a candidate.
    ///
    /// Once every color has a holder, the reserved color sits at the same use
    /// count as the rest, so palette order alone handed it to the new
    /// workspace. Clearing the manual color then left two live workspaces
    /// sharing one rail permanently — assignments are never rewritten once
    /// made — even though a free color was available for them.
    @Test
    func manualOverrideKeepsItsReservationWhenEveryColorHasAHolder() throws {
        let defaults = Self.suite()
        let overridden = UUID()
        let otherManual = UUID()
        let newWorkspace = UUID()

        Self.assign(count: 1, defaults: defaults, ids: [overridden])
        let reservedColor = try #require(
            WorkspaceAutoColorAssignmentStore(defaults: defaults).assignedColorHex(for: overridden)
        )
        // Every remaining palette color goes to a manual override, so all of
        // them — including the reserved one — are spoken for exactly once.
        let manualColors = Self.palette.map(\.hex).filter {
            WorkspaceAutoTabColorAssignment.normalized($0)
                != WorkspaceAutoTabColorAssignment.normalized(reservedColor)
        }
        let overriddenManualColor = try #require(manualColors.first)

        let whileOverridden = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: [newWorkspace],
            liveIds: [overridden, otherManual, newWorkspace],
            manualColorHexes: manualColors,
            palette: Self.palette
        )

        #expect(whileOverridden[newWorkspace.uuidString] != reservedColor)

        // Only the reserved workspace reverts; the other manual color stays, so
        // the two auto workspaces still have distinct colors available.
        let afterClearing = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: [overridden, newWorkspace],
            liveIds: [overridden, otherManual, newWorkspace],
            manualColorHexes: manualColors.filter { $0 != overriddenManualColor },
            palette: Self.palette
        )

        #expect(afterClearing[overridden.uuidString] == reservedColor)
        #expect(afterClearing[overridden.uuidString] != afterClearing[newWorkspace.uuidString])
    }

    /// The failure this guards against: a reconcile that ran mid-restore, when
    /// no workspaces were loaded yet, used to wipe the table and hand every
    /// workspace a different color on the next pass.
    @Test
    func reconcileWithNoLiveWorkspacesKeepsEverything() {
        let defaults = Self.suite()
        let ids = (0..<3).map { _ in UUID() }
        let before = Self.assign(count: 3, defaults: defaults, ids: ids)

        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: [],
            liveIds: [],
            manualColorHexes: [],
            palette: Self.palette
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
        let after = WorkspaceAutoColorAssignmentStore(defaults: defaults).reconcile(
            needingAssignment: survivor,
            liveIds: Set(survivor),
            manualColorHexes: [],
            palette: Self.palette
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

    /// One allocator reused across a run must hand out exactly what repeated
    /// single-shot calls would, since reconciling now allocates in a batch to
    /// avoid recounting the whole history for every workspace.
    @Test
    func batchedAllocationMatchesRepeatedSingleShotCalls() {
        let manual = ["#FF00FF"]
        var allocator = WorkspaceAutoTabColorAllocator(
            palette: Self.palette,
            usedHexes: manual
        )
        var batched: [String] = []
        for _ in 0..<7 {
            guard let hex = allocator.next() else { break }
            batched.append(hex)
        }

        var used = manual
        var oneAtATime: [String] = []
        for _ in 0..<7 {
            guard let hex = WorkspaceAutoTabColorAssignment.nextColorHex(
                palette: Self.palette,
                usedHexes: used
            ) else { break }
            oneAtATime.append(hex)
            used.append(hex)
        }

        #expect(batched.count == 7)
        #expect(batched == oneAtATime)
        // Sanity: the run exhausts the 3-color palette twice over and recycles
        // evenly rather than repeating one color.
        #expect(Set(batched.prefix(3)).count == 3)
    }

    /// A palette entry that cannot be parsed cannot be drawn either, so it must
    /// never be handed out while a drawable entry ties with it — including on
    /// the very first pick, when nothing is on screen to compare against.
    @Test
    func skipsPaletteEntriesThatCannotBeRendered() {
        let palette = [
            WorkspaceTabColorEntry(name: "Broken", hex: "#ZZZZZZ"),
            WorkspaceTabColorEntry(name: "Green", hex: "#196F3D"),
        ]

        var allocator = WorkspaceAutoTabColorAllocator(palette: palette, usedHexes: [])
        #expect(allocator.next() == "#196F3D")

        #expect(
            WorkspaceAutoTabColorAssignment.nextColorHex(palette: palette, usedHexes: []) == "#196F3D"
        )

        // With nothing drawable left there is no honest answer, so allocation
        // declines rather than assigning a color the rail cannot show.
        var unusable = WorkspaceAutoTabColorAllocator(
            palette: [WorkspaceTabColorEntry(name: "Broken", hex: "#ZZZZZZ")],
            usedHexes: []
        )
        #expect(unusable.next() == nil)
    }

    /// The parser accepts exactly what `WorkspaceTabColorSettings.normalizedHex`
    /// produces, so a color that cannot be rendered cannot influence allocation.
    @Test
    func labColorRejectsMalformedHexes() {
        #expect(LabColor(hex: "") == nil)
        #expect(LabColor(hex: "#12345") == nil)
        #expect(LabColor(hex: "#GGGGGG") == nil)
        #expect(LabColor(hex: "#ABC") == nil)
        #expect(LabColor(hex: "#AABBCC") != nil)
        #expect(LabColor(hex: "AABBCC") != nil)
    }

    // MARK: - Rendering boundary

    @Test
    func autoColorDrawsTheRail() {
        let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: .leftRailAuto,
            customColorHex: nil,
            autoRailColorHex: "#1565C0",
            colorScheme: .dark
        )

        #expect(railColor != nil)
    }

    @Test
    func manualColorTakesPrecedenceInTheRailRenderer() {
        let manual = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: .leftRailAuto,
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

    @Test
    func manualLeftRailIgnoresAStaleAutoColor() {
        #expect(sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: .leftRail,
            customColorHex: nil,
            autoRailColorHex: "#1565C0",
            colorScheme: .dark
        ) == nil)
    }

    /// The allocator treats an empty manual color as uncolored and hands the
    /// workspace an auto color, so the resolver and the renderer must agree —
    /// otherwise a workspace gets a color assigned and then no rail drawn.
    @Test
    func anEmptyManualColorStillShowsTheAutoRail() {
        #expect(WorkspaceAutoTabColorAssignment.railColorHex(
            indicatorStyle: .leftRailAuto,
            customColorHex: "",
            assignedColorHex: "#1565C0"
        ) == "#1565C0")

        let rendered = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: .leftRailAuto,
            customColorHex: "",
            autoRailColorHex: "#1565C0",
            colorScheme: .dark
        )
        let expected = WorkspaceTabColorSettings.displayNSColor(
            hex: "#1565C0",
            colorScheme: .dark,
            forceBright: true
        )

        #expect(rendered == expected)
    }

    /// Regression guard for the selection affordance: the selected row keeps
    /// the selection background, and an unselected auto-colored row keeps a
    /// clear background, so exactly one row reads as selected.
    @Test
    func autoColorNeverChangesTheRowBackground() {
        let selected = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRailAuto,
            isActive: true,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: .dark,
            sidebarSelectionColorHex: nil
        )
        let unselected = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRailAuto,
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

        #expect(settings.activeTabIndicatorStyle == .leftRail)
        #expect(settings.autoAssignedColorHexes.isEmpty)
    }

    @Test
    func settingsSnapshotLoadsAssignmentsWhenEnabled() {
        let defaults = Self.suite()
        let key = WorkspaceColorsCatalogSection().indicatorStyle
        UserDefaultsSettingsClient(defaults: defaults).set(.leftRailAuto, for: key)
        let ids = [UUID()]
        Self.assign(count: 1, defaults: defaults, ids: ids)

        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

        #expect(settings.activeTabIndicatorStyle == .leftRailAuto)
        #expect(settings.autoAssignedColorHexes[ids[0].uuidString] != nil)
    }

    /// Disabling the feature must not discard assignments, so re-enabling it
    /// restores the same colors instead of reshuffling them.
    @Test
    func disablingKeepsStoredAssignments() {
        let defaults = Self.suite()
        let ids = [UUID()]
        let before = Self.assign(count: 1, defaults: defaults, ids: ids)

        UserDefaultsSettingsClient(defaults: defaults).set(
            .leftRail,
            for: WorkspaceColorsCatalogSection().indicatorStyle
        )

        #expect(WorkspaceAutoColorAssignmentStore(defaults: defaults).assignedColorHex(
            for: ids[0]
        ) == before[ids[0]])
    }

    /// The real settings-change path covers the full lifecycle: one existing
    /// workspace gets a rail on enable; disabling hides auto rails; re-enabling
    /// colors every workspace opened while disabled; and a workspace created
    /// while enabled joins automatically.
    @MainActor
    @Test
    func enablingAndDisablingAppliesToEveryOpenWorkspace() async throws {
        let defaults = Self.suite()
        let key = WorkspaceColorsCatalogSection().indicatorStyle
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            settings: settings,
            autoWorkspaceColorDefaults: defaults,
            closeTabWarningDefaults: defaults
        )
        let first = try #require(manager.selectedWorkspace)

        // Exercise the same defaults notification that the Settings model emits.
        settings.set(.leftRailAuto, for: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(await Self.waitUntil { Self.railColor(for: first, defaults: defaults) != nil })

        settings.set(.leftRail, for: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(await Self.waitUntil { Self.railColor(for: first, defaults: defaults) == nil })

        let second = manager.addWorkspace(
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false
        )

        settings.set(.leftRailAuto, for: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(await Self.waitUntil {
            Self.distinctRailColors(for: [first, second], defaults: defaults) == 2
        })

        let third = manager.addWorkspace(
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false
        )
        // No settings change here: a workspace created while the feature is on
        // must be colored by the reconcile its own creation scheduled.
        #expect(await Self.waitUntil {
            Self.distinctRailColors(for: [first, second, third], defaults: defaults) == 3
        })

        let storedBeforeDisable = WorkspaceAutoColorAssignmentStore(defaults: defaults).assignments()
        settings.set(.leftRail, for: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(await Self.waitUntil {
            [first, second, third].allSatisfy { Self.railColor(for: $0, defaults: defaults) == nil }
        })

        // Only meaningful once the disable above is known to have been
        // processed, which the wait guarantees; otherwise this would compare
        // the map against itself.
        #expect(
            WorkspaceAutoColorAssignmentStore(defaults: defaults).assignments()
                == storedBeforeDisable
        )
    }

    /// Polls `condition` until it holds or the deadline passes.
    ///
    /// Reconciling hops through `Task { @MainActor }`, so a single
    /// `Task.yield()` only usually lets it run. Waiting on the real predicate
    /// makes each assertion prove the reconcile happened instead of racing it,
    /// and turns a genuine regression into a deterministic failure rather than
    /// an intermittent one.
    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    /// The rail color the sidebar would draw right now, read through the same
    /// settings snapshot the real sidebar builds.
    @MainActor
    private static func railColor(for workspace: Workspace, defaults: UserDefaults) -> String? {
        SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            showsAgentActivity: false
        ).makeSnapshot().autoRailColorHex
    }

    /// Counts distinct rail colors, so a partially finished reconcile — where
    /// some workspaces are colored and some are not — is never mistaken for the
    /// settled state.
    @MainActor
    private static func distinctRailColors(
        for workspaces: [Workspace],
        defaults: UserDefaults
    ) -> Int {
        let colors = workspaces.compactMap { railColor(for: $0, defaults: defaults) }
        guard colors.count == workspaces.count else { return -1 }
        return Set(colors).count
    }
}
