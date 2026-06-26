import XCTest
import AppKit
import CmuxBrowser
import WebKit
import ObjectiveC.runtime

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private var cmuxUnitTestWKWebViewDragLifecycleOverrideInstalled = false
private var cmuxUnitTestWKWebViewDragLifecycleEvents: [String]?

extension WKWebView {
    @objc func cmuxUnitTest_draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if cmuxUnitTestWKWebViewDragLifecycleEvents != nil {
            cmuxUnitTestWKWebViewDragLifecycleEvents?.append("entered")
            return .copy
        }
        return cmuxUnitTest_draggingEntered(sender)
    }

    @objc func cmuxUnitTest_draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if cmuxUnitTestWKWebViewDragLifecycleEvents != nil {
            cmuxUnitTestWKWebViewDragLifecycleEvents?.append("updated")
            return .copy
        }
        return cmuxUnitTest_draggingUpdated(sender)
    }

    @objc func cmuxUnitTest_prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if cmuxUnitTestWKWebViewDragLifecycleEvents != nil {
            cmuxUnitTestWKWebViewDragLifecycleEvents?.append("prepare")
            return true
        }
        return cmuxUnitTest_prepareForDragOperation(sender)
    }

    @objc func cmuxUnitTest_performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if cmuxUnitTestWKWebViewDragLifecycleEvents != nil {
            cmuxUnitTestWKWebViewDragLifecycleEvents?.append("perform")
            return true
        }
        return cmuxUnitTest_performDragOperation(sender)
    }

    @objc func cmuxUnitTest_concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if cmuxUnitTestWKWebViewDragLifecycleEvents != nil {
            cmuxUnitTestWKWebViewDragLifecycleEvents?.append("conclude")
            return
        }
        cmuxUnitTest_concludeDragOperation(sender)
    }
}

