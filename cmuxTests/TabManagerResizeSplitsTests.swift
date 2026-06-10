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


private func splitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
    switch node {
    case .pane:
        return []
    case .split(let split):
        return [split] + splitNodes(in: split.first) + splitNodes(in: split.second)
    }
}

@MainActor
final class TabManagerResizeSplitsTests: XCTestCase {
    func testResizeSplitMovesHorizontalDividerRightForFirstChildPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) != nil else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.5, forSplit: splitId),
            "Expected to seed divider position"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: leftPanelId, direction: .right, amount: 120),
            "Expected resizeSplit to succeed for the right edge of the left pane"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertGreaterThan(
            updatedSplit.dividerPosition,
            0.5,
            "Expected resizing the left pane to the right to move the divider toward the second child"
        )
    }

    func testResizeSplitMovesHorizontalDividerLeftForSecondChildPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.5, forSplit: splitId),
            "Expected to seed divider position"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: rightPanel.id, direction: .left, amount: 120),
            "Expected resizeSplit to succeed for the left edge of the right pane"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertLessThan(
            updatedSplit.dividerPosition,
            0.5,
            "Expected resizing the right pane to the left to move the divider toward the first child"
        )
    }

    func testResizeSplitMovesVerticalDividerDownForFirstChildPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let topPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: topPanelId, orientation: .vertical) != nil else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.5, forSplit: splitId),
            "Expected to seed divider position"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: topPanelId, direction: .down, amount: 120),
            "Expected resizeSplit to succeed for the bottom edge of the top pane"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertGreaterThan(
            updatedSplit.dividerPosition,
            0.5,
            "Expected resizing the top pane downward to move the divider toward the second child"
        )
    }

    func testResizeSplitMovesVerticalDividerUpForSecondChildPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let topPanelId = workspace.focusedPanelId,
              let bottomPanel = workspace.newTerminalSplit(from: topPanelId, orientation: .vertical) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.5, forSplit: splitId),
            "Expected to seed divider position"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: bottomPanel.id, direction: .up, amount: 120),
            "Expected resizeSplit to succeed for the top edge of the bottom pane"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertLessThan(
            updatedSplit.dividerPosition,
            0.5,
            "Expected resizing the bottom pane upward to move the divider toward the first child"
        )
    }

    func testResizeSplitReturnsFalseWhenPaneHasNoBorderInDirection() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) != nil else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertFalse(
            manager.resizeSplit(tabId: workspace.id, surfaceId: leftPanelId, direction: .left, amount: 120),
            "Expected resizeSplit to fail when the pane has no adjacent border in that direction"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }
        XCTAssertEqual(updatedSplit.dividerPosition, split.dividerPosition, accuracy: 0.000_1)
    }

    func testResizeSplitClampsDividerPositionAtUpperBound() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) != nil else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.89, forSplit: splitId),
            "Expected to seed divider position near upper bound"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: leftPanelId, direction: .right, amount: 10_000),
            "Expected resizeSplit to clamp instead of failing"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertEqual(updatedSplit.dividerPosition, 0.9, accuracy: 0.000_1)
    }

    func testResizeSplitClampsDividerPositionAtLowerBound() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let topPanelId = workspace.focusedPanelId,
              let bottomPanel = workspace.newTerminalSplit(from: topPanelId, orientation: .vertical) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        guard let split = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first,
              let splitId = UUID(uuidString: split.id) else {
            XCTFail("Expected a split node in tree snapshot")
            return
        }

        XCTAssertTrue(
            workspace.bonsplitController.setDividerPosition(0.11, forSplit: splitId),
            "Expected to seed divider position near lower bound"
        )

        XCTAssertTrue(
            manager.resizeSplit(tabId: workspace.id, surfaceId: bottomPanel.id, direction: .up, amount: 10_000),
            "Expected resizeSplit to clamp instead of failing"
        )

        guard let updatedSplit = splitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected updated split node in tree snapshot")
            return
        }

        XCTAssertEqual(updatedSplit.dividerPosition, 0.1, accuracy: 0.000_1)
    }
}


