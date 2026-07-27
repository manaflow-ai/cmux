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
        let runtime = FakeApplicationSurfaceRuntime()
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: runtime
        )!
        let target = panel.captureTarget!
        let token = panel.beginCaptureSession()
        let view = ApplicationCaptureView(
            windowID: target.windowID,
            processID: target.processID,
            targetFrameRate: panel.targetFrameRate,
            runtime: runtime,
            leaseProvider: { nil },
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

    @Test func applicationNamedKeysAcceptTerminalSeparators() {
        let plus = ApplicationCaptureView.parseNamedKey("ctrl+c")
        let dash = ApplicationCaptureView.parseNamedKey("ctrl-c")

        #expect(plus?.keyCode == CGKeyCode(kVK_ANSI_C))
        #expect(plus?.flags.contains(.maskControl) == true)
        #expect(dash?.keyCode == plus?.keyCode)
        #expect(dash?.flags == plus?.flags)
        #expect(ApplicationCaptureView.parseNamedKey("hyper-c") == nil)
    }

    @Test func modifierTransitionsTrackPhysicalKeysIndependently() {
        var pressed: Set<UInt16> = []

        #expect(ApplicationCaptureView.modifierKeyTransition(
            keyCode: UInt16(kVK_Shift),
            pressedKeyCodes: &pressed
        ))
        #expect(ApplicationCaptureView.modifierKeyTransition(
            keyCode: UInt16(kVK_RightShift),
            pressedKeyCodes: &pressed
        ))
        #expect(!ApplicationCaptureView.modifierKeyTransition(
            keyCode: UInt16(kVK_Shift),
            pressedKeyCodes: &pressed
        ))
        #expect(!ApplicationCaptureView.modifierKeyTransition(
            keyCode: UInt16(kVK_RightShift),
            pressedKeyCodes: &pressed
        ))
        #expect(pressed.isEmpty)
    }

    @Test func pickerSearchMatchesOwnerAndWindowTitle() {
        let model = ApplicationSurfacePickerModel()
        model.replaceWindows([
            ApplicationWindowDescriptor(
                windowID: 1,
                processID: 10,
                owner: "Calculator",
                title: "Calculator",
                width: 400,
                height: 600
            ),
            ApplicationWindowDescriptor(
                windowID: 2,
                processID: 20,
                owner: "Preview",
                title: "Release Notes.pdf",
                width: 800,
                height: 600
            ),
        ])

        #expect(model.selectedWindowID == 1)
        model.query = "release"
        #expect(model.filteredWindows.map(\.windowID) == [2])
        model.query = "calculator"
        #expect(model.filteredWindows.map(\.windowID) == [1])
    }

    @Test func applicationPaneOwnsWindowSelection() {
        let runtime = FakeApplicationSurfaceRuntime()
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            targetFrameRate: 60,
            runtime: runtime
        )!
        let panelID = panel.id
        var titleChanges: [String] = []
        panel.setDisplayTitleChangeHandler { titleChanges.append($0) }

        #expect(panel.captureTarget == nil)
        #expect(panel.captureStateDescription == "selecting")

        panel.selectWindow(ApplicationWindowDescriptor(
            windowID: 88,
            processID: 99,
            owner: "Calculator",
            title: "Calculator",
            width: 674,
            height: 408
        ))

        #expect(panel.id == panelID)
        #expect(panel.captureTarget == ApplicationPanel.CaptureTarget(
            windowID: 88,
            processID: 99
        ))
        #expect(panel.displayTitle == "Calculator")
        #expect(panel.selectedWindowTitle == "Calculator")

        panel.chooseAnotherWindow()

        #expect(panel.id == panelID)
        #expect(panel.captureTarget == nil)
        #expect(panel.displayTitle == "Application")
        #expect(titleChanges == ["Calculator", "Application"])
    }
}

@MainActor
private final class FakeApplicationSurfaceRuntime: ApplicationSurfaceRuntime {
    func acquireApplicationSurfaceLease() async -> ApplicationSurfaceRuntimeLease? {
        nil
    }

    func listApplicationWindows(
        lease: ApplicationSurfaceRuntimeLease
    ) async throws -> [ApplicationWindowDescriptor] {
        []
    }

    func startApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        windowID: UInt32,
        processID: Int32,
        frameRate: Int
    ) async throws -> ApplicationSurfaceSessionDescriptor {
        throw ApplicationSurfaceRuntimeError.helperUnavailable
    }

    func stopApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async {}

    func sendApplicationSurfaceEvent(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String,
        event: ApplicationSurfaceInputEvent
    ) async throws {}
}
