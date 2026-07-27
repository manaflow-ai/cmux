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
            screenshotStore: BrowserDesignModeScreenshotStore(directory: URL.temporaryDirectory),
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
