import Testing
import AppKit
import Bonsplit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserPaneFileDropUploadRegressionTests {
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

    @Test func defaultFileDropWithHostedWebViewRoutesToPage() throws {
        try withFileDropDefault(.text) {
            let setup = try makeTarget(hostedWebView: true)
            defer { close(setup.window) }
            let webView = try #require(setup.webView)
            let dragInfo = makeFileDragInfo(window: setup.window, slot: setup.slot)

            #expect(setup.target.draggingEntered(dragInfo) == .copy)
            #expect(setup.target.prepareForDragOperation(dragInfo))
            #expect(setup.target.performDragOperation(dragInfo))
            setup.target.concludeDragOperation(dragInfo)

            #expect(webView.dragCalls == ["entered", "prepare", "perform", "conclude"])
        }
    }

    @Test func fileDropWithUnresolvableWebViewIsNotClaimedAsPreview() throws {
        try withFileDropDefault(.text) {
            let setup = try makeTarget(hostedWebView: false)
            defer { close(setup.window) }
            let dragInfo = makeFileDragInfo(window: setup.window, slot: setup.slot)

            #expect(setup.target.draggingEntered(dragInfo).isEmpty)
            #expect(!setup.target.prepareForDragOperation(dragInfo))
            #expect(!setup.target.performDragOperation(dragInfo))
        }
    }

    @Test func hitTestClaimAndPrepareAgreeWhenWebViewUnavailable() throws {
        try withFileDropDefault(.text) {
            #expect(BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: fileURLPasteboardTypes(),
                eventType: .leftMouseDragged
            ))

            let setup = try makeTarget(hostedWebView: false)
            defer { close(setup.window) }
            let dragInfo = makeFileDragInfo(window: setup.window, slot: setup.slot)

            #expect(!setup.target.prepareForDragOperation(dragInfo))
        }
    }

    @Test func previewDefaultStillRoutesBrowserDropToHostedPage() throws {
        try withFileDropDefault(.preview) {
            let setup = try makeTarget(hostedWebView: true)
            defer { close(setup.window) }
            let webView = try #require(setup.webView)
            let dragInfo = makeFileDragInfo(window: setup.window, slot: setup.slot)

            #expect(BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: fileURLPasteboardTypes(),
                eventType: .leftMouseDragged
            ))
            #expect(setup.target.prepareForDragOperation(dragInfo))
            #expect(setup.target.performDragOperation(dragInfo))
            #expect(webView.dragCalls == ["prepare", "perform"])
        }
    }

    // A live hosted web view does not always fill its slot (a docked Web
    // Inspector splits the slot with WebKit companion views). The registry
    // fallback hit-tests the whole slot container, so without a geometry check
    // a file dropped over the non-page area would be misrouted into the page
    // upload path instead of being refused.
    @Test func fileDropOverNonPageAreaOfLiveWebViewIsRefused() throws {
        try withFileDropDefault(.text) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer { close(window) }
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            let root = try #require(window.contentView)

            let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 260, height: 160))
            root.addSubview(anchor)
            let webView = DragSpyWebView(frame: .zero, configuration: WKWebViewConfiguration())
            defer { BrowserWindowPortalRegistry.detach(webView: webView) }
            BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
            BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
            let context = BrowserPaneDropContext(
                workspaceId: UUID(),
                panelId: UUID(),
                paneId: PaneID(id: UUID())
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: context)
            root.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            root.layoutSubtreeIfNeeded()

            let container = try #require(webView.superview as? WindowBrowserSlotView)

            // Emulate a docked-inspector split: the live web view keeps only one
            // half of the slot, the companion view owns the other half.
            webView.autoresizingMask = []
            webView.frame = NSRect(
                x: 0,
                y: 0,
                width: container.bounds.width,
                height: container.bounds.height / 2
            )
            let pagePoint = NSPoint(x: container.bounds.midX, y: container.bounds.height * 0.25)
            let nonPagePoint = NSPoint(x: container.bounds.midX, y: container.bounds.height * 0.75)

            // Harness sanity: the precise hosted-webview hit test resolves the
            // page area and misses the companion area, while the registry still
            // resolves the whole container.
            #expect(container.hostedWebViewForFileDrop(at: pagePoint) === webView)
            #expect(container.hostedWebViewForFileDrop(at: nonPagePoint) == nil)
            let nonPageWindowPoint = container.convert(nonPagePoint, to: nil)
            #expect(
                BrowserWindowPortalRegistry.webViewAtWindowPoint(nonPageWindowPoint, in: window) === webView
            )

            let target = try #require(
                BrowserWindowPortalRegistry.browserPaneDropTargetAtWindowPoint(nonPageWindowPoint, in: window)
            )
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-7632.split.\(UUID().uuidString)"))
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/upload.png") as NSURL]))
            let dragInfo = MockDraggingInfo(window: window, location: nonPageWindowPoint, pasteboard: pasteboard)

            #expect(target.draggingEntered(dragInfo).isEmpty)
            #expect(!target.prepareForDragOperation(dragInfo))
            #expect(!target.performDragOperation(dragInfo))
            #expect(webView.dragCalls == [])
        }
    }

    @Test func shiftInvertedFileDropStillRoutesToPreview() {
        #expect(
            DragOverlayRoutingPolicy.resolvedFileDropBehavior(
                pasteboardTypes: fileURLPasteboardTypes(),
                modifierFlags: [.shift],
                canDropAsText: true,
                defaultBehavior: .text
            ) == .preview
        )
    }

    @Test func dispositionDefaultsToPageUploadRegardlessOfWebViewAvailability() {
        withFileDropDefault(.text) {
            #expect(
                BrowserPaneFileDropRouting.disposition(
                    pasteboardTypes: fileURLPasteboardTypes(),
                    modifierFlags: [],
                    isDockHosted: false
                ) == .forwardToPage
            )
        }
        withFileDropDefault(.preview) {
            #expect(
                BrowserPaneFileDropRouting.disposition(
                    pasteboardTypes: fileURLPasteboardTypes(),
                    modifierFlags: [],
                    isDockHosted: false
                ) == .forwardToPage
            )
        }
    }

    @Test func dispositionShiftAlwaysRoutesToPreview() {
        withFileDropDefault(.text) {
            #expect(
                BrowserPaneFileDropRouting.disposition(
                    pasteboardTypes: fileURLPasteboardTypes(),
                    modifierFlags: [.shift],
                    isDockHosted: false
                ) == .previewInWorkspace
            )
        }
        withFileDropDefault(.preview) {
            #expect(
                BrowserPaneFileDropRouting.disposition(
                    pasteboardTypes: fileURLPasteboardTypes(),
                    modifierFlags: [.shift],
                    isDockHosted: false
                ) == .previewInWorkspace
            )
        }
    }

    @Test func dispositionDockAlwaysForwardsToPage() {
        #expect(
            BrowserPaneFileDropRouting.disposition(
                pasteboardTypes: fileURLPasteboardTypes(),
                modifierFlags: [],
                isDockHosted: true
            ) == .forwardToPage
        )
        #expect(
            BrowserPaneFileDropRouting.disposition(
                pasteboardTypes: fileURLPasteboardTypes(),
                modifierFlags: [.shift],
                isDockHosted: true
            ) == .forwardToPage
        )
    }

    @Test func dispositionRequiresFileURLPayload() {
        #expect(BrowserPaneFileDropRouting.disposition(
            pasteboardTypes: [DragOverlayRoutingPolicy.filePreviewTransferType],
            modifierFlags: [],
            isDockHosted: false
        ) == nil)
        #expect(BrowserPaneFileDropRouting.disposition(
            pasteboardTypes: nil,
            modifierFlags: [],
            isDockHosted: false
        ) == nil)
    }

    // The dock-status lookup is an app-wide ownership sweep; disposition must not
    // evaluate it unless a file-URL payload is present. Drag callbacks fire for
    // every payload type, so an eager lookup would run on every non-file drag.
    @Test func dispositionDoesNotEvaluateDockStatusWithoutFileURL() {
        var dockStatusEvaluations = 0
        func countingDockStatus() -> Bool {
            dockStatusEvaluations += 1
            return true
        }

        #expect(BrowserPaneFileDropRouting.disposition(
            pasteboardTypes: nil,
            modifierFlags: [],
            isDockHosted: countingDockStatus()
        ) == nil)
        #expect(dockStatusEvaluations == 0)

        #expect(
            BrowserPaneFileDropRouting.disposition(
                pasteboardTypes: fileURLPasteboardTypes(),
                modifierFlags: [],
                isDockHosted: countingDockStatus()
            ) == .forwardToPage
        )
        #expect(dockStatusEvaluations == 1)
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

        let target = try #require(slot.paneDropTargetForDrop(at: NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)))
        return (window, slot, target, webView)
    }

    private func makeFileDragInfo(window: NSWindow, slot: WindowBrowserSlotView) -> MockDraggingInfo {
        let pasteboard = makeFilePasteboard(paths: ["/tmp/upload.png"])
        let dropPoint = slot.convert(NSPoint(x: slot.bounds.midX, y: slot.bounds.midY), to: nil)
        return MockDraggingInfo(window: window, location: dropPoint, pasteboard: pasteboard)
    }

    private func makeFilePasteboard(paths: [String]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-7632.file.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL }))
        return pasteboard
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
