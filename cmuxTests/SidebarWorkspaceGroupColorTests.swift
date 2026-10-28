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

    /// The incremental refresh rebuilds rows from `staleWorkspaceIds`. When the anchor moves into
    /// another byCwd entry, only the anchor's row was refreshed, so the member must come back stale.
    @Test func anchorMovingToAnotherByCwdColorMakesMemberRowsStale() throws {
        let green = "#196F3D"
        let blue = "#1565C0"
        let (root, configStore) = try Self.makeConfigStore(byCwdColors: ["frontend": green, "backend": blue])
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "SidebarWorkspaceGroupColorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let anchor = Workspace(title: "Anchor", initialSurface: .cloudVMLoading)
        let member = Workspace(title: "Member", initialSurface: .cloudVMLoading)
        let workspaces = [anchor, member]
        defer { workspaces.forEach { $0.teardownAllPanels() } }
        let group = Self.makeGroup(anchorWorkspaceId: anchor.id, customColor: nil)
        anchor.groupId = group.id
        member.groupId = group.id
        anchor.currentDirectory = root.appendingPathComponent("frontend").path
        func colors() -> [UUID: String] {
            SidebarWorkspaceGroupAppearance.inheritedColorHexes(
                workspaces: workspaces,
                groups: [group],
                configStore: configStore
            )
        }
        func staleIds(saved: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot]) -> Set<UUID> {
            let current = colors()
            return Set(SidebarWorkspaceSnapshotFactory.staleWorkspaceIds(workspaces: workspaces, savedSnapshots: saved) {
                SidebarWorkspaceSnapshotFactory.presentationKey(
                    workspace: $0,
                    settings: settings,
                    showsAgentActivity: false,
                    groupColorHex: current[$0.id],
                    originColorHex: nil,
                    hostTitleSuffix: nil
                )
            })
        }
        let before = colors()
        #expect(before[member.id] == green)
        let saved = Dictionary(uniqueKeysWithValues: workspaces.map { workspace in
            (workspace.id, SidebarWorkspaceSnapshotFactory(
                workspace: workspace,
                settings: settings,
                showsAgentActivity: false,
                groupColorHex: before[workspace.id]
            ).makeSnapshot())
        })
        #expect(staleIds(saved: saved).isEmpty)

        anchor.currentDirectory = root.appendingPathComponent("backend").path

        #expect(colors()[member.id] == blue)
        #expect(staleIds(saved: saved).contains(member.id))
    }

    @Test func membersOfAColoredGroupInheritItsColor() throws {
        let (root, configStore) = try Self.makeConfigStore(byCwdColors: [:])
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

    @Test func workspaceWithAStaleGroupIdInheritsNothing() throws {
        let (root, configStore) = try Self.makeConfigStore(byCwdColors: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        let stray = Workspace(title: "Stray", initialSurface: .cloudVMLoading)
        defer { stray.teardownAllPanels() }
        // The group's anchor isn't a live workspace (a restore or an in-flight anchor promotion),
        // so the sidebar draws `stray` at the root, and it must not draw the group's color.
        let group = Self.makeGroup(anchorWorkspaceId: UUID(), customColor: Self.groupColor)
        stray.groupId = group.id

        let colors = SidebarWorkspaceGroupAppearance.inheritedColorHexes(
            workspaces: [stray],
            groups: [group],
            configStore: configStore
        )

        #expect(colors.isEmpty)
    }

    /// Group colors follow the sidebar's effective membership, where two groups claiming one
    /// live anchor resolve to the lowest group id whatever order the groups come in.
    @Test func twoGroupsClaimingOneAnchorResolveToTheLowestGroupId() throws {
        let anchor = Workspace(title: "Anchor", initialSurface: .cloudVMLoading)
        defer { anchor.teardownAllPanels() }
        let lowId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highId = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
        let groups = [highId, lowId].map { id in
            WorkspaceGroup(
                id: id,
                name: "group",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceId: anchor.id,
                customColor: nil,
                iconSymbol: nil
            )
        }
        for ordered in [groups, groups.reversed()] {
            let membership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(
                tabs: [anchor],
                groupsById: Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
            )
            #expect(membership[anchor.id] == lowId)
        }
    }

    @Test func groupWithoutOwnColorUsesItsByCwdConfigColor() throws {
        let configColor = "#7A4FD8"
        let (root, configStore) = try Self.makeConfigStore(byCwdColors: ["": configColor])
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
    /// `byCwdColors` maps a subdirectory of the returned root ("" for the root itself) to a group color.
    private static func makeConfigStore(byCwdColors: [String: String]) throws -> (URL, CmuxConfigStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-group-color-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = try byCwdColors.map { subdirectory, color in
            let directory = subdirectory.isEmpty ? root : root.appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return #""\#(directory.path)": { "color": "\#(color)" }"#
        }
        let configURL = root.appendingPathComponent("cmux.json")
        try #"{ "workspaceGroups": { "byCwd": { \#(entries.joined(separator: ", ")) } } }"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        let configStore = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        configStore.loadAll()
        return (root, configStore)
    }
}
