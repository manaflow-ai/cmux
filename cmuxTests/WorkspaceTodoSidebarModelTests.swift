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
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // cmuxTests
            .deletingLastPathComponent() // repo root
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - Glyph model

    @Test
    func glyphFillFractionsProgressAcrossLanes() {
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .todo).fillFraction == 0)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .working).fillFraction == 0.5)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .needsAttention).fillFraction == 0.5)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .review).fillFraction == 0.75)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .done).fillFraction == 1)
    }

    @Test
    func glyphColorRolesMatchLanes() {
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .todo).colorRole == .neutral)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .working).colorRole == .working)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .needsAttention).colorRole == .attention)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .review).colorRole == .review)
        #expect(SidebarWorkspaceTaskStatusGlyphModel(status: .done).colorRole == .done)
    }

    @Test
    func onlyDoneShowsCheckmark() {
        for status in WorkspaceTaskStatus.allCases {
            let model = SidebarWorkspaceTaskStatusGlyphModel(status: status)
            #expect(model.showsCheckmark == (status == .done))
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

    // MARK: - Minimal todo visibility

    @Test
    func compactStatusOnlyShowsWhenDetailsAreHiddenAndStatusIsEngaged() {
        #expect(!SidebarWorkspaceTodoMinimalVisibility.showsCompactStatus(
            hidesAllDetails: false,
            taskStatus: .working,
            featureEnabled: true
        ))
        #expect(!SidebarWorkspaceTodoMinimalVisibility.showsCompactStatus(
            hidesAllDetails: true,
            taskStatus: nil,
            featureEnabled: true
        ))
        #expect(!SidebarWorkspaceTodoMinimalVisibility.showsCompactStatus(
            hidesAllDetails: true,
            taskStatus: .working,
            featureEnabled: false
        ))
        #expect(SidebarWorkspaceTodoMinimalVisibility.showsCompactStatus(
            hidesAllDetails: true,
            taskStatus: .working,
            featureEnabled: true
        ))
    }

    @Test
    func rowStatusIndicatorOnlyShowsForManualStatusWhenFlagEnabled() {
        #expect(!SidebarWorkspaceManualTaskStatusIndicatorModel.showsIndicator(
            featureEnabled: true,
            taskStatus: nil,
            hasManualOverride: true
        ))
        #expect(!SidebarWorkspaceManualTaskStatusIndicatorModel.showsIndicator(
            featureEnabled: false,
            taskStatus: .review,
            hasManualOverride: true
        ))
        #expect(!SidebarWorkspaceManualTaskStatusIndicatorModel.showsIndicator(
            featureEnabled: true,
            taskStatus: .review,
            hasManualOverride: false
        ))
        #expect(SidebarWorkspaceManualTaskStatusIndicatorModel.showsIndicator(
            featureEnabled: true,
            taskStatus: .review,
            hasManualOverride: true
        ))
    }

    @Test
    func checklistSectionStaysMountedForUseAndCompactsWhenIdle() {
        #expect(!SidebarWorkspaceTodoMinimalVisibility.showsChecklistSection(
            itemCount: 0,
            addFieldActivationToken: 0,
            isPopoverPresented: false,
            canAddItems: true
        ))
        #expect(!SidebarWorkspaceTodoMinimalVisibility.showsChecklistSection(
            itemCount: 0,
            addFieldActivationToken: 1,
            isPopoverPresented: false,
            canAddItems: false
        ))
        #expect(SidebarWorkspaceTodoMinimalVisibility.showsChecklistSection(
            itemCount: 1,
            addFieldActivationToken: 0,
            isPopoverPresented: false,
            canAddItems: false
        ))
        #expect(SidebarWorkspaceTodoMinimalVisibility.showsChecklistSection(
            itemCount: 0,
            addFieldActivationToken: 1,
            isPopoverPresented: false,
            canAddItems: true
        ))
        #expect(SidebarWorkspaceTodoMinimalVisibility.showsChecklistSection(
            itemCount: 0,
            addFieldActivationToken: 0,
            isPopoverPresented: true,
            canAddItems: true
        ))
    }

    @Test
    func compactStatusMenuSelectionDistinguishesAutoFromManualOverride() {
        let automatic = SidebarWorkspaceCompactStatusMenuModel.resolve(
            inferred: .working,
            override: nil
        )
        var lanes = WorkspaceTodoStatusLane.lanes(
            inferred: automatic.inferred,
            activeOverride: automatic.activeOverride
        )
        #expect(lanes.first?.isSelected == true)
        #expect(lanes.first { $0.status == .working }?.isSelected == false)

        let pinned = SidebarWorkspaceCompactStatusMenuModel.resolve(
            inferred: .working,
            override: WorkspaceTaskStatusOverride(status: .review, inferredAtOverride: .working)
        )
        lanes = WorkspaceTodoStatusLane.lanes(
            inferred: pinned.inferred,
            activeOverride: pinned.activeOverride
        )
        #expect(lanes.first?.isSelected == false)
        #expect(lanes.first { $0.status == .review }?.isSelected == true)

        let expired = SidebarWorkspaceCompactStatusMenuModel.resolve(
            inferred: .done,
            override: WorkspaceTaskStatusOverride(status: .review, inferredAtOverride: .working)
        )
        lanes = WorkspaceTodoStatusLane.lanes(
            inferred: expired.inferred,
            activeOverride: expired.activeOverride
        )
        #expect(lanes.first?.isSelected == true)
        #expect(lanes.first { $0.status == .review }?.isSelected == false)
    }

    // MARK: - Todo pane header

    @Test
    func todoPaneHeaderDoesNotRenderWorkspaceTitleAsPaneTitle() throws {
        let source = try Self.sourceText("Sources/Panels/WorkspaceTodoPanelView.swift")

        #expect(
            !source.contains("Text(workspace.title)"),
            """
            The Todo pane header must render the Todo panel title, not Workspace.title. \
            Workspace.title follows the focused surface title, so it can briefly show \
            the terminal title during terminal-to-Todo tab switches.
            """
        )
        #expect(source.contains("WorkspaceTodoPaneHeaderTitle.title"))
    }

    @Test
    func todoPaneHeaderHidesAutomaticTodoStatusLabel() {
        #expect(WorkspaceTodoPaneHeaderStatusLabel.displayName(
            effective: .todo,
            hasOverride: false
        ) == nil)
        #expect(WorkspaceTodoPaneHeaderStatusLabel.displayName(
            effective: .review,
            hasOverride: false
        ) == WorkspaceTaskStatus.review.displayName)
        #expect(WorkspaceTodoPaneHeaderStatusLabel.displayName(
            effective: .todo,
            hasOverride: true
        ) == WorkspaceTaskStatus.todo.displayName)
        #expect(WorkspaceTodoPaneHeaderStatusLabel.displayName(
            effective: nil,
            hasOverride: false
        ) == nil)
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
