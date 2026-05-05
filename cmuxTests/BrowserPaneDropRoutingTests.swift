import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserPaneDropRoutingTests: XCTestCase {
    func testFilePreviewPanelTypeUsesLowercaseRawValueWithLegacyDecode() throws {
        XCTAssertEqual(PanelType.filePreview.rawValue, "filepreview")
        XCTAssertEqual(PanelType(rawValue: "filepreview"), .filePreview)
        let legacy = try JSONDecoder().decode(PanelType.self, from: Data("\"filePreview\"".utf8))
        XCTAssertEqual(legacy, .filePreview)
    }

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
                "tab": ["id": tabId.uuidString, "kind": "filePreview"],
                "sourcePaneId": sourcePaneId.uuidString,
                "sourceProcessId": ProcessInfo.processInfo.processIdentifier,
            ]
        )

        let transfer = BrowserPaneDragTransfer.decode(from: payload)

        XCTAssertEqual(transfer?.tabId, tabId)
        XCTAssertEqual(transfer?.sourcePaneId, sourcePaneId)
        XCTAssertTrue(transfer?.isFromCurrentProcess == true)
        XCTAssertEqual(transfer?.kind, "filePreview")
        XCTAssertTrue(transfer?.isFilePreview == false)
    }

    func testDecodePasteboardUsesDedicatedFilePreviewTransferType() throws {
        let realTabPasteboard = try makeBonsplitPanePayloadPasteboard(
            kind: "filePreview",
            includesFilePreviewTransferType: false
        )
        let realTabTransfer = try XCTUnwrap(BrowserPaneDragTransfer.decode(from: realTabPasteboard))
        XCTAssertFalse(realTabTransfer.isFilePreview)
        XCTAssertEqual(realTabTransfer.kind, "filePreview")

        let syntheticPasteboard = try makeBonsplitPanePayloadPasteboard(
            kind: "filePreview",
            includesFilePreviewTransferType: true
        )
        let syntheticTransfer = try XCTUnwrap(BrowserPaneDragTransfer.decode(from: syntheticPasteboard))
        XCTAssertTrue(syntheticTransfer.isFilePreview)
    }

    func testFilePreviewDropDestinationUsesPaneCenterOrSplitZone() {
        let paneId = PaneID(id: UUID())
        let target = BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: paneId
        )

        switch BrowserPaneDropRouting.filePreviewDestination(target: target, zone: .center) {
        case .insert(let destinationPane, let index):
            XCTAssertEqual(destinationPane, paneId)
            XCTAssertNil(index)
        default:
            XCTFail("Center file-preview drops should insert into the target pane")
        }

        switch BrowserPaneDropRouting.filePreviewDestination(target: target, zone: .left) {
        case .split(let destinationPane, let orientation, let insertFirst):
            XCTAssertEqual(destinationPane, paneId)
            XCTAssertEqual(orientation, .horizontal)
            XCTAssertTrue(insertFirst)
        default:
            XCTFail("Edge file-preview drops should split the target pane")
        }
    }

    private func makeBonsplitPanePayloadPasteboard(
        kind: String?,
        includesFilePreviewTransferType: Bool
    ) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.browser-pane.\(UUID().uuidString)"))
        pasteboard.clearContents()

        var tab: [String: Any] = ["id": UUID().uuidString]
        if let kind {
            tab["kind"] = kind
        }
        let payload: [String: Any] = [
            "tab": tab,
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        pasteboard.setData(data, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
        if includesFilePreviewTransferType {
            pasteboard.setData(data, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
        }
        return pasteboard
    }
}
