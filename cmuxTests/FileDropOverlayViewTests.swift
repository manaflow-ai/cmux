import AppKit
import ObjectiveC.runtime
import SwiftUI
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FileDropOverlayViewTests: XCTestCase {
    private func makeContentViewWindow(windowId: UUID = UUID()) -> NSWindow {
        _ = NSApplication.shared

        let root = ContentView(updateViewModel: UpdateViewModel(), windowId: windowId)
            .environmentObject(TabManager())
            .environmentObject(TerminalNotificationStore.shared)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = MainWindowHostingView(rootView: root)
        return window
    }

    private func fileDropOverlays(in root: NSView?) -> [FileDropOverlayView] {
        guard let root else { return [] }

        var overlays: [FileDropOverlayView] = []
        if let overlay = root as? FileDropOverlayView {
            overlays.append(overlay)
        }
        for subview in root.subviews {
            overlays.append(contentsOf: fileDropOverlays(in: subview))
        }
        return overlays
    }

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
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        nonisolated(unsafe) let draggingSource: Any?
        let draggingSequenceNumber: Int
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(
            window: NSWindow,
            location: NSPoint,
            pasteboard: NSPasteboard,
            sourceOperationMask: NSDragOperation = .copy,
            draggingSource: Any? = nil,
            sequenceNumber: Int = 1
        ) {
            self.draggingDestinationWindow = window
            self.draggingSourceOperationMask = sourceOperationMask
            self.draggingLocation = location
            self.draggedImageLocation = location
            self.draggedImage = nil
            self.draggingPasteboard = pasteboard
            self.draggingSource = draggingSource
            self.draggingSequenceNumber = sequenceNumber
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

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testContentViewInstallsSingleFileDropOverlayAcrossRepeatedLayouts() {
        let window = makeContentViewWindow()
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        realizeWindowLayout(window)
        realizeWindowLayout(window)
        realizeWindowLayout(window)

        guard let themeFrame = window.contentView?.superview else {
            XCTFail("Expected theme frame")
            return
        }

        let overlays = fileDropOverlays(in: themeFrame)
        XCTAssertEqual(
            overlays.count,
            1,
            "ContentView should install exactly one FileDropOverlayView even after repeated layout passes"
        )
        XCTAssertTrue(
            (objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView) === overlays.first,
            "The window-associated file-drop overlay should match the single installed view"
        )
    }

    func testOverlayResolvesPortalHostedBrowserWebViewForFileDrops() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 36, width: 220, height: 150))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        let overlay = FileDropOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)

        let point = anchor.convert(
            NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY),
            to: nil
        )
        XCTAssertTrue(
            overlay.webViewUnderPoint(point) === webView,
            "File-drop overlay should resolve portal-hosted browser panes so Finder uploads still reach WKWebView"
        )
    }

    func testOverlayDelegatesBrowserFileDragLifecycleToPortalHostedWebView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let anchor = NSView(frame: NSRect(x: 52, y: 44, width: 210, height: 140))
        contentView.addSubview(anchor)

        let webView = DragSpyWebView(frame: .zero, configuration: WKWebViewConfiguration())
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        let overlay = FileDropOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/upload.mov") as NSURL]),
            "Expected file URL drag payload"
        )

        let dropPoint = anchor.convert(
            NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY),
            to: nil
        )
        let dragInfo = MockDraggingInfo(
            window: window,
            location: dropPoint,
            pasteboard: pasteboard
        )

        XCTAssertEqual(overlay.draggingEntered(dragInfo), .copy)
        XCTAssertTrue(overlay.prepareForDragOperation(dragInfo))
        XCTAssertTrue(overlay.performDragOperation(dragInfo))
        overlay.concludeDragOperation(dragInfo)

        XCTAssertEqual(
            webView.dragCalls,
            ["entered", "prepare", "perform", "conclude"],
            "Finder file drops over browser panes should still reach the portal-hosted WKWebView"
        )
    }
}
