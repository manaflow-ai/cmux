import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG


final class BonsplitTabDragPayloadTests: XCTestCase {
    func testRejectsFilePreviewCompatibilityPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: "filePreview", includesFilePreviewTransferType: true)

        XCTAssertNil(
            BonsplitTabDragPayload.transfer(from: pasteboard),
            "Sidebar workspace drop targets should ignore file-preview drags instead of treating them as movable tabs"
        )
    }

    func testAcceptsRealFilePreviewTabPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: "filePreview")

        XCTAssertNotNil(
            BonsplitTabDragPayload.transfer(from: pasteboard),
            "Existing file-preview tabs should still move through normal Bonsplit tab drag paths"
        )
    }

    func testAcceptsRegularCurrentProcessTabPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: nil)

        XCTAssertNotNil(BonsplitTabDragPayload.transfer(from: pasteboard))
    }

    func testWorkspaceDropRoutingAcceptsTabTransferTypeOnly() {
        XCTAssertTrue(
            BonsplitTabDragPayload.canRouteWorkspaceDrop(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType]
            )
        )
    }

    func testWorkspaceDropRoutingRejectsFilePreviewCompatibilityTransfer() {
        XCTAssertFalse(
            BonsplitTabDragPayload.canRouteWorkspaceDrop(
                pasteboardTypes: [
                    DragOverlayRoutingPolicy.filePreviewTransferType,
                    DragOverlayRoutingPolicy.bonsplitTabTransferType,
                ]
            )
        )
    }

    private func makeBonsplitPayloadPasteboard(
        kind: String?,
        includesFilePreviewTransferType: Bool = false
    ) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.bonsplit.\(UUID().uuidString)"))
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
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier))
        if includesFilePreviewTransferType {
            pasteboard.setData(data, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
        }
        return pasteboard
    }
}

#endif
