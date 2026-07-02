import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Behavior coverage for the sidebar todo UI's pure models: the
/// status→glyph mapping (`SidebarWorkspaceTaskStatusGlyphModel`) and the
/// checklist display ordering/clamping policy
/// (`SidebarWorkspaceChecklistDisplayPolicy`).
struct WorkspaceTodoSidebarModelTests {
    // MARK: - Glyph model

    @Test
    func glyphFillFractionsProgressAcrossLanes() {
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .todo, hasOverride: false).fillFraction == 0)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .working, hasOverride: false).fillFraction == 0.5)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .needsAttention, hasOverride: false).fillFraction == 0.5)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .review, hasOverride: false).fillFraction == 0.75)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .done, hasOverride: false).fillFraction == 1)
    }

    @Test
    func glyphColorRolesMatchLanes() {
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .todo, hasOverride: false).colorRole == .neutral)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .working, hasOverride: false).colorRole == .working)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .needsAttention, hasOverride: false).colorRole == .attention)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .review, hasOverride: false).colorRole == .review)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .done, hasOverride: false).colorRole == .done)
    }

    @Test
    func onlyDoneShowsCheckmark() {
        for status in WorkspaceTaskStatus.allCases {
            let model = SidebarWorkspaceTaskStatusGlyphModel(status: status, hasOverride: false)
            #expect(model.showsCheckmark == (status == .done))
        }
    }

    @Test
    func overrideDotTracksManualOverrideForEveryLane() {
        for status in WorkspaceTaskStatus.allCases {
            #expect(SidebarWorkspaceTaskStatusGlyphModel(status: status, hasOverride: true).showsOverrideDot)
            #expect(!SidebarWorkspaceTaskStatusGlyphModel(status: status, hasOverride: false).showsOverrideDot)
        }
    }

    @Test
    func tooltipDistinguishesManualFromInferred() {
        let manual = SidebarWorkspaceTaskStatusGlyphModel.tooltip(status: .review, hasOverride: true)
        let inferred = SidebarWorkspaceTaskStatusGlyphModel.tooltip(status: .review, hasOverride: false)
        #expect(manual != inferred)
        #expect(manual.contains(WorkspaceTaskStatus.review.displayName))
        #expect(inferred.contains(WorkspaceTaskStatus.review.displayName))
    }

    @Test
    func displayNamesAreUniqueAndNonEmpty() {
        let names = WorkspaceTaskStatus.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    // MARK: - Checklist display policy

    private func item(_ text: String, _ state: WorkspaceChecklistItem.State) -> WorkspaceChecklistItem {
        WorkspaceChecklistItem(text: text, state: state)
    }

    @Test
    func completedItemsSinkBelowUncheckedPreservingRelativeOrder() {
        let items = [
            item("a", .completed),
            item("b", .pending),
            item("c", .inProgress),
            item("d", .completed),
            item("e", .pending),
        ]
        let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(items)
        #expect(ordered.map(\.text) == ["b", "c", "e", "a", "d"])
    }

    @Test
    func clampHidesItemsBeyondTheLimit() {
        let items = (0..<10).map { item("item \($0)", .pending) }
        let clamped = SidebarWorkspaceChecklistDisplayPolicy.clampedItems(items, showsAllItems: false)
        #expect(clamped.visible.count == SidebarWorkspaceChecklistDisplayPolicy.visibleItemLimit)
        #expect(clamped.hiddenCount == 10 - SidebarWorkspaceChecklistDisplayPolicy.visibleItemLimit)
        #expect(clamped.visible.map(\.text) == (0..<7).map { "item \($0)" })
    }

    @Test
    func clampIsBypassedWhenFullyExpandedOrUnderLimit() {
        let long = (0..<10).map { item("item \($0)", .pending) }
        let expanded = SidebarWorkspaceChecklistDisplayPolicy.clampedItems(long, showsAllItems: true)
        #expect(expanded.visible.count == 10)
        #expect(expanded.hiddenCount == 0)

        let short = (0..<7).map { item("item \($0)", .pending) }
        let underLimit = SidebarWorkspaceChecklistDisplayPolicy.clampedItems(short, showsAllItems: false)
        #expect(underLimit.visible.count == 7)
        #expect(underLimit.hiddenCount == 0)
    }
}