private func installCmuxUnitTestWKWebViewDragLifecycleOverride() {
    guard !cmuxUnitTestWKWebViewDragLifecycleOverrideInstalled else { return }

    func swizzle(_ originalSelector: Selector, _ swizzledSelector: Selector) {
        guard let originalMethod = class_getInstanceMethod(WKWebView.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(WKWebView.self, swizzledSelector) else {
            fatalError("Unable to locate WKWebView drag lifecycle methods for swizzling")
        }

        let didAddMethod = class_addMethod(
            WKWebView.self,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod {
            class_replaceMethod(
                WKWebView.self,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    swizzle(
        #selector(NSView.draggingEntered(_:)),
        #selector(WKWebView.cmuxUnitTest_draggingEntered(_:))
    )
    swizzle(
        #selector(NSView.draggingUpdated(_:)),
        #selector(WKWebView.cmuxUnitTest_draggingUpdated(_:))
    )
    swizzle(
        #selector(NSView.prepareForDragOperation(_:)),
        #selector(WKWebView.cmuxUnitTest_prepareForDragOperation(_:))
    )
    swizzle(
        #selector(NSView.performDragOperation(_:)),
        #selector(WKWebView.cmuxUnitTest_performDragOperation(_:))
    )
    swizzle(
        #selector(NSView.concludeDragOperation(_:)),
        #selector(WKWebView.cmuxUnitTest_concludeDragOperation(_:))
    )

    cmuxUnitTestWKWebViewDragLifecycleOverrideInstalled = true
}

private final class MockDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation = NSPoint(x: 10, y: 10)
    let draggedImageLocation = NSPoint(x: 10, y: 10)
    let draggedImage: NSImage? = nil
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard, window: NSWindow? = nil) {
        self.draggingPasteboard = pasteboard
        self.draggingDestinationWindow = window
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

@MainActor
final class CmuxWebViewDragRoutingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        installCmuxUnitTestWKWebViewDragLifecycleOverride()
        cmuxUnitTestWKWebViewDragLifecycleEvents = nil
    }

    override func tearDown() {
        cmuxUnitTestWKWebViewDragLifecycleEvents = nil
        super.tearDown()
    }

    func testRejectsInternalPaneDragEvenWhenFilePromiseTypesArePresent() {
        XCTAssertTrue(
            CmuxWebView.shouldRejectInternalPaneDrag([
                DragOverlayRoutingPolicy.bonsplitTabTransferType,
                NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            ])
        )
    }

    func testAllowsRegularExternalFileImageAndURLDrops() {
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
                CmuxWebView.shouldRejectInternalPaneDrag(pasteboardTypes),
                "Browser web view should not reject external drag payload: \(pasteboardTypes)"
            )
        }
    }

    func testRegisterForDraggedTypesKeepsExternalFileImageAndURLTypes() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let externalTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .URL,
            .png,
            .tiff,
            .html,
        ]

        webView.registerForDraggedTypes([
            .string,
            DragOverlayRoutingPolicy.bonsplitTabTransferType,
            DragOverlayRoutingPolicy.sidebarTabReorderType,
        ] + externalTypes)

        let registeredTypes = Set(webView.registeredDraggedTypes)
        for pasteboardType in externalTypes {
            XCTAssertTrue(
                registeredTypes.contains(pasteboardType),
                "Browser web view should keep external drag type registered: \(pasteboardType)"
            )
        }
        XCTAssertFalse(registeredTypes.contains(DragOverlayRoutingPolicy.bonsplitTabTransferType))
        XCTAssertFalse(registeredTypes.contains(DragOverlayRoutingPolicy.sidebarTabReorderType))
        XCTAssertFalse(registeredTypes.contains(.string))
    }

    func testWebsiteDragPayloadReachesWebKitDragLifecycle() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.web-drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("file:///tmp/site-drop.png", forType: .fileURL)
        pasteboard.setString("https://example.com/site-drop.png", forType: .URL)
        pasteboard.setString("<img src=\"https://example.com/site-drop.png\">", forType: .html)
        pasteboard.setData(Data("png".utf8), forType: .png)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let dragInfo = MockDraggingInfo(pasteboard: pasteboard)

        cmuxUnitTestWKWebViewDragLifecycleEvents = []
        XCTAssertEqual(webView.draggingEntered(dragInfo), .copy)
        XCTAssertEqual(webView.draggingUpdated(dragInfo), .copy)
        XCTAssertTrue(webView.prepareForDragOperation(dragInfo))
        XCTAssertTrue(webView.performDragOperation(dragInfo))
        webView.concludeDragOperation(dragInfo)

        XCTAssertEqual(
            cmuxUnitTestWKWebViewDragLifecycleEvents,
            ["entered", "updated", "prepare", "perform", "conclude"]
        )
    }

    func testInternalPaneDragDoesNotReachWebKitDragLifecycle() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.internal-drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("tab-transfer", forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
        pasteboard.setString("tab-title", forType: .string)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let dragInfo = MockDraggingInfo(pasteboard: pasteboard)

        cmuxUnitTestWKWebViewDragLifecycleEvents = []
        XCTAssertEqual(webView.draggingEntered(dragInfo), [])
        XCTAssertEqual(webView.draggingUpdated(dragInfo), [])
        XCTAssertFalse(webView.prepareForDragOperation(dragInfo))
        XCTAssertFalse(webView.performDragOperation(dragInfo))
        webView.concludeDragOperation(dragInfo)

        XCTAssertEqual(cmuxUnitTestWKWebViewDragLifecycleEvents, [])
    }
}

@MainActor
final class BrowserScreenshotPipelineTests: XCTestCase {
    private func makeTestImage(width: Int, height: Int) throws -> NSImage {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )

