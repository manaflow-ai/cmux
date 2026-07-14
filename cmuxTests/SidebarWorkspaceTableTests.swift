import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkspaceTableTests {
    @Test
    @MainActor
    func containerHasNoStructuralHorizontalRowInsetAndAlwaysActiveHoverTracking() throws {
        let container = SidebarWorkspaceTableController().makeContainerView()
        let column = try #require(container.tableView.tableColumns.first)
        container.tableView.updateTrackingAreas()
        let hoverTrackingArea = try #require(container.tableView.trackingAreas.first { area in
            area.options.contains(.mouseEnteredAndExited)
                && area.options.contains(.mouseMoved)
                && area.options.contains(.inVisibleRect)
        })

        #expect(container.tableView.style == .fullWidth)
        #expect(container.scrollView.contentInsets.left == 0)
        #expect(container.scrollView.contentInsets.right == 0)
        #expect(container.tableView.intercellSpacing.width == 0)
        #expect(!container.tableView.usesAutomaticRowHeights)
        #expect(container.tableView.columnAutoresizingStyle == .uniformColumnAutoresizingStyle)
        #expect(column.resizingMask.contains(.autoresizingMask))
        #expect(hoverTrackingArea.options.contains(.activeAlways))
        #expect(!hoverTrackingArea.options.contains(.activeInKeyWindow))
    }

    @Test
    func rowHeightEstimateAccountsForScaleWrappingAndDetails() {
        let calculator = SidebarWorkspaceTableRowHeightCalculator()
        let compact = calculator.estimatedWorkspaceHeight(
            fontScale: 1,
            titleLineCount: 1,
            auxiliaryLineCount: 0
        )
        let detailed = calculator.estimatedWorkspaceHeight(
            fontScale: 1.2,
            titleLineCount: 3,
            auxiliaryLineCount: 4
        )

        #expect(compact == 31)
        #expect(detailed == 144)
        #expect(calculator.estimatedGroupHeaderHeight(fontScale: 1) == 36)
        #expect(detailed > compact)
    }

    @Test
    @MainActor
    func rowHeightCacheMeasuresOnceForEquivalentRepeatedQueries() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0

        let initialChanges = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 44
        }
        let repeatedChanges = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 99
        }

        #expect(measurementCount == 1)
        #expect(initialChanges == IndexSet(integer: 0))
        #expect(repeatedChanges.isEmpty)
        #expect(cache.height(for: row, columnWidth: 200) == 44)
    }

    @Test
    @MainActor
    func rowHeightCacheInvalidatesWhenColumnWidthChanges() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0
        let measure: SidebarWorkspaceTableRowHeightCache.Measurement = { _, width in
            measurementCount += 1
            return width / 4
        }

        _ = cache.prepare(rows: [row], columnWidth: 200, measure: measure)
        let changed = cache.prepare(rows: [row], columnWidth: 240, measure: measure)

        #expect(measurementCount == 2)
        #expect(changed == IndexSet(integer: 0))
        #expect(cache.height(for: row, columnWidth: 200) == nil)
        #expect(cache.height(for: row, columnWidth: 240) == 60)
    }

    @Test
    @MainActor
    func rowHeightCacheInvalidatesContentFontAndAppearanceChanges() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let workspaceId = UUID()
        var measurementCount = 0
        let measure: SidebarWorkspaceTableRowHeightCache.Measurement = { _, _ in
            measurementCount += 1
            return CGFloat(40 + measurementCount)
        }
        let original = makeRowConfiguration(workspaceId: workspaceId)
        let changedContent = makeRowConfiguration(workspaceId: workspaceId, contentToken: 1)
        let changedFont = makeRowConfiguration(
            workspaceId: workspaceId,
            contentToken: 1,
            fontMagnificationPercent: 120
        )
        let changedAppearance = makeRowConfiguration(
            workspaceId: workspaceId,
            contentToken: 1,
            fontMagnificationPercent: 120,
            colorScheme: .dark
        )

        _ = cache.prepare(rows: [original], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedContent], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedFont], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedAppearance], columnWidth: 200, measure: measure)

        #expect(measurementCount == 4)
        #expect(cache.height(for: changedAppearance, columnWidth: 200) == 44)
    }

    @Test
    @MainActor
    func cachedHeightQueriesDuringScrollNeverMeasure() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0
        _ = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 44
        }

        for _ in 0..<500 {
            #expect(cache.prepareHostedRowsIfWidthChanged([row], columnWidth: 200) == nil)
            #expect(cache.height(for: row, columnWidth: 200) == 44)
        }

        #expect(measurementCount == 1)
    }

    @Test
    func hoverRecomputesFromStationaryWindowPointAfterScrollAndReorder() throws {
        let resolver = SidebarWorkspaceTableHoverResolver()
        let pointer = NSPoint(x: 20, y: 15)
        var scrollOffset: CGFloat = 0
        var orderedIds = ["a", "b", "c", "d"]

        func resolvedId() -> String? {
            let row = resolver.hoveredRow(
                windowPoint: pointer,
                convertToTable: { NSPoint(x: $0.x, y: $0.y + scrollOffset) },
                rowAtPoint: { Int(floor($0.y / 20)) },
                rowCount: orderedIds.count
            )
            return row.map { orderedIds[$0] }
        }

        #expect(resolvedId() == "a")
        scrollOffset = 20
        #expect(resolvedId() == "b")
        orderedIds = ["a", "c", "b", "d"]
        #expect(resolvedId() == "c")
    }

    @MainActor
    private func makeRowConfiguration(
        workspaceId: UUID = UUID(),
        contentToken: Int = 0,
        fontMagnificationPercent: Int = 100,
        colorScheme: ColorScheme = .light
    ) -> SidebarWorkspaceTableRowConfiguration {
#if DEBUG
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: colorScheme,
            globalFontMagnificationPercent: fontMagnificationPercent,
            lazyContractProbe: SidebarLazyContractProbe()
        )
#else
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: colorScheme,
            globalFontMagnificationPercent: fontMagnificationPercent
        )
#endif
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: environment,
            equivalenceValue: TestRowContent(token: contentToken)
        ) { _, _ in
            AnyView(TestRowContent(token: contentToken))
        }
    }

    private struct TestRowContent: View, Equatable {
        let token: Int

        var body: some View {
            EmptyView()
        }
    }
}
