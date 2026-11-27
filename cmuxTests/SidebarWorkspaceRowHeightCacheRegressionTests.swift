import AppKit
import Testing
@testable import cmux_DEV

/// Red/green regression coverage for the sidebar close-clipping fix
/// (https://github.com/manaflow-ai/cmux/pull/11242). Closing a workspace
/// shifts `index` and `isFirstRow` for every row below it; before the fix the
/// height cache keyed on full model equality, so a close both forgot the
/// cached height of the entire tail (losing the content-matched entries the
/// stale-width `height(for:)` fallback depends on) and re-measured every
/// surviving row through hosted layout. These tests fail on the pre-fix
/// cache (`hasEquivalentContent` keying) and pass on
/// `hasEquivalentHeightContent`.
@Suite
@MainActor
struct SidebarWorkspaceRowHeightCacheRegressionTests {
    @Test
    func cacheServesCachedHeightAcrossTheIndexShiftACloseCauses() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        var model = SidebarWorkspaceRowSuspensionTests.makeModel(
            customDescription: "This workspace description wraps across several sidebar lines"
        )
        model.index = 3
        model.isFirstRow = false
        let prepared = cache.prepare(
            rows: [makeConfiguration(model: model)],
            columnWidth: 300
        ) { _, _ in 57 }
        #expect(prepared == IndexSet(integer: 0))

        // A close above this row shifts it up one slot; nothing that affects
        // its measured height changed, so the cached height must survive.
        var shifted = model
        shifted.index = 2
        #expect(cache.height(for: makeConfiguration(model: shifted), columnWidth: 300) == 57)

        // Promotion to first row is the same shift for the head's successor.
        var promoted = model
        promoted.index = 0
        promoted.isFirstRow = true
        #expect(cache.height(for: makeConfiguration(model: promoted), columnWidth: 300) == 57)
    }

    @Test
    func closeDoesNotRemeasureTheSurvivingTail() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let models = (0..<5).map { index in
            var model = SidebarWorkspaceRowSuspensionTests.makeModel(
                customDescription: "This workspace description wraps across several sidebar lines"
            )
            model.index = index
            model.isFirstRow = index == 0
            return model
        }
        var measured = 0
        _ = cache.prepare(
            rows: models.map(makeConfiguration),
            columnWidth: 300
        ) { _, _ in
            measured += 1
            return 57
        }
        #expect(measured == 5)

        // Close the first workspace: the four survivors shift up one index
        // and the new head becomes the first row.
        let survivors = models.dropFirst().enumerated().map { index, model in
            var shifted = model
            shifted.index = index
            shifted.isFirstRow = index == 0
            return makeConfiguration(model: shifted)
        }
        measured = 0
        let changed = cache.prepare(rows: survivors, columnWidth: 300) { _, _ in
            measured += 1
            return 57
        }
        #expect(measured == 0, "a close must not re-measure position-only changes")
        #expect(changed.isEmpty)
    }

    @Test
    func contentChangesStillRemeasureAndReportHeightChanges() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        var model = SidebarWorkspaceRowSuspensionTests.makeModel(
            customDescription: "This workspace description wraps across several sidebar lines"
        )
        model.index = 0
        model.isFirstRow = true
        _ = cache.prepare(
            rows: [makeConfiguration(model: model)],
            columnWidth: 300
        ) { _, _ in 57 }

        // A notification line is real content: it must re-measure even though
        // the row's position did not move.
        var updated = model
        updated.latestNotificationText = "latest agent message"
        var measured = 0
        let updatedRow = makeConfiguration(model: updated)
        let changed = cache.prepare(rows: [updatedRow], columnWidth: 300) { _, _ in
            measured += 1
            return 88
        }
        #expect(measured == 1)
        #expect(changed == IndexSet(integer: 0))
        #expect(cache.height(for: updatedRow, columnWidth: 300) == 88)
    }

    /// Pins the premise the cache keying relies on: `index` feeds only the
    /// accessibility label and `isFirstRow` only the drop-indicator frame in
    /// the apply pass, so neither may change what the measurement pass
    /// (`layoutContent(apply: false)`) returns. If a future change makes
    /// either field height-relevant, this fails and
    /// `hasHeightEquivalentContent` must stop neutralizing that field.
    @Test
    func positionFieldsDoNotAffectMeasuredCellHeight() {
        var tailModel = SidebarWorkspaceRowSuspensionTests.makeModel(
            customDescription: Array(
                repeating: "wraps across several sidebar lines to exceed the estimate",
                count: 4
            ).joined(separator: " ")
        )
        tailModel.index = 7
        tailModel.isFirstRow = false
        var headModel = tailModel
        headModel.index = 0
        headModel.isFirstRow = true

        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: tailModel,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: tailModel),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let tailHeight = cell.layoutContent(model: tailModel, width: 300, apply: false)
        let headHeight = cell.layoutContent(model: headModel, width: 300, apply: false)
        #expect(tailHeight == headHeight)
        #expect(tailModel.hasHeightEquivalentContent(to: headModel))
    }

    private func makeConfiguration(
        model: SidebarWorkspaceRowModel
    ) -> SidebarWorkspaceTableRowConfiguration {
        SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model),
            groupId: nil,
            isPinned: false,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100,
                lazyContractProbe: SidebarLazyContractProbe()
            )
        )
    }
}
