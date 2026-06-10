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


@discardableResult
private func assertProportionalEqualizedSplitTree(
    _ node: ExternalTreeNode,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Int {
    switch node {
    case .pane:
        return 1
    case .split(let split):
        let firstLeafCount = assertProportionalEqualizedSplitTree(split.first, file: file, line: line)
        let secondLeafCount = assertProportionalEqualizedSplitTree(split.second, file: file, line: line)
        let totalLeafCount = firstLeafCount + secondLeafCount
        XCTAssertEqual(
            split.dividerPosition,
            Double(firstLeafCount) / Double(totalLeafCount),
            accuracy: 0.000_1,
            file: file,
            line: line
        )
        return totalLeafCount
    }
}

@MainActor
final class TabManagerEqualizeSplitsTests: XCTestCase {
    func testEqualizeSplitsKeepsMultiTabPaneAndBrowserAtHalfWidth() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.2,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, name: "Terminal A"),
                        CmuxSurfaceDefinition(type: .terminal, name: "Terminal B")
                    ])),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .browser, name: "Browser", url: "https://example.com")
                    ]))
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot() else {
            XCTFail("Expected horizontal root split")
            return
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 0.5, accuracy: 0.000_1)

        guard case .pane(let terminalPane) = root.first else {
            XCTFail("Expected first child to remain one pane containing multiple tabs")
            return
        }
        XCTAssertEqual(terminalPane.tabs.count, 2)
    }

    func testEqualizeSplitsBalancesThreeSameAxisSiblingPanesIntoThirds() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.2,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, name: "Left")
                    ])),
                    .split(CmuxSplitDefinition(
                        direction: .horizontal,
                        split: 0.8,
                        children: [
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: "Middle")
                            ])),
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .browser, name: "Right", url: "https://example.com")
                            ]))
                        ]
                    ))
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot(),
              case .split(let rightColumn) = root.second else {
            XCTFail("Expected three-pane same-axis split tree")
            return
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 1.0 / 3.0, accuracy: 0.000_1)
        XCTAssertEqual(rightColumn.orientation, "horizontal")
        XCTAssertEqual(rightColumn.dividerPosition, 0.5, accuracy: 0.000_1)
    }

    func testEqualizeSplitsCountsCrossAxisSubtreeAsOneSpan() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.2,
                children: [
                    .split(CmuxSplitDefinition(
                        direction: .vertical,
                        split: 0.8,
                        children: [
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: "Top Terminal")
                            ])),
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: "Bottom Terminal")
                            ]))
                        ]
                    )),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .browser, name: "Browser", url: "https://example.com")
                    ]))
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot(),
              case .split(let leftStack) = root.first else {
            XCTFail("Expected browser beside a vertically stacked terminal subtree")
            return
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(leftStack.orientation, "vertical")
        XCTAssertEqual(leftStack.dividerPosition, 0.5, accuracy: 0.000_1)
    }

    func testEqualizeSplitsDoesNotPropagateSameAxisSpansThroughCrossAxisBoundary() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: .horizontal,
                split: 0.2,
                children: [
                    .split(CmuxSplitDefinition(
                        direction: .vertical,
                        split: 0.8,
                        children: [
                            .split(CmuxSplitDefinition(
                                direction: .horizontal,
                                split: 0.8,
                                children: [
                                    .pane(CmuxPaneDefinition(surfaces: [
                                        CmuxSurfaceDefinition(type: .terminal, name: "Top Left")
                                    ])),
                                    .pane(CmuxPaneDefinition(surfaces: [
                                        CmuxSurfaceDefinition(type: .terminal, name: "Top Right")
                                    ]))
                                ]
                            )),
                            .pane(CmuxPaneDefinition(surfaces: [
                                CmuxSurfaceDefinition(type: .terminal, name: "Bottom")
                            ]))
                        ]
                    )),
                    .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .browser, name: "Browser", url: "https://example.com")
                    ]))
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )

        XCTAssertTrue(manager.equalizeSplits(tabId: workspace.id), "Expected equalize splits command to succeed")

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot(),
              case .split(let leftStack) = root.first,
              case .split(let topRow) = leftStack.first else {
            XCTFail("Expected browser beside a mixed nested terminal subtree")
            return
        }
        XCTAssertEqual(root.orientation, "horizontal")
        XCTAssertEqual(root.dividerPosition, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(leftStack.orientation, "vertical")
        XCTAssertEqual(leftStack.dividerPosition, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(topRow.orientation, "horizontal")
        XCTAssertEqual(topRow.dividerPosition, 0.5, accuracy: 0.000_1)
    }
}

