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
final class BrowserPaneDropRoutingTests: XCTestCase {
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

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            dragCalls.append("exited")
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
        XCTAssertTrue(
            BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .cursorUpdate
            )
        )

        let externalPayloads: [[NSPasteboard.PasteboardType]] = [
            [.URL],
            [.png],
            [.tiff],
            [.html],
            [.string],
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

        XCTAssertTrue(
            BrowserPaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [.fileURL, .png],
                eventType: .cursorUpdate
            )
        )
    }

    func testPaneDropTargetRequiresDropContext() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        slot.layout()
        let localPoint = NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)

        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID(id: UUID())
        ))
        XCTAssertNotNil(slot.paneDropTargetForDrop(at: localPoint))

        slot.setPaneDropContext(nil)
        XCTAssertNil(slot.paneDropTargetForDrop(at: localPoint))
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
            sourcePaneId: paneId.id
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
            sourcePaneId: UUID()
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

    func testDecodeLiveCapabilityReadsTabAndSourcePane() throws {
        let tabId = UUID()
        let sourcePaneId = UUID()
        let context = try makeBonsplitPanePayloadPasteboard(
            tabId: tabId,
            sourcePaneId: sourcePaneId,
            kind: "filePreview",
            includesFilePreviewTransferType: false
        )
        defer { TabDragTransferRegistry.process.end(context.registration) }

        let transfer = BrowserPaneDragTransfer.decode(from: context.pasteboard)

        XCTAssertEqual(transfer?.tabId, tabId)
        XCTAssertEqual(transfer?.sourcePaneId, sourcePaneId)
        XCTAssertEqual(transfer?.kind, "filePreview")
        XCTAssertTrue(transfer?.isFilePreview == false)
    }

    func testDecodePasteboardUsesDedicatedFilePreviewTransferType() throws {
        let realTabContext = try makeBonsplitPanePayloadPasteboard(
            kind: "filePreview",
            includesFilePreviewTransferType: false
        )
        defer { TabDragTransferRegistry.process.end(realTabContext.registration) }
        let realTabTransfer = try XCTUnwrap(
            BrowserPaneDragTransfer.decode(from: realTabContext.pasteboard)
        )
        XCTAssertFalse(realTabTransfer.isFilePreview)
        XCTAssertEqual(realTabTransfer.kind, "filePreview")

        let syntheticContext = try makeBonsplitPanePayloadPasteboard(
            kind: "filePreview",
            includesFilePreviewTransferType: true
        )
        defer { TabDragTransferRegistry.process.end(syntheticContext.registration) }
        let syntheticTransfer = try XCTUnwrap(
            BrowserPaneDragTransfer.decode(from: syntheticContext.pasteboard)
        )
        XCTAssertTrue(syntheticTransfer.isFilePreview)
    }

    func testBrowserPaneFileDropDefaultUsesHostedWebViewLifecycle() throws {
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let root = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 360, height: 240))
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let slot = WindowBrowserSlotView(frame: NSRect(x: 20, y: 20, width: 260, height: 160))
        root.addSubview(slot)
        let webView = DragSpyWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID(id: UUID())
        ))
        slot.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(slot.paneDropTargetForDrop(at: NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.browser-pane.file-drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/upload.png") as NSURL]))

        let dropPoint = slot.convert(NSPoint(x: slot.bounds.midX, y: slot.bounds.midY), to: nil)
        let dragInfo = MockDraggingInfo(window: window, location: dropPoint, pasteboard: pasteboard)

        XCTAssertEqual(target.draggingEntered(dragInfo), .copy)
        XCTAssertTrue(target.prepareForDragOperation(dragInfo))
        XCTAssertTrue(target.performDragOperation(dragInfo))
        target.concludeDragOperation(dragInfo)

        XCTAssertEqual(webView.dragCalls, ["entered", "prepare", "perform", "conclude"])
    }

    func testBrowserPaneFilePreviewOnlyDragUsesPaneDropPathInsteadOfHostedWebView() throws {
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let root = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 360, height: 240))
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let slot = WindowBrowserSlotView(frame: NSRect(x: 20, y: 20, width: 260, height: 160))
        root.addSubview(slot)
        let webView = DragSpyWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID(id: UUID())
        ))
        slot.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(slot.paneDropTargetForDrop(at: NSPoint(x: slot.bounds.midX, y: slot.bounds.midY)))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.browser-pane.file-preview-drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let dragId = UUID()
        _ = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/from-image-pane.png", displayTitle: "from-image-pane.png"),
            id: dragId
        )
        defer { FilePreviewDragRegistry.shared.discard(id: dragId) }
        let payload = try JSONSerialization.data(withJSONObject: [
            "tab": ["id": dragId.uuidString, "kind": "filePreview"],
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier),
        ])
        let registration = try XCTUnwrap(
            TabDragTransferRegistry.process.register(
                TabDragTransfer(
                    tab: Tab(
                        id: TabID(uuid: dragId),
                        title: "from-image-pane.png",
                        kind: "filePreview"
                    ),
                    sourcePaneId: PaneID()
                )
            )
        )
        defer { TabDragTransferRegistry.process.end(registration) }
        pasteboard.setData(payload, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
        XCTAssertTrue(registration.write(to: pasteboard))

        XCTAssertFalse(DragOverlayRoutingPolicy.hasFileURL(pasteboard.types))

        let dropPoint = slot.convert(NSPoint(x: slot.bounds.midX, y: slot.bounds.midY), to: nil)
        let dragInfo = MockDraggingInfo(window: window, location: dropPoint, pasteboard: pasteboard)

        XCTAssertEqual(target.draggingEntered(dragInfo), .move)
        XCTAssertTrue(target.prepareForDragOperation(dragInfo))
        XCTAssertEqual(webView.dragCalls, [])
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
        tabId: UUID = UUID(),
        sourcePaneId: UUID = UUID(),
        kind: String?,
        includesFilePreviewTransferType: Bool
    ) throws -> (pasteboard: NSPasteboard, registration: TabDragTransferRegistration) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.browser-pane.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let registration = try XCTUnwrap(
            TabDragTransferRegistry.process.register(
                TabDragTransfer(
                    tab: Tab(
                        id: TabID(uuid: tabId),
                        title: "Test tab",
                        kind: kind
                    ),
                    sourcePaneId: PaneID(id: sourcePaneId)
                )
            )
        )
        XCTAssertTrue(registration.write(to: pasteboard))
        if includesFilePreviewTransferType {
            pasteboard.setString(
                "file-preview",
                forType: DragOverlayRoutingPolicy.filePreviewTransferType
            )
        }
        return (pasteboard, registration)
    }
}
