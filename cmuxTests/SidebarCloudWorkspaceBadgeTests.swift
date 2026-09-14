import AppKit
import CmuxCore
import Observation
import Testing
@testable import cmux_DEV

@Suite(.serialized)
@MainActor
struct SidebarCloudWorkspaceBadgeTests {
    /// Ensures Cloud identity changes alter only the immutable row projection.
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

    /// Ensures context-menu refreshes preserve the Cloud identity.
    @Test func cloudIdentityUpdatesWhileContextMenuIsOpen() {
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let factory = SidebarWorkspaceSnapshotFactory(workspace: workspace, settings: settings, showsAgentActivity: false)
        let local = factory.makeSnapshot()
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true)
        let cloud = factory.makeSnapshot()
        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: local, next: cloud, force: false, contextMenuVisible: true
        )
        #expect(decision.workspaceSnapshotStorage?.cloudWorkspaceLabel == cloud.cloudWorkspaceLabel)
        #expect(decision.workspaceSnapshotStorage?.cloudWorkspaceLabel != nil)
    }

    /// Ensures restored Cloud identity survives every connection presentation state.
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

    /// Exercises the real row geometry across selection, density, scaling, and pinning.
    @Test(arguments: [180.0, 280.0], [false, true])
    func cloudBadgeLeadsTitleWithoutDisplacingPin(width: Double, isPinned: Bool) throws {
        for dark in [false, true] {
            for isActive in [false, true] {
                for compact in [false, true] {
                    for magnification in [100, 150] {
                        try verifyCloudBadge(width: width, isPinned: isPinned, dark: dark,
                            isActive: isActive, compact: compact, magnification: magnification)
                    }
                }
            }
        }
    }

    private func verifyCloudBadge(
        width: Double, isPinned: Bool, dark: Bool, isActive: Bool, compact: Bool, magnification: Int
    ) throws {
        let defaults = Self.makeDefaults()
        defaults.set(false, forKey: "sidebarWrapWorkspaceTitles")
        defaults.set(compact, forKey: "sidebarHideAllDetails")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let workspace = Workspace(title: "Same project with a long workspace name",
            workingDirectory: "/home/cmux", initialSurface: .cloudVMLoading)
        workspace.isPinned = isPinned
        let factory = SidebarWorkspaceSnapshotFactory(workspace: workspace, settings: settings, showsAgentActivity: false)
        let localSnapshot = factory.makeSnapshot()
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false)
        workspace.updateCloudPanelDirectory(panelId: try #require(workspace.focusedPanelId), directory: "/home/cmux")
        let cloudSnapshot = factory.makeSnapshot()
        let model = Self.makeModel(settings: settings, workspaceSnapshot: cloudSnapshot,
            colorSchemeIsDark: dark, isActive: isActive, magnification: magnification)
        let cell = SidebarAppKitRowCellTests.configuredCell(model: model, tab: workspace)
        cell.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let height = cell.layoutContent(model: model, width: width, apply: false)
        cell.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: cell.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = cell
        defer { window.contentView = nil }
        cell.layoutSubtreeIfNeeded()
        let images = SidebarAppKitRowCellTests.descendants(of: cell).compactMap { $0 as? NSImageView }
        let badges = images.filter {
            $0.accessibilityIdentifier() == "sidebarCloudBadge"
        }
        #expect(badges.count == 1)
        let badge = try #require(badges.first)
        let title = try #require(SidebarAppKitRowCellTests.descendants(of: cell).compactMap { $0 as? SidebarRowTextView }.first {
            $0.stringValue == cloudSnapshot.title
        })
        let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: bitmap)
        #if compiler(>=6.2)
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])),
            named: "cloud-\(Int(width))-pin\(isPinned)-active\(isActive)-compact\(compact)-dark\(dark)-scale\(magnification).png")
        #endif
        #expect(!badge.isHidden)
        #expect(badge.image != nil)
        #expect(badge.toolTip == "Cloud workspace on vivid-newt")
        #expect(badge.contentTintColor != title.textColor)
        #expect(title.frame.width > 60)
        #expect(badge.frame.maxX + 8 == title.frame.minX)
        #expect(title.frame.maxX <= width)
        #expect(title.lineBreakMode == .byTruncatingTail)
        #expect(cell.accessibilityLabel()?.contains("Cloud workspace on vivid-newt") == true)
        let pins = images.filter { !$0.isHidden && $0.toolTip == String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip", defaultValue: "Pinned workspace — protected from Close") }
        #expect(pins.count == (isPinned ? 1 : 0))
        if isPinned {
            let pin = try #require(pins.first)
            #expect(pin.frame.maxX + 8 == badge.frame.minX)
            #expect(pin.frame.midY == badge.frame.midY)
        }
        let cloudTitleFrame = title.frame
        let directoryFrames = SidebarAppKitRowCellTests.descendants(of: cell)
            .compactMap { $0 as? SidebarRowTextView }
            .filter { !$0.isHidden && $0.stringValue.contains("/home/cmux") }
            .map(\.frame)
        #expect(directoryFrames.isEmpty == compact)
        cell.applyRebuiltModel(Self.makeModel(settings: settings, workspaceSnapshot: localSnapshot,
            colorSchemeIsDark: dark, isActive: isActive, magnification: magnification))
        cell.layoutSubtreeIfNeeded()
        #expect(badge.isHidden)
        #expect(title.frame.minX < cloudTitleFrame.minX)
        #expect(title.frame.maxX == cloudTitleFrame.maxX)
        #expect(cell.accessibilityLabel()?.contains("Cloud workspace") == false)
        #expect(cell.layoutContent(model: try #require(cell.currentModelForMeasurement), width: width, apply: false) == height)
        #expect(SidebarAppKitRowCellTests.descendants(of: cell).compactMap { $0 as? SidebarRowTextView }
            .filter { !$0.isHidden && $0.stringValue.contains("/home/cmux") }.map(\.frame) == directoryFrames)
    }

    /// SwiftUI consumers track Cloud identity through Workspace's existing read facade.
    @Test(.timeLimit(.minutes(1)))
    func cloudIdentityParticipatesInObservationTracking() async {
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        withObservationTracking {
            #expect(workspace.cloudVMID == nil)
        } onChange: {
            changes.continuation.yield(())
            changes.continuation.finish()
        }
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true)
        var iterator = changes.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(workspace.cloudVMID == "vivid-newt")
    }

    /// Every observer sees the current binding, including changes made before subscription.
    @Test(.timeLimit(.minutes(1)))
    func cloudBindingChangesReplayToEveryObserver() async {
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true)
        var first = workspace.cloudBindingState.changes().makeAsyncIterator()
        var second = workspace.cloudBindingState.changes().makeAsyncIterator()
        #expect(await first.next() == 1)
        #expect(await second.next() == 1)
        workspace.cloudVMBinding = nil
        #expect(await first.next() == 2)
        #expect(await second.next() == 2)
        #expect(workspace.cloudVMID == nil)
    }

    /// A slow sidebar receives only the newest invalidation after a burst of binding changes.
    @Test(.timeLimit(.minutes(1)))
    func cloudBindingChangesCoalesceAndDeduplicate() async {
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        var changes = workspace.cloudBindingState.changes().makeAsyncIterator()
        #expect(await changes.next() == 0)
        for index in 1...100 {
            let binding = WorkspaceCloudVMBinding(vmID: "machine-\(index)", isBase: true)
            workspace.cloudVMBinding = binding
            workspace.cloudVMBinding = binding
        }
        #expect(await changes.next() == 100)
        #expect(workspace.cloudVMID == "machine-100")
    }

    /// Cancelling one subscriber finishes its stream without disconnecting other sidebars.
    @Test(.timeLimit(.minutes(1)))
    func cloudBindingObservationCancellationIsIndependent() async {
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        let cancelledChanges = workspace.cloudBindingState.changes()
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            var iterator = cancelledChanges.makeAsyncIterator()
            _ = await iterator.next()
            started.continuation.yield(())
            started.continuation.finish()
            return await iterator.next()
        }
        var readiness = started.stream.makeAsyncIterator()
        _ = await readiness.next()
        consumer.cancel()
        #expect(await consumer.value == nil)
        var active = workspace.cloudBindingState.changes().makeAsyncIterator()
        #expect(await active.next() == 0)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: true)
        #expect(await active.next() == 1)
    }

    private static func makeModel(
        settings: SidebarTabItemSettingsSnapshot,
        workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        colorSchemeIsDark: Bool = true,
        isActive: Bool = false,
        magnification: Int = 100
    ) -> SidebarWorkspaceRowModel {
        return SidebarWorkspaceRowModel(
            workspaceId: UUID(),
            index: 0,
            snapshot: workspaceSnapshot,
            settings: settings,
            isActive: isActive,
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
            globalFontMagnificationPercent: magnification,
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
