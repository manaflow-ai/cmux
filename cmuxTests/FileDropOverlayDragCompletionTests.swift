import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FileDropOverlayDragCompletionTests {
    private final class DropWebView: WKWebView {
        var prepareResult = true
        var calls: [String] = []
        var onPerform: (() -> Void)?

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { prepareResult }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            calls.append("perform")
            onPerform?()
            return true
        }
        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { calls.append("conclude") }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { calls.append("exit") }
    }

    private final class DragInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation = .copy
        let draggingLocation: NSPoint
        let draggedImageLocation: NSPoint = .zero
        let draggedImage: NSImage? = nil
        // NSDraggingInfo exposes these nonisolated; this test uses its immutable fixture only on MainActor.
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        nonisolated(unsafe) let draggingSource: Any? = nil
        let draggingSequenceNumber: Int = 12925
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(window: NSWindow, pasteboard: NSPasteboard) {
            draggingDestinationWindow = window
            draggingLocation = NSPoint(x: 100, y: 100)
            draggingPasteboard = pasteboard
        }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
            classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        func resetSpringLoading() {}
    }

    private func withBrowserDrag(
        _ body: (NSWindow, FileDropOverlayView, DropWebView, DragInfo) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 280)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: bounds)
        let webView = DropWebView(frame: bounds, configuration: WKWebViewConfiguration())
        content.addSubview(webView)
        window.contentView = content
        let overlay = FileDropOverlayView(frame: bounds)
        overlay.hitTestReferenceView = content
        try #require(content.superview).addSubview(overlay, positioned: .above, relativeTo: content)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/issue-12925.txt") as NSURL]))
        let drag = DragInfo(window: window, pasteboard: pasteboard)
        #expect(overlay.draggingEntered(drag) == .copy)
        #expect(!overlay.hintBadgeView.isHidden)
        try body(window, overlay, webView, drag)
    }

    @Test
    func nativeDragEndClearsFeedbackEvenWithoutConclude() throws {
        try withBrowserDrag { _, overlay, webView, drag in
            overlay.draggingEnded(drag)
            #expect(overlay.hintBadgeView.isHidden)
            #expect(overlay.activeDragWebView == nil)
            #expect(webView.calls == ["exit"])
            _ = overlay.draggingUpdated(drag)
            #expect(overlay.hintBadgeView.isHidden)
        }
    }

    @Test
    func rejectedPreparationDismissesHintWithoutWaitingForConclude() throws {
        try withBrowserDrag { _, overlay, webView, drag in
            webView.prepareResult = false
            #expect(!overlay.prepareForDragOperation(drag))
            #expect(overlay.hintBadgeView.isHidden)
        }
    }

    @Test
    func popupDuringDropDoesNotCancelBrowserDelivery() throws {
        try withBrowserDrag { window, overlay, webView, drag in
            webView.onPerform = {
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                #expect(overlay.hintBadgeView.isHidden)
            }
            #expect(overlay.prepareForDragOperation(drag))
            #expect(overlay.hintBadgeView.isHidden)
            #expect(overlay.performDragOperation(drag))
            overlay.concludeDragOperation(drag)
            #expect(webView.calls == ["perform", "conclude"])
            #expect(overlay.hintBadgeView.isHidden)
        }
    }
}
