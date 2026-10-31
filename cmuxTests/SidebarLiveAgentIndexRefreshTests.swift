import Foundation
import Testing
@testable import cmux_DEV

/// Which sidebar rows rebuild when the live agent index changes. The index is
/// not observable, so a row that reads it (the compact glyph's tooltip, the
/// normal-mode "Claude account" row) stays stale unless this says to rebuild.
@Suite
@MainActor
struct SidebarLiveAgentIndexRefreshTests {
    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()
    private static let all = [a, b, c]
    /// A targeted notification naming only workspace `b`.
    private static let namesB: [AnyHashable: Any] = ["panelIdsByWorkspaceId": [b: Set([UUID()])]]

    private static func refreshed(
        _ userInfo: [AnyHashable: Any]?,
        compacts: Bool,
        showsMetadata: Bool
    ) -> [UUID] {
        SidebarAgentProfileLabel.workspaceIdsToRefresh(
            afterIndexChange: userInfo,
            allWorkspaceIds: all,
            compactsAgentStatus: compacts,
            showsMetadata: showsMetadata
        )
    }

    // (compact status, metadata shown, expect a refresh)
    @Test(arguments: [
        (false, false, false),
        (true, false, true),
        (false, true, true),
        (true, true, true),
    ])
    func indexChangeRefreshesWhenARowReadsTheIndex(
        compacts: Bool,
        showsMetadata: Bool,
        refreshes: Bool
    ) {
        let ids = Self.refreshed(Self.namesB, compacts: compacts, showsMetadata: showsMetadata)
        #expect(ids == (refreshes ? [Self.b] : []))
    }

    @Test
    func normalModeRefreshStaysScopedToTheNamedWorkspaces() {
        func changed(_ userInfo: [AnyHashable: Any]?) -> [UUID] {
            Self.refreshed(userInfo, compacts: false, showsMetadata: true)
        }

        #expect(changed(Self.namesB) == [Self.b])
        #expect(changed(["workspaceId": Self.c]) == [Self.c])
        #expect(changed(["workspaceId": UUID()]).isEmpty)
        #expect(changed(nil) == Self.all)
    }

    @Test
    func defaultSidebarSettingsRefreshTheAccountRow() {
        let ids = SidebarAgentProfileLabel.workspaceIdsToRefresh(
            afterIndexChange: Self.namesB,
            allWorkspaceIds: Self.all,
            settings: SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        )
        #expect(ids == [Self.b])
    }

    @Test(arguments: ["sidebarHideAllDetails", "sidebarShowStatusPills"])
    func hiddenMetadataInNormalModeSkipsTheRefresh(key: String) {
        let defaults = Self.makeDefaults()
        defaults.set(key == "sidebarHideAllDetails", forKey: key)
        let ids = SidebarAgentProfileLabel.workspaceIdsToRefresh(
            afterIndexChange: Self.namesB,
            allWorkspaceIds: Self.all,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults)
        )
        #expect(ids.isEmpty)
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarLiveAgentIndexRefreshTests.\(UUID().uuidString)")!
    }
}
