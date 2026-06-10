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


final class FilePreviewDragPasteboardWriterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FilePreviewDragRegistry.shared.discardAll()
        NSPasteboard(name: .drag).clearContents()
    }

    override func tearDown() {
        NSPasteboard(name: .drag).clearContents()
        FilePreviewDragRegistry.shared.discardAll()
        super.tearDown()
    }

    func testRegistrationIsPreparedWhenDragTypesAreRequested() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/example.txt").standardizedFileURL
        let writer = FilePreviewDragPasteboardWriter(
            filePath: fileURL.path,
            displayTitle: "example.txt"
        )
        let dragPasteboard = NSPasteboard(name: .drag)

        XCTAssertNil(FilePreviewDragPasteboardWriter.dragID(from: dragPasteboard))
        let writableTypes = writer.writableTypes(for: dragPasteboard)
        XCTAssertTrue(writableTypes.contains(.fileURL))
        let preparedDragID = try XCTUnwrap(FilePreviewDragPasteboardWriter.dragID(from: dragPasteboard))
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: preparedDragID))
        XCTAssertEqual(
            writer.pasteboardPropertyList(forType: .fileURL) as? String,
            fileURL.absoluteString
        )

        let filePreviewData = try XCTUnwrap(
            writer.pasteboardPropertyList(forType: DragOverlayRoutingPolicy.filePreviewTransferType) as? Data
        )
        let dragID = try XCTUnwrap(FilePreviewDragPasteboardWriter.dragID(from: filePreviewData))
        XCTAssertEqual(dragID, preparedDragID)
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: dragID))

        let bonsplitData = try XCTUnwrap(
            writer.pasteboardPropertyList(forType: FilePreviewDragPasteboardWriter.bonsplitTransferType) as? Data
        )
        XCTAssertEqual(FilePreviewDragPasteboardWriter.dragID(from: bonsplitData), dragID)
        XCTAssertEqual(dragPasteboard.data(forType: DragOverlayRoutingPolicy.filePreviewTransferType), filePreviewData)
        XCTAssertEqual(dragPasteboard.data(forType: FilePreviewDragPasteboardWriter.bonsplitTransferType), filePreviewData)
        XCTAssertEqual(dragPasteboard.string(forType: .fileURL), fileURL.absoluteString)

        FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: dragPasteboard)

        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: dragID))
    }

    func testRegistrySweepsExpiredDragEntries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let oldID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/old.txt", displayTitle: "old.txt"),
            now: start
        )
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: oldID, now: start.addingTimeInterval(30)))

        let newID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/new.txt", displayTitle: "new.txt"),
            now: start.addingTimeInterval(61)
        )

        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: oldID, now: start.addingTimeInterval(61)))
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: newID, now: start.addingTimeInterval(61)))
    }
}


#endif
