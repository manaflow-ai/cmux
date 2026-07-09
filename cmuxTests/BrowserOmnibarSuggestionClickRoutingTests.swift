import AppKit
import CmuxBrowser
import CmuxBrowserUI
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct BrowserOmnibarSuggestionClickRoutingTests {
    @Test func clickInsideVisiblePopupRoutesToSuggestionsOverlay() throws {
        let setup = try makeSlotWithSuggestions()
        let hit = setup.slot.hitTest(NSPoint(x: 300, y: 540))

        #expect(overlayClaims(hit, in: setup.slot))
    }

    @Test func mirroredBottomRegionDoesNotSwallowClicks() throws {
        let setup = try makeSlotWithSuggestions()
        let hit = setup.slot.hitTest(NSPoint(x: 300, y: 60))

        #expect(!overlayClaims(hit, in: setup.slot))
    }

    @Test func offsetOverlayFrameClickRoutesToSuggestionsOverlay() throws {
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        let host = makeHostWindow(contentRect: contentRect)
        let container = NSView(frame: contentRect)
        host.contentView.addSubview(container)

        let popupFrame = CGRect(x: 0, y: 0, width: 400, height: 60)
        let configuration = makeSuggestionsConfiguration(popupFrame: popupFrame)
        let overlay = BrowserPortalOmnibarSuggestionsHostingView(
            rootView: BrowserPortalOmnibarSuggestionsOverlay(configuration: configuration)
        )
        overlay.popupFrameInTopLeftCoordinates = popupFrame
        overlay.frame = CGRect(x: 200, y: 100, width: 400, height: 300)
        container.addSubview(overlay)

        // macOS 15 CI has an unflipped NSHostingView, where aligned-frame cases
        // cannot distinguish the old math from the fixed conversion. Offsetting
        // the frame exposes the superview-coordinate contract under both flip
        // regimes: container (350, 380) -> local bottom-left (150, 280) ->
        // local top-left (150, 20), inside the popup strip.
        let popupHit = container.hitTest(NSPoint(x: 350, y: 380))
        #expect(overlayClaims(popupHit, in: container))

        let belowPopupHit = container.hitTest(NSPoint(x: 350, y: 150))
        #expect(!overlayClaims(belowPopupHit, in: container))
    }

    private func makeSlotWithSuggestions() throws -> (window: NSWindow, slot: WindowBrowserSlotView) {
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        let host = makeHostWindow(contentRect: contentRect)
        let slot = WindowBrowserSlotView(frame: contentRect)
        host.contentView.addSubview(slot)

        slot.setOmnibarSuggestions(
            makeSuggestionsConfiguration(popupFrame: CGRect(x: 100, y: 8, width: 400, height: 120))
        )
        slot.layoutSubtreeIfNeeded()

        let overlay = try #require(
            slot.subviews.compactMap { $0 as? BrowserPortalOmnibarSuggestionsHostingView }.first
        )
        try #require(overlay.frame == slot.bounds)

        return (host.window, slot)
    }

    private func makeHostWindow(contentRect: NSRect) -> (window: NSWindow, contentView: NSView) {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        let contentView = NSView(frame: contentRect)
        window.contentView = contentView
        return (window, contentView)
    }

    private func makeSuggestionsConfiguration(
        popupFrame: CGRect
    ) -> BrowserPortalOmnibarSuggestionsConfiguration {
        BrowserPortalOmnibarSuggestionsConfiguration(
            panelId: UUID(),
            popupFrame: popupFrame,
            colorScheme: .light,
            engineName: "TestEngine",
            items: [
                OmnibarSuggestion(kind: .search(engineName: "TestEngine", query: "alpha")),
                OmnibarSuggestion(kind: .search(engineName: "TestEngine", query: "beta")),
            ],
            selectedIndex: 0,
            isLoadingRemoteSuggestions: false,
            searchSuggestionsEnabled: true,
            onCommit: { _ in },
            onHighlight: { _ in }
        )
    }

    private func overlayClaims(_ view: NSView?, in boundary: NSView) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is BrowserPortalOmnibarSuggestionsHostingView { return true }
            if candidate === boundary { return false }
            current = candidate.superview
        }
        return false
    }
}
