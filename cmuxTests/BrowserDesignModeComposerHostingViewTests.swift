import AppKit
import CmuxBrowser
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the Design Mode composer overlay hit testing.
///
/// The composer is hosted as a full-slot overlay above the portal-hosted
/// WKWebView. A plain `NSHostingView` claims every point in `hitTest`, so an
/// unscoped overlay swallows clicks, scrolls, and element-picker interactions
/// meant for the page — even while the composer card is dismissed. The overlay
/// must route events only within the visible composer card and pass everything
/// else through to the web content below.
@MainActor
@Suite(.serialized)
struct BrowserDesignModeComposerHostingViewTests {
    private func makeController() -> BrowserDesignModeController {
        BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: BrowserDesignModeArtifactStore(directory: URL.temporaryDirectory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(),
            canEnable: { true },
            clipboardWriter: { _ in true },
            onActivityChanged: {}
        )
    }

    @Test func dismissedComposerOverlayPassesClicksThroughToThePage() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        slot.setDesignComposer(
            BrowserPortalDesignComposerConfiguration(
                panelId: UUID(),
                controller: makeController()
            )
        )
        slot.layoutSubtreeIfNeeded()

        let hit = slot.hitTest(NSPoint(x: 320, y: 240))

        #expect(
            !(hit is NSHostingView<BrowserDesignModePopoverHost>),
            "The dismissed composer overlay must not intercept events meant for the web view"
        )
    }

    @Test func presentedComposerRoutesEventsOnlyWithinTheCardFrame() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let overlay = BrowserDesignModeComposerHostingView(
            rootView: BrowserDesignModePopoverHost(controller: makeController())
        )
        overlay.frame = container.bounds
        container.addSubview(overlay)

        let cardFrame = CGRect(x: 100, y: 300, width: 200, height: 80)
        overlay.cardFrameInTopLeftCoordinates = cardFrame

        func hit(topLeftPoint: NSPoint) -> NSView? {
            let localPoint = overlay.isFlipped
                ? topLeftPoint
                : NSPoint(x: topLeftPoint.x, y: overlay.bounds.height - topLeftPoint.y)
            return overlay.hitTest(overlay.convert(localPoint, to: container))
        }

        #expect(
            hit(topLeftPoint: NSPoint(x: 150, y: 320)) != nil,
            "Events inside the composer card must reach the composer"
        )
        #expect(
            hit(topLeftPoint: NSPoint(x: 20, y: 20)) == nil,
            "Events outside the composer card must pass through to the page"
        )
    }

    @Test func selectionTokenExposesAnAccessibleRemovalAction() {
        let selection = BrowserDesignModeSelection(
            selector: "#hero",
            selectors: ["#hero"],
            tagName: "h1",
            domSnippet: "<h1 id=\"hero\">Hero</h1>",
            textContent: "Hero",
            textEditable: true,
            bounds: BrowserDesignModeRect(x: 10, y: 20, width: 200, height: 60),
            viewport: BrowserDesignModeViewport(width: 800, height: 600),
            computedStyles: [:]
        )
        var removedIdentity: String?
        let cell = BrowserDesignModeTokenCell(selection: selection) { identity in
            removedIdentity = identity
        }

        #expect(cell.accessibilityRole() == .button)
        #expect(
            cell.accessibilityLabel() == String(
                localized: "browser.designMode.context.remove",
                defaultValue: "Remove \(selection.tagName) context"
            )
        )
        #expect(cell.accessibilityPerformPress())
        #expect(removedIdentity == "#hero")
    }

    @Test func annotationTokenDisplaysCapturedRegionThumbnail() throws {
        let screenshotURL = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-token-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: screenshotURL) }
        let screenshot = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 48,
                pixelsHigh: 32,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let screenshotContext = try #require(NSGraphicsContext(bitmapImageRep: screenshot))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = screenshotContext
        NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 48, height: 32).fill()
        let inkPath = NSBezierPath()
        inkPath.move(to: NSPoint(x: 4, y: 6))
        inkPath.line(to: NSPoint(x: 44, y: 26))
        inkPath.lineWidth = 5
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setStroke()
        inkPath.stroke()
        screenshotContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        #expect(containsMagentaPixel(in: screenshot), "The test screenshot must contain visible ink")
        let png = try #require(screenshot.representation(using: .png, properties: [:]))
        try png.write(to: screenshotURL, options: .atomic)

        let selection = BrowserDesignModeSelection(
            selector: "@annotation(test-region)",
            selectors: [],
            color: "#1E90FF",
            tagName: "region",
            domSnippet: "",
            textContent: "",
            textEditable: false,
            bounds: BrowserDesignModeRect(x: 10, y: 20, width: 200, height: 120),
            viewport: BrowserDesignModeViewport(width: 800, height: 600),
            computedStyles: [:]
        )
        let controller = makeController()
        controller.annotationScreenshotPaths[selection.selector] = screenshotURL.path
        controller.apply(
            BrowserDesignModeSnapshot(
                revision: 1,
                enabled: true,
                selection: selection,
                edits: [],
                cssDiff: ""
            )
        )
        let host = NSHostingView(rootView: BrowserDesignModePopover(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(firstSubview(of: BrowserDesignModeTokenTextView.self, in: host))
        let storage = try #require(textView.textStorage)
        let attachment = try #require(
            storage.attribute(.attachment, at: 0, effectiveRange: nil)
                as? BrowserDesignModeTokenAttachment
        )
        #expect(attachment.screenshotPath == screenshotURL.path)
        let cell = try #require(attachment.attachmentCell as? BrowserDesignModeTokenCell)
        let cellSize = cell.cellSize()
        let rendered = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(cellSize.width)),
                pixelsHigh: Int(ceil(cellSize.height)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        rendered.size = cellSize
        let context = try #require(NSGraphicsContext(bitmapImageRep: rendered))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        cell.draw(withFrame: NSRect(origin: .zero, size: cellSize), in: textView)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        #expect(
            containsMagentaPixel(in: rendered),
            "A drawn-region token must visibly render the ink from its captured screenshot"
        )
    }

    private func containsMagentaPixel(in bitmap: NSBitmapImageRep) -> Bool {
        guard let bitmapData = bitmap.bitmapData else { return false }
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else { return false }
        let redOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let pixel = bitmapData + y * bitmap.bytesPerRow + x * bytesPerPixel
                if pixel[redOffset] > 204,
                   pixel[redOffset + 1] < 51,
                   pixel[redOffset + 2] > 204 {
                    return true
                }
            }
        }
        return false
    }

    private func firstSubview<View: NSView>(of type: View.Type, in root: NSView) -> View? {
        if let match = root as? View { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    @Test func tokenHitTestingResolvesOnlyTheGlyphUnderThePointer() throws {
        let selection = BrowserDesignModeSelection(
            selector: "#hero",
            selectors: ["#hero"],
            tagName: "h1",
            domSnippet: "<h1 id=\"hero\">Hero</h1>",
            textContent: "Hero",
            textEditable: true,
            bounds: BrowserDesignModeRect(x: 10, y: 20, width: 200, height: 60),
            viewport: BrowserDesignModeViewport(width: 800, height: 600),
            computedStyles: [:]
        )
        let textView = BrowserDesignModeTokenTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 40)
        )
        let storage = try #require(textView.textStorage)
        storage.setAttributedString(
            BrowserDesignModeTokenAttachment.attributedToken(for: selection) { _ in }
        )
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualCharacterRange: nil
        )
        let tokenFrame = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)

        #expect(textView.tokenHit(at: NSPoint(x: tokenFrame.midX, y: tokenFrame.midY))?.identity == "#hero")
        #expect(textView.tokenHit(at: NSPoint(x: 300, y: tokenFrame.midY)) == nil)
    }

    @Test func failedRuntimeRemovalKeepsAuthoritativeSelection() async {
        let controller = makeController()
        controller.phase = .active(annotation: .idle)
        let selection = BrowserDesignModeSelection(
            selector: "#hero",
            selectors: ["#hero"],
            tagName: "h1",
            domSnippet: "<h1 id=\"hero\">Hero</h1>",
            textContent: "Hero",
            textEditable: true,
            bounds: BrowserDesignModeRect(x: 10, y: 20, width: 200, height: 60),
            viewport: BrowserDesignModeViewport(width: 800, height: 600),
            computedStyles: [:]
        )
        controller.apply(
            BrowserDesignModeSnapshot(
                revision: 1,
                enabled: true,
                selection: selection,
                edits: [],
                cssDiff: ""
            )
        )

        let removed = await controller.removeSelection(at: 0)

        #expect(!removed)
        #expect(controller.snapshot?.selections == [selection])
    }

    @Test func mixedTokenDeletionPreservesOnlyTheAttachmentRange() {
        let content = NSMutableAttributedString(string: "A\u{FFFC}BC")
        content.addAttribute(
            .attachment,
            value: NSTextAttachment(),
            range: NSRange(location: 1, length: 1)
        )

        let ranges = BrowserDesignModeTokenDeletion.textRangesOutsideAttachments(
            in: content,
            range: NSRange(location: 0, length: content.length)
        )

        #expect(ranges == [
            NSRange(location: 0, length: 1),
            NSRange(location: 2, length: 2),
        ])
    }
}
