import AppKit
import CmuxSettings
import Testing
@testable import cmux_DEV

/// `sidebar.groupMemberIndent`: how far workspace rows inside a group sit
/// to the right of ungrouped rows, and the drop indicators that follow them.
@Suite(.serialized)
@MainActor
struct SidebarGroupMemberIndentTests {
    private static func settings(indent: Int?) -> SidebarTabItemSettingsSnapshot {
        let defaults = UserDefaults(suiteName: "SidebarGroupMemberIndentTests.\(UUID().uuidString)")!
        if let indent {
            defaults.set(indent, forKey: SidebarCatalogSection().groupMemberIndent.userDefaultsKey)
        }
        return SidebarTabItemSettingsSnapshot(defaults: defaults)
    }

    private static func titleMinX(isGrouped: Bool, settings: SidebarTabItemSettingsSnapshot) throws -> CGFloat {
        let model = SidebarAppKitRowCellTests.makeModel(settings: settings, isGrouped: isGrouped)
        let cell = SidebarAppKitRowCellTests.configuredCell(model: model)
        cell.frame = NSRect(x: 0, y: 0, width: 260, height: 60)
        cell.layoutSubtreeIfNeeded()
        let title = try #require(
            descendants(of: cell)
                .compactMap { $0 as? SidebarRowTextView }
                .first { !$0.isHidden && $0.stringValue == "Workspace" }
        )
        return title.frame.minX
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    @Test func defaultKeepsTheExistingTwelvePointIndent() {
        #expect(Self.settings(indent: nil).groupMemberIndent == 12)
        #expect(SidebarWorkspaceGroupingMetrics.memberIndent == 12)
    }

    @Test(arguments: [(-4, 0), (0, 0), (28, 28), (48, 48), (200, 48)])
    func storedIndentIsLimitedToTheSupportedRange(_ stored: Int, _ expected: CGFloat) {
        #expect(Self.settings(indent: stored).groupMemberIndent == expected)
    }

    @Test(arguments: [0, 12, 28])
    func groupedRowTitleShiftsByTheConfiguredIndent(_ indent: Int) throws {
        let settings = Self.settings(indent: indent)
        let ungrouped = try Self.titleMinX(isGrouped: false, settings: settings)
        let grouped = try Self.titleMinX(isGrouped: true, settings: settings)
        #expect(grouped - ungrouped == CGFloat(indent))
    }

    @Test(arguments: [CGFloat(0.5), CGFloat(1), CGFloat(2)])
    func headerBottomDropIndicatorFollowsTheConfiguredIndent(_ scale: CGFloat) {
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: scale, memberIndent: 28)
        #expect(metrics.groupScopedBottomDropIndicatorLeadingInset == 28)
    }
}
