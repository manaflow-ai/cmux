import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar workspace group colors")
struct SidebarWorkspaceGroupColorTests {
    private static let groupColor = "#1565C0"
    private static let originColor = "#B1A2FA"

    @Test func groupColorBeatsOriginColorAndManualColorBeatsBoth() throws {
        let suiteName = "SidebarWorkspaceGroupColorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(title: "Grouped", initialSurface: .cloudVMLoading)
        defer { workspace.teardownAllPanels() }
        let factory = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            showsAgentActivity: false,
            originColorHex: Self.originColor,
            groupColorHex: Self.groupColor
        )

        let inherited = factory.makeSnapshot()
        #expect(inherited.customColorHex == Self.groupColor)
        #expect(inherited.presentationKey.customColorHex == Self.groupColor)
        // An inherited color is not the workspace's own, so its Clear Color stays hidden.
        #expect(inherited.hasManualCustomColor == false)

        let manualColor = "#FF945A"
        workspace.customColor = manualColor
        let manual = factory.makeSnapshot()
        #expect(manual.customColorHex == manualColor)
        #expect(manual.presentationKey.customColorHex == manualColor)
        #expect(manual.hasManualCustomColor)
    }

    /// The sidebar's cache reconcile and its incremental stale-row check build keys with
    /// `presentationKey(workspace:...)`; it must match the key the built snapshot carries.
    @Test func cacheKeyMatchesTheBuiltSnapshotAndTracksTheGroupColor() throws {
        let suiteName = "SidebarWorkspaceGroupColorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let workspace = Workspace(title: "Member", initialSurface: .cloudVMLoading)
        defer { workspace.teardownAllPanels() }
        func key(groupColor: String?) -> SidebarWorkspaceSnapshotBuilder.PresentationKey {
            SidebarWorkspaceSnapshotFactory.presentationKey(
                workspace: workspace,
                settings: settings,
                showsAgentActivity: false,
                groupColorHex: groupColor,
                originColorHex: nil,
                hostTitleSuffix: nil
            )
        }
        let saved = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: false,
            groupColorHex: Self.groupColor
        ).makeSnapshot()
        #expect(saved.presentationKey == key(groupColor: Self.groupColor))

        // The group's color changed (its anchor moved into another byCwd entry): the saved row is stale.
        #expect(saved.presentationKey != key(groupColor: "#196F3D"))

        // A member with its own color draws the same thing whatever the group color is.
        workspace.customColor = "#FF945A"
        #expect(key(groupColor: Self.groupColor) == key(groupColor: "#196F3D"))
    }

    @Test func membersOfAColoredGroupInheritItsColor() throws {
        let (root, configStore) = try Self.makeConfigStore(byCwdColor: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let anchor = Workspace(title: "Anchor", initialSurface: .cloudVMLoading)
        let member = Workspace(title: "Member", initialSurface: .cloudVMLoading)
        let ungrouped = Workspace(title: "Ungrouped", initialSurface: .cloudVMLoading)
        let uncoloredAnchor = Workspace(title: "Uncolored", initialSurface: .cloudVMLoading)
        let workspaces = [anchor, member, ungrouped, uncoloredAnchor]
        defer { workspaces.forEach { $0.teardownAllPanels() } }
        let colored = Self.makeGroup(anchorWorkspaceId: anchor.id, customColor: Self.groupColor)
        let uncolored = Self.makeGroup(anchorWorkspaceId: uncoloredAnchor.id, customColor: nil)
        anchor.groupId = colored.id
        member.groupId = colored.id
        uncoloredAnchor.groupId = uncolored.id

        let colors = SidebarWorkspaceGroupAppearance.inheritedColorHexes(
            workspaces: workspaces,
            groups: [colored, uncolored],
            configStore: configStore
        )

        #expect(colors == [anchor.id: Self.groupColor, member.id: Self.groupColor])
    }

    @Test func groupWithoutOwnColorUsesItsByCwdConfigColor() throws {
        let configColor = "#7A4FD8"
        let (root, configStore) = try Self.makeConfigStore(byCwdColor: configColor)
        defer { try? FileManager.default.removeItem(at: root) }
        let anchor = Workspace(title: "Anchor", initialSurface: .cloudVMLoading)
        let member = Workspace(title: "Member", initialSurface: .cloudVMLoading)
        defer { [anchor, member].forEach { $0.teardownAllPanels() } }
        let group = Self.makeGroup(anchorWorkspaceId: anchor.id, customColor: nil)
        anchor.groupId = group.id
        member.groupId = group.id
        anchor.currentDirectory = root.path

        let appearance = SidebarWorkspaceGroupAppearance(
            group: group,
            workspaceById: [anchor.id: anchor, member.id: member],
            configStore: configStore
        )
        #expect(appearance.colorHex == configColor)
        #expect(appearance.hasCustomColor == false)
        let colors = SidebarWorkspaceGroupAppearance.inheritedColorHexes(
            workspaces: [anchor, member],
            groups: [group],
            configStore: configStore
        )
        #expect(colors[member.id] == configColor)
    }

    private static func makeGroup(anchorWorkspaceId: UUID, customColor: String?) -> WorkspaceGroup {
        WorkspaceGroup(
            id: UUID(),
            name: "group",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: anchorWorkspaceId,
            customColor: customColor,
            iconSymbol: nil
        )
    }

    /// A config store reading only a temp `cmux.json`, never the user's own config.
    private static func makeConfigStore(byCwdColor: String?) throws -> (URL, CmuxConfigStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-group-color-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("cmux.json")
        let byCwd = byCwdColor.map { #"{ "\#(root.path)": { "color": "\#($0)" } }"# } ?? "{}"
        try #"{ "workspaceGroups": { "byCwd": \#(byCwd) } }"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        let configStore = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        configStore.loadAll()
        return (root, configStore)
    }
}
