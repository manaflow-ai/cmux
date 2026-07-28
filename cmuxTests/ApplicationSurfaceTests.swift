import AppKit
import Carbon.HIToolbox
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Application surfaces", .serialized)
struct ApplicationSurfaceTests {
    private final class MenuActionProbe: NSObject {
        private(set) var callCount = 0

        @objc func perform(_ sender: Any?) {
            callCount += 1
        }
    }

    @Test func focusIntentWaitsForCaptureViewWindow() async {
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
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.contentView = view

        #expect(window.firstResponder === view)
        #expect(!view.isReleasingForwardedInput)
        panel.unfocus()
        #expect(window.firstResponder !== view)
        #expect(view.isReleasingForwardedInput)
        await view.waitUntilForwardedInputReleased()
        #expect(!view.isReleasingForwardedInput)
    }

    @Test func captureRequiresBothPaneIntentAndVisibleHostWindow() {
        #expect(ApplicationCaptureView.shouldCapture(
            captureDesired: true,
            hostWindowVisible: true
        ))
        #expect(!ApplicationCaptureView.shouldCapture(
            captureDesired: true,
            hostWindowVisible: false
        ))
        #expect(!ApplicationCaptureView.shouldCapture(
            captureDesired: false,
            hostWindowVisible: true
        ))
    }

    @Test func captureLivenessDistinguishesFirstFrameAndStreamStalls() {
        var state = ApplicationCaptureLivenessState(startedAt: 10)

        #expect(state.failure(
            at: 17.9,
            firstFrameTimeout: 8,
            frameStallTimeout: 5
        ) == nil)
        #expect(state.failure(
            at: 18,
            firstFrameTimeout: 8,
            frameStallTimeout: 5
        ) == .firstFrameTimedOut)

        state.recordFrame(at: 20)
        #expect(state.failure(
            at: 24.9,
            firstFrameTimeout: 8,
            frameStallTimeout: 5
        ) == nil)
        #expect(state.failure(
            at: 25,
            firstFrameTimeout: 8,
            frameStallTimeout: 5
        ) == .frameStalled)
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

    @Test func inputPumpRejectsNonMotionEventsBeyondItsBound() async {
        var delivered: [ApplicationSurfaceInputEvent] = []
        let pump = ApplicationSurfaceInputPump(maximumQueuedEventCount: 2) { event in
            delivered.append(event)
            return true
        }
        let first = ApplicationSurfaceInputEvent(kind: .key, keyCode: 1, keyDown: true)
        let second = ApplicationSurfaceInputEvent(kind: .scroll, deltaY: 1)
        let rejected = ApplicationSurfaceInputEvent(kind: .key, keyCode: 2, keyDown: true)

        #expect(pump.enqueue(first) == .accepted)
        #expect(pump.enqueue(second) == .accepted)
        #expect(pump.enqueue(rejected) == .full)
        await pump.waitUntilIdle()

        #expect(delivered == [first, second])
    }

    @Test func inputPumpQueuesNamedKeyPairAtomically() async {
        var delivered: [ApplicationSurfaceInputEvent] = []
        let pump = ApplicationSurfaceInputPump(maximumQueuedEventCount: 1) { event in
            delivered.append(event)
            return true
        }
        let keyDown = ApplicationSurfaceInputEvent(kind: .key, keyCode: 12, keyDown: true)
        let keyUp = ApplicationSurfaceInputEvent(kind: .key, keyCode: 12, keyDown: false)

        #expect(pump.enqueue([keyDown, keyUp]) == .full)
        await pump.waitUntilIdle()

        #expect(delivered.isEmpty)
    }

    @Test func inputPumpCoalescesMotionBeforeApplyingBackpressure() async {
        var delivered: [ApplicationSurfaceInputEvent] = []
        let pump = ApplicationSurfaceInputPump(maximumQueuedEventCount: 2) { event in
            delivered.append(event)
            return true
        }
        for coordinate in 0..<100 {
            #expect(pump.enqueue(ApplicationSurfaceInputEvent(
                kind: .mouseMoved,
                x: Double(coordinate),
                y: Double(coordinate)
            )) == .accepted)
        }
        let key = ApplicationSurfaceInputEvent(kind: .key, keyCode: 1, keyDown: true)
        #expect(pump.enqueue(key) == .accepted)

        await pump.waitUntilIdle()

        #expect(delivered.count == 2)
        #expect(delivered.first?.kind == .mouseMoved)
        #expect(delivered.first?.x == 99)
        #expect(delivered.last == key)
    }

    @Test func inputPumpSynthesizesReleasesForDeliveredPresses() async {
        var delivered: [ApplicationSurfaceInputEvent] = []
        let pump = ApplicationSurfaceInputPump { event in
            delivered.append(event)
            return true
        }
        let keyDown = ApplicationSurfaceInputEvent(kind: .key, keyCode: 56, keyDown: true)
        let mouseDown = ApplicationSurfaceInputEvent(
            kind: .leftMouseDown,
            x: 0.25,
            y: 0.5
        )
        let mouseDrag = ApplicationSurfaceInputEvent(
            kind: .leftMouseDragged,
            x: 0.75,
            y: 0.8
        )

        #expect(pump.enqueue(keyDown) == .accepted)
        #expect(pump.enqueue(mouseDown) == .accepted)
        #expect(pump.enqueue(mouseDrag) == .accepted)
        await pump.waitUntilIdle()

        let releases = await pump.discardPendingAndTakeReleaseEvents()

        #expect(releases.contains(ApplicationSurfaceInputEvent(
            kind: .key,
            keyCode: 56,
            keyDown: false
        )))
        #expect(releases.contains(ApplicationSurfaceInputEvent(
            kind: .leftMouseUp,
            x: 0.75,
            y: 0.8
        )))
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

    @Test func applicationPanelRetainsCaptureViewAcrossRepresentableLifetime() {
        let runtime = FakeApplicationSurfaceRuntime()
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: runtime
        )!
        let token = panel.beginCaptureSession()
        var view: ApplicationCaptureView? = ApplicationCaptureView(
            windowID: 42,
            processID: 43,
            targetFrameRate: 60,
            runtime: runtime,
            leaseProvider: { nil },
            onStateChanged: { _ in },
            onMovedToWindow: { _ in }
        )
        weak var retainedView = view

        panel.attach(view!, token: token)
        view = nil

        #expect(retainedView != nil)
        panel.close()
    }

    @Test func applicationPanelReusesCaptureViewAcrossRepresentableRemounts() {
        let runtime = FakeApplicationSurfaceRuntime()
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: runtime
        )!

        let firstView = panel.captureView(windowID: 42, processID: 43)
        let secondView = panel.captureView(windowID: 42, processID: 43)

        #expect(firstView === secondView)
        panel.close()
    }

    @Test func hiddenApplicationCaptureReportsSuspendedHealth() {
        let runtime = FakeApplicationSurfaceRuntime()
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: runtime
        )!
        let view = panel.captureView(windowID: 42, processID: 43)

        panel.setCaptureVisibleInUI(true, view: view)

        #expect(panel.captureStateDescription == "suspended")
        panel.close()
    }

    @Test func applicationEditingKeyEquivalentReachesPaneBeforeMainMenu() throws {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let runtime = FakeApplicationSurfaceRuntime()
        let view = ApplicationCaptureView(
            windowID: 42,
            processID: 43,
            targetFrameRate: 60,
            runtime: runtime,
            leaseProvider: { nil },
            onStateChanged: { _ in },
            onMovedToWindow: { _ in }
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        #expect(window.makeFirstResponder(view))

        let probe = MenuActionProbe()
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu(title: "Main")
        let menuItem = NSMenuItem(
            title: "Host Command",
            action: #selector(MenuActionProbe.perform(_:)),
            keyEquivalent: "i"
        )
        menuItem.keyEquivalentModifierMask = [.command]
        menuItem.target = probe
        menu.addItem(menuItem)
        NSApp.mainMenu = menu
        defer {
            NSApp.mainMenu = previousMenu
            window.contentView = nil
            window.close()
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "i",
            charactersIgnoringModifiers: "i",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_I)
        ))

        #expect(window.performKeyEquivalent(with: event))
        #expect(probe.callCount == 0)
    }

    @Test func applicationTitleChangesFollowPanelAcrossWorkspaces() throws {
        let runtime = FakeApplicationSurfaceRuntime()
        let source = Workspace()
        let destination = Workspace()
        let sourcePane = try #require(source.bonsplitController.allPaneIds.first)
        let destinationPane = try #require(
            destination.bonsplitController.allPaneIds.first
        )
        let panel = try #require(source.newApplicationSurface(
            inPane: sourcePane,
            windowID: 42,
            processID: 43,
            title: "Preview",
            runtime: runtime
        ))
        let detached = try #require(source.detachSurface(panelId: panel.id))

        #expect(destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ) == panel.id)
        panel.selectWindow(ApplicationWindowDescriptor(
            windowID: 88,
            processID: 99,
            owner: "Calculator",
            title: "Calculator",
            width: 674,
            height: 408
        ))

        #expect(panel.workspaceId == destination.id)
        #expect(destination.panelTitle(panelId: panel.id) == "Calculator")
        #expect(source.panelTitle(panelId: panel.id) == nil)
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
