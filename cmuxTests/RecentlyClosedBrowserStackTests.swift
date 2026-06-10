@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class RecentlyClosedBrowserStackTests: XCTestCase {
    func testPopReturnsEntriesInLIFOOrder() {
        var stack = RecentlyClosedBrowserStack(capacity: 20)
        stack.push(makeSnapshot(index: 1))
        stack.push(makeSnapshot(index: 2))
        stack.push(makeSnapshot(index: 3))

        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 2)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 1)
        XCTAssertNil(stack.pop())
    }

    func testPushDropsOldestEntriesWhenCapacityExceeded() {
        var stack = RecentlyClosedBrowserStack(capacity: 3)
        for index in 1...5 {
            stack.push(makeSnapshot(index: index))
        }

        XCTAssertEqual(stack.pop()?.originalTabIndex, 5)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 4)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 3)
        XCTAssertNil(stack.pop())
    }

    func testRemoveSnapshotsDropsOnlyEntriesForGivenWorkspaceId() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        var stack = RecentlyClosedBrowserStack(capacity: 20)
        stack.push(makeSnapshot(index: 1, workspaceId: workspaceA))
        stack.push(makeSnapshot(index: 2, workspaceId: workspaceB))
        stack.push(makeSnapshot(index: 3, workspaceId: workspaceA))
        stack.push(makeSnapshot(index: 4, workspaceId: workspaceB))

        stack.removeSnapshots(forWorkspaceId: workspaceA)

        XCTAssertEqual(stack.pop()?.originalTabIndex, 4)
        XCTAssertEqual(stack.pop()?.originalTabIndex, 2)
        XCTAssertNil(stack.pop())
    }

    private func makeSnapshot(index: Int, workspaceId: UUID = UUID()) -> ClosedBrowserPanelRestoreSnapshot {
        ClosedBrowserPanelRestoreSnapshot(
            workspaceId: workspaceId,
            url: URL(string: "https://example.com/\(index)"),
            profileID: nil,
            originalPaneId: UUID(),
            originalTabIndex: index,
            fallbackSplitOrientation: .horizontal,
            fallbackSplitInsertFirst: false,
            fallbackAnchorPaneId: UUID()
        )
    }
}

