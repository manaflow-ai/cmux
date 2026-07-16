import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("AppKit sidebar native controller scale", .serialized)
struct SidebarAppKitViewControllerScaleTests {
    private static let viewportRowCeiling = 32
    private static let viewportResolverCallCeiling = 64

    @Test(arguments: [1, 10, 100, 1_000])
    func lazyResolversStayViewportBounded(workspaceCount: Int) throws {
        let harness = try Harness(workspaceCount: workspaceCount)
        defer { harness.tearDown() }

        let realizedRows = harness.realizeVisibleRows()
        let realizedWorkspaceIDs = Set(realizedRows.compactMap {
            harness.workspaceID(atRow: $0)
        })
        let resolvedWorkspaceIDs = Set(harness.recorder.workspaceSnapshotIDs)

        #expect(!realizedRows.isEmpty)
        #expect(realizedRows.count <= Self.viewportRowCeiling)
        #expect(!resolvedWorkspaceIDs.isEmpty)
        #expect(resolvedWorkspaceIDs.isSubset(of: realizedWorkspaceIDs))
        #expect(
            harness.recorder.workspaceSnapshotIDs.count
                <= Self.viewportResolverCallCeiling
        )
        #expect(
            harness.recorder.workspaceActionIDs.count
                <= Self.viewportResolverCallCeiling
        )
        #expect(
            Set(harness.recorder.workspaceActionIDs)
                .isSubset(of: realizedWorkspaceIDs)
        )
        if workspaceCount >= 100 {
            #expect(harness.recorder.workspaceSnapshotIDs.count < workspaceCount)
            #expect(harness.recorder.workspaceActionIDs.count < workspaceCount)
        }

        #if DEBUG
        #expect(
            harness.controller.resolverInvocationCounts.workspaceSnapshots
                == harness.recorder.workspaceSnapshotIDs.count
        )
        #expect(
            harness.controller.resolverInvocationCounts.workspaceActions
                == harness.recorder.workspaceActionIDs.count
        )
        #expect(harness.controller.resolverInvocationCounts.groupSnapshots == 0)
        #expect(harness.controller.resolverInvocationCounts.groupActions == 0)
        #endif
    }

    @Test(arguments: [1, 10, 100, 1_000])
    func keyedUpdateReloadsAtMostOneVisibleNativeRow(workspaceCount: Int) throws {
        let harness = try Harness(workspaceCount: workspaceCount)
        defer { harness.tearDown() }

        let realizedRows = harness.realizeVisibleRows()
        let targetRow = try #require(realizedRows.first)
        let targetWorkspaceID = try #require(harness.workspaceID(atRow: targetRow))
        let cellIdentitiesBeforeUpdate = harness.realizedCellIdentities()
        harness.recorder.reset()
        #if DEBUG
        harness.controller.resetResolverInvocationCounts()
        #endif

        harness.controller.reconfigure(
            itemIDs: Set([SidebarWorkspaceRenderItemID.workspace(targetWorkspaceID)])
        )
        harness.layout()
        _ = harness.controller.tableView.view(
            atColumn: 0,
            row: targetRow,
            makeIfNecessary: true
        )

        let resolvedWorkspaceIDs = Set(harness.recorder.workspaceSnapshotIDs)
        let resolvedActionIDs = Set(harness.recorder.workspaceActionIDs)
        #expect(resolvedWorkspaceIDs == Set([targetWorkspaceID]))
        #expect(resolvedWorkspaceIDs.count <= 1)
        #expect(resolvedActionIDs == Set([targetWorkspaceID]))
        #expect(resolvedActionIDs.count <= 1)

        let cellIdentitiesAfterUpdate = harness.realizedCellIdentities()
        for (row, identity) in cellIdentitiesBeforeUpdate where row != targetRow {
            #expect(cellIdentitiesAfterUpdate[row] == identity)
        }

        #if DEBUG
        #expect(harness.controller.resolverInvocationCounts.workspaceSnapshots >= 1)
        #expect(harness.controller.resolverInvocationCounts.workspaceActions >= 1)
        #expect(harness.controller.resolverInvocationCounts.groupSnapshots == 0)
        #expect(harness.controller.resolverInvocationCounts.groupActions == 0)
        #endif
    }

    @Test(arguments: [1, 10, 100, 1_000])
    func hoverTransitionDoesNotResolveNativeRows(workspaceCount: Int) throws {
        let harness = try Harness(workspaceCount: workspaceCount)
        defer { harness.tearDown() }

        let realizedRows = harness.realizeVisibleRows()
        let oldRow = try #require(realizedRows.first)
        let nextRow = realizedRows.dropFirst().first
        let nextWorkspaceID = nextRow.flatMap { harness.workspaceID(atRow: $0) }

        harness.controller.tableView.onHoveredRowChanged?(nil, oldRow)
        harness.recorder.reset()
        harness.recorder.hoveredItemIDs.removeAll(keepingCapacity: true)
        #if DEBUG
        harness.controller.resetResolverInvocationCounts()
        #endif

        harness.controller.tableView.onHoveredRowChanged?(oldRow, nextRow)

        #expect(harness.recorder.workspaceSnapshotIDs.isEmpty)
        #expect(harness.recorder.workspaceActionIDs.isEmpty)
        #expect(
            harness.recorder.hoveredItemIDs
                == [nextWorkspaceID.map { SidebarWorkspaceRenderItemID.workspace($0) }]
        )

        #if DEBUG
        #expect(harness.controller.resolverInvocationCounts.workspaceSnapshots == 0)
        #expect(harness.controller.resolverInvocationCounts.workspaceActions == 0)
        #expect(harness.controller.resolverInvocationCounts.groupSnapshots == 0)
        #expect(harness.controller.resolverInvocationCounts.groupActions == 0)
        #endif
    }

    @MainActor
    private final class ResolverRecorder {
        var workspaceSnapshotIDs: [UUID] = []
        var workspaceActionIDs: [UUID] = []
        var hoveredItemIDs: [SidebarWorkspaceRenderItemID?] = []

        func reset() {
            workspaceSnapshotIDs.removeAll(keepingCapacity: true)
            workspaceActionIDs.removeAll(keepingCapacity: true)
        }
    }

    @MainActor
    private final class Harness {
        let workspaceIDs: [UUID]
        let recorder: ResolverRecorder
        let controller: SidebarAppKitViewController

        private let defaults: UserDefaults
        private let defaultsSuiteName: String
        private let window: NSWindow

        init(workspaceCount: Int) throws {
            _ = NSApplication.shared

            let workspaceIDs = (0..<workspaceCount).map { _ in UUID() }
            let rowByWorkspaceID = Dictionary(
                uniqueKeysWithValues: workspaceIDs.enumerated().map { ($0.element, $0.offset) }
            )
            let recorder = ResolverRecorder()
            let defaultsSuiteName = "SidebarAppKitViewControllerScaleTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
            let contextMenu = Self.contextMenuSnapshot()
            let controller = SidebarAppKitViewController()

            controller.apply(SidebarAppKitConfiguration(
                renderItems: workspaceIDs.map { .workspace(workspaceId: $0) },
                selectedWorkspaceIDs: [],
                activeWorkspaceID: nil,
                workspaceSnapshot: { workspaceID in
                    recorder.workspaceSnapshotIDs.append(workspaceID)
                    guard let row = rowByWorkspaceID[workspaceID] else { return nil }
                    return Self.rowSnapshot(
                        workspaceID: workspaceID,
                        row: row,
                        workspaceCount: workspaceCount,
                        settings: settings,
                        contextMenu: contextMenu
                    )
                },
                groupSnapshot: { _ in nil },
                workspaceActions: { workspaceID in
                    recorder.workspaceActionIDs.append(workspaceID)
                    return .none
                },
                groupActions: { _ in .none },
                interactions: .init(onHoveredItemChanged: { itemID in
                    recorder.hoveredItemIDs.append(itemID)
                })
            ))

            let viewportSize = NSSize(width: 280, height: 320)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: viewportSize),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.contentViewController = controller
            window.setContentSize(viewportSize)

            self.workspaceIDs = workspaceIDs
            self.recorder = recorder
            self.controller = controller
            self.defaults = defaults
            self.defaultsSuiteName = defaultsSuiteName
            self.window = window

            layout()
        }

        func tearDown() {
            controller.prepareForRemoval()
            window.contentViewController = nil
            window.close()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        func layout() {
            controller.view.layoutSubtreeIfNeeded()
            controller.scrollView.layoutSubtreeIfNeeded()
            controller.tableView.layoutSubtreeIfNeeded()
        }

        func realizeVisibleRows() -> IndexSet {
            layout()
            let tableView = controller.tableView
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            if visibleRange.location != NSNotFound, visibleRange.length > 0 {
                let upperBound = min(
                    tableView.numberOfRows,
                    visibleRange.location + visibleRange.length
                )
                if visibleRange.location < upperBound {
                    for row in visibleRange.location..<upperBound {
                        _ = tableView.view(
                            atColumn: 0,
                            row: row,
                            makeIfNecessary: true
                        )
                    }
                }
            } else if tableView.numberOfRows > 0 {
                _ = tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
            }
            layout()

            var rows = IndexSet()
            for row in 0..<tableView.numberOfRows where tableView.rowView(
                atRow: row,
                makeIfNecessary: false
            ) != nil {
                rows.insert(row)
            }
            return rows
        }

        func workspaceID(atRow row: Int) -> UUID? {
            guard workspaceIDs.indices.contains(row) else { return nil }
            return workspaceIDs[row]
        }

        func realizedCellIdentities() -> [Int: ObjectIdentifier] {
            var identities: [Int: ObjectIdentifier] = [:]
            for row in 0..<controller.tableView.numberOfRows {
                guard let view = controller.tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) else { continue }
                identities[row] = ObjectIdentifier(view)
            }
            return identities
        }

        private static func rowSnapshot(
            workspaceID: UUID,
            row: Int,
            workspaceCount: Int,
            settings: SidebarTabItemSettingsSnapshot,
            contextMenu: SidebarWorkspaceContextMenuSnapshot
        ) -> SidebarWorkspaceRowSnapshot {
            SidebarWorkspaceRowSnapshot(
                workspaceId: workspaceID,
                groupId: nil,
                index: row,
                workspaceCount: workspaceCount,
                workspace: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(
                    title: "Workspace \(row + 1)"
                ),
                isActive: row == 0,
                isMultiSelected: false,
                hasUserCustomTitle: false,
                hasCustomTitle: false,
                hasCustomDescription: false,
                customTitle: nil,
                workspaceShortcutDigit: nil,
                workspaceShortcutModifierSymbol: "⌘",
                canCloseWorkspace: workspaceCount > 1,
                unreadCount: 0,
                latestNotificationText: nil,
                showsAgentActivity: false,
                rowSpacing: 0,
                showsModifierShortcutHints: false,
                isPointerHovering: false,
                isBeingDragged: false,
                topDropIndicatorVisible: false,
                bottomDropIndicatorVisible: false,
                isBonsplitWorkspaceDropActive: false,
                settings: settings,
                isChecklistExpanded: false,
                checklistAddFieldActivationToken: 0,
                isChecklistPopoverPresented: false,
                contextMenu: contextMenu
            )
        }

        private static func contextMenuSnapshot() -> SidebarWorkspaceContextMenuSnapshot {
            SidebarWorkspaceContextMenuSnapshot(
                targetWorkspaceIds: [],
                remoteTargetWorkspaceIds: [],
                allRemoteTargetsConnecting: false,
                allRemoteTargetsDisconnected: false,
                pinState: nil,
                groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
                canCreateEmptyGroup: true,
                eligibleGroupTargetIds: [],
                allEligibleTargetsGroupId: nil,
                hasGroupedEligibleTarget: false,
                todoStatusLanes: [],
                canMarkRead: false,
                canMarkUnread: false,
                hasLatestNotification: false,
                notifications: []
            )
        }
    }
}
