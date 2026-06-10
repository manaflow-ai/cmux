import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import CmuxGit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


/// Behavioral coverage for the cross-window workspace move primitive that backs
/// dragging a workspace from one window's sidebar into another window's sidebar
/// (`AppDelegate.moveWorkspaceToWindow(workspaceId:windowId:atIndex:focus:)`).
/// The app-level routing needs live windows, but the underlying mechanism —
/// `detachWorkspace` from the source manager + `attachWorkspace(at:)` on the
/// destination manager — is the move and is exercised directly here.
@MainActor
final class CrossWindowWorkspaceMoveTests: XCTestCase {
    func testMoveInsertsAtDropIndexInDestination() {
        let source = TabManager()
        let destination = TabManager()
        let moving = source.addWorkspace()
        _ = source.addWorkspace()

        let destFirst = destination.tabs[0]
        let destSecond = destination.addWorkspace()

        guard let detached = source.detachWorkspace(tabId: moving.id) else {
            XCTFail("Expected to detach the dragged workspace from the source window")
            return
        }
        XCTAssertEqual(detached.id, moving.id)
        destination.attachWorkspace(detached, at: 1, select: true)

        XCTAssertEqual(
            destination.tabs.map(\.id),
            [destFirst.id, moving.id, destSecond.id],
            "Moved workspace should land at the requested drop index in the destination"
        )
        XCTAssertEqual(destination.selectedTabId, moving.id)
        XCTAssertFalse(
            source.tabs.contains { $0.id == moving.id },
            "Source window must no longer contain the moved workspace"
        )
        XCTAssertTrue(
            destination.tabs.allSatisfy { $0.owningTabManager === destination },
            "Destination workspaces should be owned by the destination manager"
        )
    }

    func testMoveAppendsWhenNoDropIndex() {
        let source = TabManager()
        let destination = TabManager()
        let moving = source.addWorkspace()
        _ = source.addWorkspace()

        let existingDestIds = destination.tabs.map(\.id)

        guard let detached = source.detachWorkspace(tabId: moving.id) else {
            XCTFail("Expected to detach the dragged workspace")
            return
        }
        destination.attachWorkspace(detached, at: nil, select: true)

        XCTAssertEqual(
            destination.tabs.map(\.id),
            existingDestIds + [moving.id],
            "With no drop index the moved workspace appends to the destination"
        )
    }

    func testMovingLastWorkspaceKeepsSourceNonEmpty() {
        let source = TabManager()
        let destination = TabManager()
        let onlyWorkspace = source.tabs[0]

        guard let detached = source.detachWorkspace(tabId: onlyWorkspace.id) else {
            XCTFail("Expected to detach the only workspace")
            return
        }
        destination.attachWorkspace(detached, at: nil, select: true)

        XCTAssertFalse(
            source.tabs.isEmpty,
            "Detaching the last workspace must leave the source window with a fresh workspace"
        )
        XCTAssertFalse(
            source.tabs.contains { $0.id == onlyWorkspace.id },
            "The moved workspace should no longer be in the source window"
        )
        XCTAssertTrue(destination.tabs.contains { $0.id == onlyWorkspace.id })
    }

    func testMovingPinnedWorkspaceLandsAtFrontEvenWhenDroppedBelowUnpinnedRows() {
        let source = TabManager()
        let destination = TabManager()
        let destFirst = destination.tabs[0]   // unpinned
        let moving = source.tabs[0]
        source.setPinned(moving, pinned: true)

        guard let detached = source.detachWorkspace(tabId: moving.id) else {
            XCTFail("Expected to detach the pinned workspace")
            return
        }
        XCTAssertTrue(detached.isPinned, "Detach must preserve the pinned state")

        // Request a drop position *below* the destination's unpinned row.
        destination.attachWorkspace(detached, at: 1, select: true)

        XCTAssertEqual(
            destination.tabs.first?.id,
            moving.id,
            "A pinned workspace must land in the leading pinned segment regardless of drop index"
        )
        XCTAssertTrue(destination.tabs.contains { $0.id == destFirst.id })
    }

    func testMovingWorkspaceIntoMiddleOfGroupRunKeepsGroupContiguous() {
        let source = TabManager()
        let destination = TabManager()

        // Build a destination group with an anchor + two members.
        let memberA = destination.tabs[0]
        let memberB = destination.addWorkspace()
        guard let groupId = destination.createWorkspaceGroup(
            name: "Group",
            childWorkspaceIds: [memberA.id, memberB.id]
        ) else {
            XCTFail("Expected to create a destination group")
            return
        }

        let moving = source.tabs[0]
        guard let detached = source.detachWorkspace(tabId: moving.id) else {
            XCTFail("Expected to detach the workspace")
            return
        }
        XCTAssertNil(detached.groupId, "Detach must clear group membership")

        // Aim the insert into the middle of the group's contiguous run.
        let middle = max(1, destination.tabs.count - 1)
        destination.attachWorkspace(detached, at: middle, select: true)

        // The moved (ungrouped) workspace must not sit between grouped rows.
        let groupedOffsets = destination.tabs.enumerated()
            .filter { $0.element.groupId == groupId }
            .map(\.offset)
        XCTAssertFalse(groupedOffsets.isEmpty)
        let isContiguous = groupedOffsets.max()! - groupedOffsets.min()! == groupedOffsets.count - 1
        XCTAssertTrue(
            isContiguous,
            "The destination group's rows must stay contiguous after a cross-window move"
        )
        XCTAssertTrue(destination.tabs.contains { $0.id == moving.id })
    }
}
