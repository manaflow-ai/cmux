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
                defaultValue: "Remove h1 context"
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
        for y in 0..<screenshot.pixelsHigh {
            for x in 0..<screenshot.pixelsWide {
                let isInk = abs(y - (x / 2 + 4)) <= 2
                screenshot.setColor(
                    isInk ? .magenta : NSColor(white: 0.25, alpha: 1),
                    atX: x,
                    y: y
                )
            }
        }
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
        let rendered = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rendered)

        var foundThumbnailPixel = false
        for y in 0..<rendered.pixelsHigh where !foundThumbnailPixel {
            for x in 0..<rendered.pixelsWide {
                guard let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8,
                   color.greenComponent < 0.2,
                   color.blueComponent > 0.8 {
                    foundThumbnailPixel = true
                    break
                }
            }
        }

        #expect(
            foundThumbnailPixel,
            "A drawn-region token must visibly render the ink from its captured screenshot"
        )
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
