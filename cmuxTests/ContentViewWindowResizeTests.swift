import AppKit
import CmuxAppKitSupportUI
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("content view pane overlay geometry")
struct ContentViewWindowResizeTests {
    @Test @MainActor
    func windowOverlayUsesItsFlippedReferenceViewForPaneCoordinates() throws {
        _ = NSApplication.shared

        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 800))
        let window = NSWindow(
            contentRect: rootView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = rootView
        defer { window.close() }

        let overlayReferenceView = NSHostingView(rootView: Color.clear)
        overlayReferenceView.frame = rootView.bounds
        rootView.addSubview(overlayReferenceView)
        #expect(!rootView.isFlipped)
        #expect(overlayReferenceView.isFlipped)

        let paneView = NSView(frame: NSRect(x: 100, y: 500, width: 600, height: 220))
        overlayReferenceView.addSubview(paneView)

        let glassEffect = PaneOverlayGlassEffectStub()
        glassEffect.installationTarget = WindowContentOverlayInstallationTarget(
            container: rootView,
            reference: overlayReferenceView
        )
        let resolver = WindowContentOverlayTargetResolver(glassEffect: glassEffect)
        let coordinateSpace = try #require(
            ContentView.tmuxWorkspacePaneWindowOverlayReferenceView(
                for: window,
                resolver: resolver
            )
        )

        #expect(coordinateSpace === overlayReferenceView)
        #expect(
            ContentView.tmuxWorkspacePaneExactRect(for: paneView, in: coordinateSpace)
                == paneView.frame
        )
    }
}

@MainActor
private final class PaneOverlayGlassEffectStub: WindowGlassEffectManaging {
    var backgroundViewIdentifier = NSUserInterfaceItemIdentifier("test.paneOverlay.background")
    var isAvailable = true
    var installationTarget: WindowContentOverlayInstallationTarget?

    func apply(
        to window: NSWindow,
        tintColor: NSColor?,
        style: WindowGlassEffectStyle?
    ) -> Bool {
        false
    }

    func updateTint(to window: NSWindow, color: NSColor?) {}

    func remove(from window: NSWindow) -> Bool {
        false
    }

    func foregroundContainer(for window: NSWindow) -> NSView? {
        installationTarget?.container
    }

    func originalContentView(for window: NSWindow) -> NSView? {
        installationTarget?.reference
    }

    func portalInstallationTarget(for window: NSWindow) -> WindowContentOverlayInstallationTarget? {
        installationTarget
    }
}
