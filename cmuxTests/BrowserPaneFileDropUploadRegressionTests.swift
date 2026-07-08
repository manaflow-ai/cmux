import XCTest
import AppKit
import Bonsplit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserPaneFileDropUploadRegressionTests: XCTestCase {
    private final class DragSpyWebView: WKWebView {
        var dragCalls: [String] = []

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            dragCalls.append("entered")
            return .copy
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            dragCalls.append("prepare")
            return true
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            dragCalls.append("perform")
            return true
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            dragCalls.append("conclude")
        }
    }

    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation
        let draggingLocation: NSPoint
        let draggedImageLocation: NSPoint
        let draggedImage: NSImage?
        // NSDraggingInfo exposes the pasteboard nonisolated; tests mutate it only before construction.
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        // AppKit exposes the dragging source as an untyped object and this test never mutates it.
        nonisolated(unsafe) let draggingSource: Any?
        let draggingSequenceNumber: Int
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            self.draggingDestinationWindow = window
            self.draggingSourceOperationMask = .copy
            self.draggingLocation = location
            self.draggedImageLocation = location
            self.draggedImage = nil
            self.draggingPasteboard = pasteboard
            self.draggingSource = nil
            self.draggingSequenceNumber = 1
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}

        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
            nil
        }

        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}

        func resetSpringLoading() {}
    }

    func testDefaultFileDropWithHostedWebViewRoutesToPage() throws {
        try withFileDropDefault(.text) {
            let setup = try makeTarget(hostedWebView: true)
            defer { close(setup.window) }
            let webView = try XCTUnwrap(setup.webView)
            let dragInfo = makeFileDragInfo(window: setup.window, slot: setup.slot)

            XCTAssertEqual(setup.target.draggingEntered(dragInfo), .copy)
            XCTAssertTrue(setup.target.prepareForDragOperation(dragInfo))
            XCTAssertTrue(setup.target.performDragOperation(dragInfo))
            setup.target.concludeDragOperation(dragInfo)

            XCTAssertEqual(webView.dragCalls, ["entered", "prepare", "perform", "conclude"])
        }
    }

    func testFileDropWithUnresolvableWebViewIsNotClaimedAsPreview() throws {
        try withFileDropDefault(.text) {
            let setup = try makeTarget(hostedWebView: false)
            defer { close(setup.window) }
            let dragInfo = makeFileDragInfo(window: setup.window, slot: setup.slot)

            XCTAssertTrue(setup.target.draggingEntered(dragInfo).isEmpty)
            XCTAssertFalse(setup.target.prepareForDragOperation(dragInfo))
            XCTAssertFalse(setup.target.performDragOperation(dragInfo))
        }
    }

    func testHitTestClaimAndPrepareAgreeWhenWebViewUnavailable() throws {
        try withFileDropDefault(.text) {
            XCTAssertTrue(BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: fileURLPasteboardTypes(),
                eventType: .leftMouseDragged
            ))

            let setup = try makeTarget(hostedWebView: false)
            defer { close(setup.window) }
            let dragInfo = makeFileDragInfo(window: setup.window, slot: setup.slot)

            XCTAssertFalse(setup.target.prepareForDragOperation(dragInfo))
        }
    }

    func testShiftInvertedFileDropStillRoutesToPreview() {
        XCTAssertEqual(
            DragOverlayRoutingPolicy.resolvedFileDropBehavior(
                pasteboardTypes: fileURLPasteboardTypes(),
                modifierFlags: [.shift],
                canDropAsText: true,
                defaultBehavior: .text
            ),
            .preview
        )
    }

    private func withFileDropDefault(_ behavior: FileDropDefaultBehavior, run: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let savedDefaultBehavior = defaults.object(forKey: FileDropBehaviorSettings.defaultBehaviorKey)
        defaults.set(behavior.rawValue, forKey: FileDropBehaviorSettings.defaultBehaviorKey)
        defer {
            if let savedDefaultBehavior {
                defaults.set(savedDefaultBehavior, forKey: FileDropBehaviorSettings.defaultBehaviorKey)
            } else {
                defaults.removeObject(forKey: FileDropBehaviorSettings.defaultBehaviorKey)
            }
        }
        try run()
    }

    private func makeTarget(hostedWebView: Bool) throws -> (
        window: NSWindow,
        slot: WindowBrowserSlotView,
        target: BrowserPaneDropTargetView,
        webView: DragSpyWebView?
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 360, height: 240))
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let slot = WindowBrowserSlotView(frame: NSRect(x: 20, y: 20, width: 260, height: 160))
        root.addSubview(slot)
        let webView: DragSpyWebView?
        if hostedWebView {
            let hosted = DragSpyWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
            slot.addSubview(hosted)
            slot.pinHostedWebView(hosted)
            webView = hosted
        } else {
            webView = nil
        }
        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID(id: UUID())
        ))
        slot.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(slot.paneDropTargetForDrop(at: NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)))
        return (window, slot, target, webView)
    }

    private func makeFileDragInfo(window: NSWindow, slot: WindowBrowserSlotView) -> MockDraggingInfo {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-7632.file.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/upload.png") as NSURL]))
        let dropPoint = slot.convert(NSPoint(x: slot.bounds.midX, y: slot.bounds.midY), to: nil)
        return MockDraggingInfo(window: window, location: dropPoint, pasteboard: pasteboard)
    }

    private func fileURLPasteboardTypes() -> [NSPasteboard.PasteboardType] {
        if PasteboardFileURLReader.fileURLPasteboardTypes.contains(.fileURL) {
            return [.fileURL]
        }
        return Array(PasteboardFileURLReader.fileURLPasteboardTypes.prefix(1))
    }

    private func close(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.orderOut(nil)
    }
}
