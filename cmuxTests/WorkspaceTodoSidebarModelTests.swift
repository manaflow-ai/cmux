import CmuxSettings
import CmuxWorkspaces
import CoreGraphics
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
    func workspaceTodoControlsGateDefaultsOffAndAllowsLocalOrRemoteOptIn() throws {
        let suiteName = "cmux.workspace.todo.controls.setting.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let key = BetaFeaturesCatalogSection().workspaceTodoControls

        #expect(key.defaultValue == false)
        #expect(!WorkspaceTodoFeature.localControlsOptIn(defaults: defaults))
        #expect(!WorkspaceTodoFeature.isEnabled(defaults: defaults, remoteEnabled: false))
        #expect(WorkspaceTodoFeature.isEnabled(defaults: defaults, remoteEnabled: true))

        defaults.set(true, forKey: key.userDefaultsKey)
        #expect(WorkspaceTodoFeature.localControlsOptIn(defaults: defaults))
        #expect(WorkspaceTodoFeature.isEnabled(defaults: defaults, remoteEnabled: false))

        defaults.set(false, forKey: key.userDefaultsKey)
        #expect(!WorkspaceTodoFeature.localControlsOptIn(defaults: defaults))
        #expect(!WorkspaceTodoFeature.isEnabled(defaults: defaults, remoteEnabled: false))
    }

    @Test
    func compactStatusOnlyShowsWhenDetailsAreHiddenAndStatusIsEngaged() {
        #expect(!SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 0,
            addFieldActivationToken: 0,
            isPopoverPresented: false,
            canAddItems: true,
            hidesAllDetails: false,
            taskStatus: .working,
            featureEnabled: true
        ).showsCompactStatus)
        #expect(!SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 0,
            addFieldActivationToken: 0,
            isPopoverPresented: false,
            canAddItems: true,
            hidesAllDetails: true,
            taskStatus: nil,
            featureEnabled: true
        ).showsCompactStatus)
        #expect(!SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 0,
            addFieldActivationToken: 0,
            isPopoverPresented: false,
            canAddItems: true,
            hidesAllDetails: true,
            taskStatus: .working,
            featureEnabled: false
        ).showsCompactStatus)
        #expect(SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 0,
            addFieldActivationToken: 0,
            isPopoverPresented: false,
            canAddItems: true,
            hidesAllDetails: true,
            taskStatus: .working,
            featureEnabled: true
        ).showsCompactStatus)
    }

    @Test
    func rowStatusIndicatorOnlyShowsForManualStatusWhenFlagEnabled() {
        #expect(!SidebarWorkspaceManualTaskStatusIndicatorModel(
            featureEnabled: true,
            taskStatus: nil,
            hasManualOverride: true
        ).showsIndicator)
        #expect(!SidebarWorkspaceManualTaskStatusIndicatorModel(
            featureEnabled: false,
            taskStatus: .review,
            hasManualOverride: true
        ).showsIndicator)
        #expect(!SidebarWorkspaceManualTaskStatusIndicatorModel(
            featureEnabled: true,
            taskStatus: .review,
            hasManualOverride: false
        ).showsIndicator)
        #expect(SidebarWorkspaceManualTaskStatusIndicatorModel(
            featureEnabled: true,
            taskStatus: .review,
            hasManualOverride: true
        ).showsIndicator)
    }

    @Test
    func checklistSectionStaysMountedForUseAndCompactsWhenIdle() {
        #expect(!SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 0,
            addFieldActivationToken: 0,
            isPopoverPresented: false,
            canAddItems: true,
            hidesAllDetails: false,
            taskStatus: nil,
            featureEnabled: true
        ).showsChecklistSection)
        #expect(!SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 0,
            addFieldActivationToken: 1,
            isPopoverPresented: false,
            canAddItems: false,
            hidesAllDetails: false,
            taskStatus: nil,
            featureEnabled: false
        ).showsChecklistSection)
        #expect(SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 1,
            addFieldActivationToken: 0,
            isPopoverPresented: false,
            canAddItems: false,
            hidesAllDetails: false,
            taskStatus: nil,
            featureEnabled: false
        ).showsChecklistSection)
        #expect(SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 0,
            addFieldActivationToken: 1,
            isPopoverPresented: false,
            canAddItems: true,
            hidesAllDetails: false,
            taskStatus: nil,
            featureEnabled: true
        ).showsChecklistSection)
        #expect(SidebarWorkspaceTodoMinimalVisibility(
            itemCount: 0,
            addFieldActivationToken: 0,
            isPopoverPresented: true,
            canAddItems: true,
            hidesAllDetails: false,
            taskStatus: nil,
            featureEnabled: true
        ).showsChecklistSection)
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

    // MARK: - Todo pane row editing

    @Test
    func todoPaneRowClickSelectsBeforeEditingAndRefocusesDuringEdit() {
        #expect(WorkspaceTodoPaneItemRowClickPolicy.action(
            isEditing: false,
            isHighlighted: false
        ) == .select)
        #expect(WorkspaceTodoPaneItemRowClickPolicy.action(
            isEditing: false,
            isHighlighted: true
        ) == .beginEdit)
        #expect(WorkspaceTodoPaneItemRowClickPolicy.action(
            isEditing: true,
            isHighlighted: false
        ) == .focusEditor)
        #expect(WorkspaceTodoPaneItemRowClickPolicy.action(
            isEditing: true,
            isHighlighted: true
        ) == .focusEditor)
    }

    @Test
    func todoPaneArrowNavigationDoesNotStealKeysWhileEditing() {
        #expect(WorkspaceTodoPaneKeyboardNavigationPolicy.shouldMoveHighlight(
            isEditing: false,
            hasItems: true
        ))
        #expect(!WorkspaceTodoPaneKeyboardNavigationPolicy.shouldMoveHighlight(
            isEditing: true,
            hasItems: true
        ))
        #expect(!WorkspaceTodoPaneKeyboardNavigationPolicy.shouldMoveHighlight(
            isEditing: false,
            hasItems: false
        ))
    }

    @Test
    func todoPaneEditFieldUsesVerticalTextEntry() throws {
        let source = try Self.sourceText("Sources/Panels/WorkspaceTodoPanelView.swift")

        #expect(source.contains("axis: .vertical"))
        #expect(source.contains(".lineLimit(1...8)"))
        #expect(!source.contains(".onSubmit { actions.commitEdit() }"))
    }

    @Test
    func checklistAddAndEditFieldsStayTextFieldsWithVerticalEntry() throws {
        let pane = try Self.sourceText("Sources/Panels/WorkspaceTodoPanelView.swift")
        let popover = try Self.sourceText("Sources/SidebarWorkspaceChecklistPopover.swift")

        #expect(pane.contains("TextField("))
        #expect(popover.contains("TextField("))
        #expect(pane.contains("text: $pendingItemText,\n                axis: .vertical"))
        #expect(popover.contains("text: $pendingItemText,\n                axis: .vertical"))
        #expect(popover.contains("text: $editingText,\n                    axis: .vertical"))
    }

    @Test
    func checklistPopoverViewportSizesToItemsUntilCap() {
        #expect(SidebarWorkspaceChecklistPopoverViewportModel.visibleRowCount(forItemCount: 0) == 0)
        #expect(SidebarWorkspaceChecklistPopoverViewportModel.visibleRowCount(forItemCount: 1) == 1)
        #expect(SidebarWorkspaceChecklistPopoverViewportModel.visibleRowCount(forItemCount: 2) == 2)
        #expect(SidebarWorkspaceChecklistPopoverViewportModel.visibleRowCount(forItemCount: 5) == 5)
        #expect(SidebarWorkspaceChecklistPopoverViewportModel.visibleRowCount(forItemCount: 6) == 6)
        #expect(SidebarWorkspaceChecklistPopoverViewportModel.visibleRowCount(forItemCount: 12) == 6)
        #expect(!SidebarWorkspaceChecklistPopoverViewportModel.requiresScrolling(forItemCount: 1))
        #expect(!SidebarWorkspaceChecklistPopoverViewportModel.requiresScrolling(forItemCount: 6))
        #expect(SidebarWorkspaceChecklistPopoverViewportModel.requiresScrolling(forItemCount: 7))
    }

    @Test
    func checklistPopoverViewportUsesMeasuredRowsForScrollingCap() {
        let measuredHeight = SidebarWorkspaceChecklistPopoverViewportModel.viewportHeight(
            orderedIds: [1, 2, 3, 4, 5, 6, 7],
            rowFrames: [
                1: CGRect(x: 0, y: 10, width: 100, height: 24),
                2: CGRect(x: 0, y: 37, width: 100, height: 24),
                3: CGRect(x: 0, y: 64, width: 100, height: 31),
                4: CGRect(x: 0, y: 98, width: 100, height: 24),
                5: CGRect(x: 0, y: 125, width: 100, height: 24),
                6: CGRect(x: 0, y: 152, width: 100, height: 24),
                7: CGRect(x: 0, y: 179, width: 100, height: 24),
            ],
            fallbackRowHeight: 19,
            fallbackSpacing: 2
        )
        #expect(measuredHeight == 166)

        let fallbackHeight = SidebarWorkspaceChecklistPopoverViewportModel.viewportHeight(
            orderedIds: [1, 2],
            rowFrames: [:],
            fallbackRowHeight: 19,
            fallbackSpacing: 2
        )
        #expect(fallbackHeight == 40)
    }

    @Test
    func checklistTextFieldsSupportShiftReturnLineBreaks() throws {
        let pane = try Self.sourceText("Sources/Panels/WorkspaceTodoPanelView.swift")
        let popover = try Self.sourceText("Sources/SidebarWorkspaceChecklistPopover.swift")
        let compactField = try Self.sourceText("Sources/ChecklistInputField.swift")

        #expect(pane.contains("modifiers.contains(.shift)"))
        #expect(pane.contains("pendingItemText.append(\"\\n\")"))
        #expect(pane.contains("editingText.append(\"\\n\")"))
        #expect(popover.contains("press.modifiers == EventModifiers.shift"))
        #expect(popover.contains("pendingItemText.append(\"\\n\")"))
        #expect(popover.contains("editingText.append(\"\\n\")"))
        #expect(compactField.contains("#selector(NSResponder.insertLineBreak(_:))"))
        #expect(compactField.contains("textView.insertText(\"\\n\""))
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
