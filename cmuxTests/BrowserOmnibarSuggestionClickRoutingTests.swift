import AppKit
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

    private func makeSlotWithSuggestions() throws -> (window: NSWindow, slot: WindowBrowserSlotView) {
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        let contentView = NSView(frame: contentRect)
        let slot = WindowBrowserSlotView(frame: contentRect)
        window.contentView = contentView
        contentView.addSubview(slot)

        slot.setOmnibarSuggestions(
            BrowserPortalOmnibarSuggestionsConfiguration(
                panelId: UUID(),
                popupFrame: CGRect(x: 100, y: 8, width: 400, height: 120),
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
        )
        slot.layoutSubtreeIfNeeded()

        let overlay = try #require(
            slot.subviews.compactMap { $0 as? BrowserPortalOmnibarSuggestionsHostingView }.first
        )
        try #require(overlay.frame == slot.bounds)

        return (window, slot)
    }

    private func overlayClaims(_ view: NSView?, in slot: NSView) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is BrowserPortalOmnibarSuggestionsHostingView { return true }
            if candidate === slot { return false }
            current = candidate.superview
        }
        return false
    }
}
