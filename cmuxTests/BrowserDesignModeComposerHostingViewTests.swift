import AppKit
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
}
