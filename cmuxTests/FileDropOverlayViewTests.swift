import AppKit
import ObjectiveC.runtime
import SwiftUI
import Testing
import WebKit
import CmuxUpdater

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FileDropOverlayViewTests {
    private func makeContentViewWindow(windowId: UUID = UUID()) -> NSWindow {
        _ = NSApplication.shared

        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: windowId)
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
        var performResult = true

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
            return performResult
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            dragCalls.append("conclude")
        }
    }

    private final class MouseEventSpyView: NSView {
        var mouseCalls: [String] = []

        override func mouseDown(with event: NSEvent) {
            mouseCalls.append("down")
        }

        override func mouseDragged(with event: NSEvent) {
            mouseCalls.append("dragged")
        }

        override func mouseUp(with event: NSEvent) {
            mouseCalls.append("up")
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

    @Test
    func contentViewInstallsSingleFileDropOverlayAcrossRepeatedLayouts() throws {
        let window = makeContentViewWindow()
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        realizeWindowLayout(window)
        realizeWindowLayout(window)
        realizeWindowLayout(window)

        let themeFrame = try #require(window.contentView?.superview)

        let overlays = fileDropOverlays(in: themeFrame)
        #expect(
            overlays.count == 1,
            "ContentView should install exactly one FileDropOverlayView even after repeated layout passes"
        )
        #expect(
            (objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView) === overlays.first,
            "The window-associated file-drop overlay should match the single installed view"
        )
    }

    @Test
    func overlayResolvesPortalHostedBrowserWebViewForFileDrops() throws {
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

        let contentView = try #require(window.contentView)
        let container = try #require(contentView.superview)

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
        #expect(
            overlay.webViewUnderPoint(point) === webView,
            "File-drop overlay should resolve portal-hosted browser panes so Finder uploads still reach WKWebView"
        )
    }

    @Test
    func overlayDelegatesBrowserFileDragLifecycleToPortalHostedWebView() throws {
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

        let contentView = try #require(window.contentView)
        let container = try #require(contentView.superview)

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
        #expect(
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

        #expect(overlay.draggingEntered(dragInfo) == .copy)
        #expect(overlay.prepareForDragOperation(dragInfo))
        #expect(overlay.performDragOperation(dragInfo))
        overlay.concludeDragOperation(dragInfo)

        #expect(
            webView.dragCalls == ["entered", "prepare", "perform", "conclude"],
            "Finder file drops over browser panes should still reach the portal-hosted WKWebView"
        )
    }

    @Test
    func overlayDoesNotRecordTextDragWhenWebViewRejectsDrop() throws {
        let defaults = UserDefaults.standard
        let savedDefaultBehavior = defaults.object(forKey: FileDropBehaviorSettings.defaultBehaviorKey)
        defaults.set(FileDropDefaultBehavior.text.rawValue, forKey: FileDropBehaviorSettings.defaultBehaviorKey)
        defer {
            if let savedDefaultBehavior {
                defaults.set(savedDefaultBehavior, forKey: FileDropBehaviorSettings.defaultBehaviorKey)
            } else {
                defaults.removeObject(forKey: FileDropBehaviorSettings.defaultBehaviorKey)
            }
        }

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

        let contentView = try #require(window.contentView)
        let container = try #require(contentView.superview)

        let anchor = NSView(frame: NSRect(x: 52, y: 44, width: 210, height: 140))
        contentView.addSubview(anchor)

        let webView = DragSpyWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.performResult = false
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        let overlay = FileDropOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/rejected-upload.mov") as NSURL]),
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

        #expect(overlay.draggingEntered(dragInfo) == .copy)
        #expect(overlay.prepareForDragOperation(dragInfo))
        #expect(!overlay.performDragOperation(dragInfo))
        #expect(!overlay.didPerformDragAsText)
        #expect(overlay.performedTextDragWebView == nil)

        overlay.concludeDragOperation(dragInfo)
        #expect(
            webView.dragCalls == ["entered", "prepare", "perform"],
            "Rejected text drops should not be recorded as performed or receive a text-route conclude"
        )
    }

    @Test("Forwarded mouse-up stays with the original drag target")
    func forwardedMouseUpUsesOriginalTargetAfterPhysicalRelease() throws {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        window.contentView = contentView
        let originalTarget = MouseEventSpyView(frame: NSRect(x: 0, y: 0, width: 210, height: 240))
        let underCursorTarget = MouseEventSpyView(frame: NSRect(x: 210, y: 0, width: 210, height: 240))
        contentView.addSubview(originalTarget)
        contentView.addSubview(underCursorTarget)
        let overlay = FileDropOverlayView(frame: contentView.bounds)
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()

        let downLocation = originalTarget.convert(
            NSPoint(x: originalTarget.bounds.midX, y: originalTarget.bounds.midY),
            to: nil
        )
        let upLocation = underCursorTarget.convert(
            NSPoint(x: underCursorTarget.bounds.midX, y: underCursorTarget.bounds.midY),
            to: nil
        )
        let down = try #require(Self.mouseEvent(type: .leftMouseDown, location: downLocation, window: window))
        let up = try #require(Self.mouseEvent(type: .leftMouseUp, location: upLocation, window: window))

        overlay.mouseDown(with: down)
        overlay.mouseUp(with: up)

        #expect(
            originalTarget.mouseCalls == ["down", "up"],
            "AppKit's post-release button mask must not redirect mouse-up away from the original target"
        )
        #expect(underCursorTarget.mouseCalls.isEmpty)
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }
}