        for y in 0..<height {
            for x in 0..<width {
                rep.setColor(
                    NSColor(
                        calibratedRed: CGFloat(x) / CGFloat(max(width - 1, 1)),
                        green: CGFloat(y) / CGFloat(max(height - 1, 1)),
                        blue: 0.5,
                        alpha: 1.0
                    ),
                    atX: x,
                    y: y
                )
            }
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    func testFullPageSnapshotWritesPNGAndTIFFToPasteboard() async throws {
        let pasteboard = NSPasteboard(name: .init("cmux-browser-screenshot-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = try makeTestImage(width: 8, height: 6)
        let result = try await BrowserScreenshotPipeline.captureAndWrite(
            mode: .fullPage,
            snapshot: { image },
            pasteboard: pasteboard
        )

        XCTAssertEqual(result.outputSize.width, 8)
        XCTAssertEqual(result.outputSize.height, 6)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testScreenshotPasteboardWriterClearsExistingContentsBeforeWriting() async throws {
        let pasteboard = NSPasteboard(name: .init("cmux-browser-screenshot-existing-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard text", forType: .string)

        let image = try makeTestImage(width: 8, height: 6)
        _ = try await BrowserScreenshotPipeline.captureAndWrite(
            mode: .fullPage,
            snapshot: { image },
            pasteboard: pasteboard
        )

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testScreenshotCaptureGateRejectsNestedCaptureUntilCurrentFinishes() async throws {
        let gate = BrowserScreenshotCaptureGate()
        var nestedCaptureRan = false

        let outerResult = try await gate.run {
            let nestedResult = try await gate.run {
                nestedCaptureRan = true
                return "nested"
            }
            XCTAssertNil(nestedResult)
            return "outer"
        }

        XCTAssertEqual(outerResult, "outer")
        XCTAssertFalse(nestedCaptureRan)

        let nextResult = try await gate.run {
            "next"
        }
        XCTAssertEqual(nextResult, "next")
    }

    func testSectionCropMapsViewSelectionIntoSnapshotImageCoordinates() throws {
        let cropRect = try BrowserScreenshotCrop.imageRect(
            forSelectionInView: NSRect(x: 50, y: 25, width: 100, height: 50),
            viewBounds: NSRect(x: 0, y: 0, width: 200, height: 150),
            imageSize: NSSize(width: 400, height: 300)
        )

        XCTAssertEqual(cropRect.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(cropRect.origin.y, 50, accuracy: 0.001)
        XCTAssertEqual(cropRect.width, 200, accuracy: 0.001)
        XCTAssertEqual(cropRect.height, 100, accuracy: 0.001)
    }

    func testSectionCropSubtractsNonZeroViewBoundsOrigin() throws {
        let cropRect = try BrowserScreenshotCrop.imageRect(
            forSelectionInView: NSRect(x: 150, y: 75, width: 50, height: 25),
            viewBounds: NSRect(x: 100, y: 50, width: 200, height: 100),
            imageSize: NSSize(width: 400, height: 200)
        )

        XCTAssertEqual(cropRect.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(cropRect.origin.y, 50, accuracy: 0.001)
        XCTAssertEqual(cropRect.width, 100, accuracy: 0.001)
        XCTAssertEqual(cropRect.height, 50, accuracy: 0.001)
    }

    func testSectionSnapshotCropsSelectionBeforeWritingPasteboard() async throws {
        let pasteboard = NSPasteboard(name: .init("cmux-browser-screenshot-section-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let source = try makeTestImage(width: 400, height: 300)
        let result = try await BrowserScreenshotPipeline.captureAndWrite(
            mode: .section(
                selectionInView: NSRect(x: 50, y: 25, width: 100, height: 50),
                viewBounds: NSRect(x: 0, y: 0, width: 200, height: 150)
            ),
            snapshot: { source },
            pasteboard: pasteboard
        )

        XCTAssertEqual(result.outputSize.width, 200)
        XCTAssertEqual(result.outputSize.height, 100)

        let pngData = try XCTUnwrap(pasteboard.data(forType: .png))
        let croppedImage = try XCTUnwrap(NSImage(data: pngData))
        XCTAssertEqual(croppedImage.size.width, 200)
        XCTAssertEqual(croppedImage.size.height, 100)
    }

    func testTilePlacementUsesTopOfOversizedTileWhenClampingSourceRect() throws {
        let rects = try XCTUnwrap(
            BrowserScreenshotTilePlacement(
                contentSize: NSSize(width: 100, height: 300),
                viewportSize: NSSize(width: 100, height: 100)
            ).drawRects(
                tileSize: NSSize(width: 100, height: 160),
                origin: NSPoint(x: 0, y: 100)
            )
        )

        XCTAssertEqual(rects.source.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rects.source.origin.y, 60, accuracy: 0.001)
        XCTAssertEqual(rects.source.width, 100, accuracy: 0.001)
        XCTAssertEqual(rects.source.height, 100, accuracy: 0.001)
        XCTAssertEqual(rects.destination.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rects.destination.origin.y, 100, accuracy: 0.001)
        XCTAssertEqual(rects.destination.width, 100, accuracy: 0.001)
        XCTAssertEqual(rects.destination.height, 100, accuracy: 0.001)
    }

    func testFullPageCaptureBoundsRejectsHugePageBeforeBitmapAllocation() throws {
        XCTAssertNoThrow(
            try BrowserScreenshotCaptureBounds.validateFullPageSize(
                NSSize(width: 10_000, height: 10_000)
            )
        )

        XCTAssertThrowsError(
            try BrowserScreenshotCaptureBounds.validateFullPageSize(
                NSSize(width: 10_001, height: 10_000)
            )
        ) { error in
            guard case BrowserScreenshotError.captureAreaTooLarge = error else {
                XCTFail("Expected captureAreaTooLarge, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(
            try BrowserScreenshotCaptureBounds.validateFullPageSize(
                NSSize(width: 10_000, height: 10_001)
            )
        ) { error in
            guard case BrowserScreenshotError.captureAreaTooLarge = error else {
                XCTFail("Expected captureAreaTooLarge, got \(error)")
                return
            }
        }
    }
}
