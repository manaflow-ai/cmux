import AppKit
import CmuxComputerUseVisuals
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use visible content layout")
struct ComputerUseVisibleContentCenterTests {
    /// A retained AppKit view gives the test the child frame produced by the
    /// real SwiftUI hosting/layout stack rather than re-deriving it from a
    /// synthetic midpoint.
    @MainActor
    private final class FrameCapture {
        var view: NSView?
    }

    /// Embeds the frame capture in the visual block under test.
    @MainActor
    private struct FrameProbe: NSViewRepresentable {
        let capture: FrameCapture

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            capture.view = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// Verifies the actual hosting view centers a compact block below a
    /// full-size-content title bar, including the AppKit/SwiftUI coordinate
    /// conversion used by the production onboarding window.
    @Test @MainActor
    func titledHostingViewCentersCompactVisualInVisibleContent() async throws {
        let compactSize = ComputerUsePermissionCompanionLayout.size
        let capture = FrameCapture()
        let root = ComputerUseVisibleContentCenter {
            Color.clear
                .frame(width: compactSize.width, height: compactSize.height)
                .background(FrameProbe(capture: capture))
        }
        let window = ComputerUseOnboardingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let hostingView = ComputerUseOnboardingHostingView(rootView: root)
        window.contentView = hostingView
        defer { window.close() }

        window.orderBack(nil)
        for _ in 0..<12 {
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
        }

        let probe = try #require(capture.view)
        let visualFrame = probe.convert(probe.bounds, to: hostingView)
        let geometry = ComputerUseWindowContentGeometry(
            contentBounds: hostingView.bounds,
            contentLayoutRect: window.contentLayoutRect
        )

        #expect(
            abs(visualFrame.midX - geometry.visibleContentRect.midX) <= 0.5
        )
        #expect(
            abs(visualFrame.midY - geometry.visibleContentRect.midY) <= 0.5,
            "compact visual must be centered in the visible area, not under the title bar"
        )
    }
}
