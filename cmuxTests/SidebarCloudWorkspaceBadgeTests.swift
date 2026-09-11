import AppKit
import Combine
import CmuxCore
import Testing
@testable import cmux_DEV

@Suite(.serialized)
@MainActor
struct SidebarCloudWorkspaceBadgeTests {
    @Test func cloudBindingChangesSidebarSnapshotWithoutTitleOrPathChanges() {
        let workspace = Workspace(title: "vm:vivid-newt", workingDirectory: "/tmp", initialSurface: .cloudVMLoading)
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let factory = SidebarWorkspaceSnapshotFactory(workspace: workspace, settings: settings, showsAgentActivity: false)
        let local = factory.makeSnapshot()
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true)
        let cloud = factory.makeSnapshot()
        #expect(local.title == cloud.title)
        #expect(local != cloud)
        workspace.cloudVMBinding = nil
        #expect(factory.makeSnapshot() == local)
    }

    @Test(arguments: [false, true])
    func cloudBadgeSurvivesRestoreAndReconnect(legacyTransport: Bool) throws {
        let workspace = Workspace(title: "Same project", initialSurface: .cloudVMLoading)
        if legacyTransport {
            workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
                destination: "root@example.invalid",
                port: nil, identityFile: nil, sshOptions: [], localProxyPort: nil,
                relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
                managedCloudVMID: "vivid-newt", terminalStartupCommand: nil
            )
        } else {
            workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true, remoteWorkspaceID: "ws_123")
        }
        let encoded = try JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
        let saved = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: encoded)
        let restored = Workspace(initialSurface: .cloudVMLoading)
        restored.restoreSessionSnapshot(saved)
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let factory = SidebarWorkspaceSnapshotFactory(workspace: restored, settings: settings, showsAgentActivity: false)
        for state: WorkspaceRemoteConnectionState in [.disconnected, .connecting, .reconnecting, .connected, .suspended, .error] {
            restored.remoteConnectionState = state
            let cell = SidebarAppKitRowCellTests.configuredCell(model: Self.makeModel(settings: settings, workspaceSnapshot: factory.makeSnapshot()))
            #expect(cell.accessibilityLabel()?.contains("Cloud workspace on vivid-newt") == true)
        }
    }

    @Test(arguments: [false, true], [180.0, 280.0])
    func cloudBadgeIsSecondaryAndKeepsNarrowTitlesVisible(dark: Bool, width: Double) throws {
        let defaults = Self.makeDefaults()
        defaults.set(false, forKey: "sidebarWrapWorkspaceTitles")
        defaults.set(true, forKey: "sidebarHideAllDetails")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let workspace = Workspace(title: "Same project with a long workspace name", initialSurface: .cloudVMLoading)
        let factory = SidebarWorkspaceSnapshotFactory(workspace: workspace, settings: settings, showsAgentActivity: false)
        let localSnapshot = factory.makeSnapshot()
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false)
        let cloudSnapshot = factory.makeSnapshot()
        let cell = SidebarAppKitRowCellTests.configuredCell(model: Self.makeModel(settings: settings, workspaceSnapshot: cloudSnapshot, colorSchemeIsDark: dark))
        cell.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        cell.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        cell.layoutSubtreeIfNeeded()
        let badge = try #require(SidebarAppKitRowCellTests.descendants(of: cell).compactMap { $0 as? NSImageView }.first {
            $0.accessibilityIdentifier() == "sidebarCloudBadge"
        })
        let title = try #require(SidebarAppKitRowCellTests.descendants(of: cell).compactMap { $0 as? SidebarRowTextView }.first {
            $0.stringValue == cloudSnapshot.title
        })
        #expect(!badge.isHidden)
        #expect(badge.image != nil)
        #expect(badge.toolTip == "Cloud workspace on vivid-newt")
        #expect(badge.contentTintColor != title.textColor)
        #expect(title.frame.width > 60)
        #expect(title.frame.maxX <= badge.frame.minX)
        #expect(badge.frame.maxX <= width)
        let height = cell.layoutContent(model: try #require(cell.currentModelForMeasurement), width: width, apply: false)
        cell.applyRebuiltModel(Self.makeModel(settings: settings, workspaceSnapshot: localSnapshot, colorSchemeIsDark: dark))
        cell.layoutSubtreeIfNeeded()
        #expect(badge.isHidden)
        #expect(cell.accessibilityLabel()?.contains("Cloud workspace") == false)
        #expect(cell.layoutContent(model: try #require(cell.currentModelForMeasurement), width: width, apply: false) == height)
    }

    @Test func cloudBindingChangeImmediatelyInvalidatesSidebar() {
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink { publishCount += 1 }
        defer { cancellable.cancel() }
        publishCount = 0
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true)
        #expect(publishCount == 1)
    }

    private static func makeModel(
        settings: SidebarTabItemSettingsSnapshot,
        workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        colorSchemeIsDark: Bool = true
    ) -> SidebarWorkspaceRowModel {
        return SidebarWorkspaceRowModel(
            workspaceId: UUID(),
            index: 0,
            snapshot: workspaceSnapshot,
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            canCloseWorkspace: true,
            accessibilityWorkspaceCount: 1,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: settings.details.showAgentActivity,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: colorSchemeIsDark,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: false,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarCloudWorkspaceBadgeTests.\(UUID().uuidString)")!
    }
}
