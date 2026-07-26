import AppKit
import Carbon.HIToolbox
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Application surfaces")
struct ApplicationSurfaceTests {
    @Test func focusIntentWaitsForCaptureViewWindow() {
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60
        )!
        let token = panel.beginCaptureSession()
        let view = ApplicationCaptureView(
            windowID: panel.windowID,
            processID: panel.processID,
            targetFrameRate: panel.targetFrameRate,
            onStateChanged: { _ in },
            onMovedToWindow: { view in
                panel.captureViewDidMoveToWindow(view, token: token)
            }
        )
        panel.attach(view, token: token)
        panel.focus()

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        window.contentView = view

        #expect(window.firstResponder === view)
        panel.unfocus()
        #expect(window.firstResponder !== view)
    }

    @Test func letterboxMarginsDoNotMapToNativeWindowEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let sourceFrame = CGRect(x: 1_000, y: 500, width: 100, height: 100)

        #expect(ApplicationCaptureView.sourcePoint(
            for: CGPoint(x: 25, y: 50),
            in: bounds,
            sourceFrame: sourceFrame
        ) == nil)
        #expect(ApplicationCaptureView.sourcePoint(
            for: CGPoint(x: 100, y: 50),
            in: bounds,
            sourceFrame: sourceFrame
        ) == CGPoint(x: 1_050, y: 550))
    }

    @Test func capturePixelSizeTracksSourceAspectRatioAndCapsResolution() {
        #expect(ApplicationCaptureView.capturePixelSize(
            for: CGSize(width: 800, height: 600)
        ) == CGSize(width: 1_600, height: 1_200))
        #expect(ApplicationCaptureView.capturePixelSize(
            for: CGSize(width: 4_000, height: 1_000)
        ) == CGSize(width: 4_096, height: 1_024))
    }

    @Test func applicationNamedKeysAcceptTerminalSeparators() {
        let plus = ApplicationCaptureView.parseNamedKey("ctrl+c")
        let dash = ApplicationCaptureView.parseNamedKey("ctrl-c")

        #expect(plus?.keyCode == CGKeyCode(kVK_ANSI_C))
        #expect(plus?.flags.contains(.maskControl) == true)
        #expect(dash?.keyCode == plus?.keyCode)
        #expect(dash?.flags == plus?.flags)
        #expect(ApplicationCaptureView.parseNamedKey("hyper-c") == nil)
    }
}
