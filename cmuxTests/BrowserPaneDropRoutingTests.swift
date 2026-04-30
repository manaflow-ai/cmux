import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserPaneDropRoutingTests: XCTestCase {
    func testVerticalZonesFollowAppKitCoordinates() {
        let size = CGSize(width: 240, height: 180)

        XCTAssertEqual(
            BrowserPaneDropRouting.zone(for: CGPoint(x: size.width * 0.5, y: size.height - 8), in: size),
            .top
        )
        XCTAssertEqual(
            BrowserPaneDropRouting.zone(for: CGPoint(x: size.width * 0.5, y: 8), in: size),
            .bottom
        )
    }

    func testTopChromeHeightPushesTopSplitThresholdIntoWebView() {
        let size = CGSize(width: 240, height: 180)

        XCTAssertEqual(
            BrowserPaneDropRouting.zone(
                for: CGPoint(x: size.width * 0.5, y: 110),
                in: size,
                topChromeHeight: 36
            ),
            .center
        )
        XCTAssertEqual(
            BrowserPaneDropRouting.zone(
                for: CGPoint(x: size.width * 0.5, y: 150),
                in: size,
                topChromeHeight: 36
            ),
            .top
        )
    }

    func testHitTestingCapturesOnlyForRelevantDragEvents() {
        XCTAssertTrue(
            BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .cursorUpdate
            )
        )
        XCTAssertFalse(
            BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .leftMouseDown
            )
        )
        XCTAssertFalse(
            BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .cursorUpdate
            )
        )

        let externalPayloads: [[NSPasteboard.PasteboardType]] = [
            [.fileURL],
            [.URL],
            [.png],
            [.tiff],
            [.html],
            [.string],
            [.fileURL, .png],
        ]

        for pasteboardTypes in externalPayloads {
            XCTAssertFalse(
                BrowserPaneDropTargetView.shouldCaptureHitTesting(
                    pasteboardTypes: pasteboardTypes,
                    eventType: .cursorUpdate
                ),
                "Browser pane drop target should not capture external drag payload: \(pasteboardTypes)"
            )
        }
    }

    func testCenterDropOnSamePaneIsNoOp() {
        let paneId = PaneID(id: UUID())
        let target = BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: paneId
        )
        let transfer = BrowserPaneDragTransfer(
            tabId: UUID(),
            sourcePaneId: paneId.id,
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertEqual(
            BrowserPaneDropRouting.action(for: transfer, target: target, zone: .center),
            .noOp
        )
    }

    func testRightEdgeDropBuildsSplitMoveAction() {
        let paneId = PaneID(id: UUID())
        let target = BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: paneId
        )
        let tabId = UUID()
        let transfer = BrowserPaneDragTransfer(
            tabId: tabId,
            sourcePaneId: UUID(),
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertEqual(
            BrowserPaneDropRouting.action(for: transfer, target: target, zone: .right),
            .move(
                tabId: tabId,
                targetWorkspaceId: target.workspaceId,
                targetPane: paneId,
                splitTarget: BrowserPaneSplitTarget(orientation: .horizontal, insertFirst: false)
            )
        )
    }

    func testDecodeTransferPayloadReadsTabAndSourcePane() {
        let tabId = UUID()
        let sourcePaneId = UUID()
        let payload = try! JSONSerialization.data(
            withJSONObject: [
                "tab": ["id": tabId.uuidString],
                "sourcePaneId": sourcePaneId.uuidString,
                "sourceProcessId": ProcessInfo.processInfo.processIdentifier,
            ]
        )

        let transfer = BrowserPaneDragTransfer.decode(from: payload)

        XCTAssertEqual(transfer?.tabId, tabId)
        XCTAssertEqual(transfer?.sourcePaneId, sourcePaneId)
        XCTAssertTrue(transfer?.isFromCurrentProcess == true)
    }
}
