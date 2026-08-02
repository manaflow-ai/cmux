import AppKit
import Bonsplit
import Carbon.HIToolbox
import CmuxAppKitSupportUI
import CmuxControlSocket
import CmuxExtensionKit
import CmuxSettings
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Application surfaces", .serialized)
struct ApplicationSurfaceTests {
    @Test func runtimeDaemonRequestsCannotUseUnboundedOneShotReads() throws {
        let serviceSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/App/ComputerUseRuntimeService.swift"
            )
        let serviceSource = try String(
            contentsOf: serviceSourceURL,
            encoding: .utf8
        )

        #expect(!serviceSource.contains("probeCommandWithPeerProcessID"))
    }

    @Test func cancelledWindowListInterruptsDefaultHelperRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-application-list-cancel-\(UUID().uuidString)",
                isDirectory: true
            )
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-app-list-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sockets,
            withIntermediateDirectories: true
        )
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: root,
            socketRootDirectoryURL: sockets,
            environment: ["CMUX_TAG": "cancel-window-list"],
            authenticationToken: "cancel-list-token"
        )
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
        let responder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"windows":[]}}"#,
            responseDelay: 2
        )
        defer { responder.stop() }
        let request = Task {
            await ComputerUseRuntimeService.sendDaemonRequestForTesting(
                ["method": "application_windows"],
                paths: paths,
                transport: SocketTransport(),
                timeout: 5,
                socketURL: paths.daemonSocketURL
            )
        }
        let requestDeadline = ContinuousClock.now + .seconds(1)
        while responder.receivedRequests.isEmpty,
              ContinuousClock.now < requestDeadline {
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        #expect(!responder.receivedRequests.isEmpty)
        let cancelledAt = ContinuousClock.now

        request.cancel()
        let response = await request.value

        #expect(response == nil)
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
    }

    @Test func cancelledPaneRequestInterruptsPersistentHelperRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-application-cancel-\(UUID().uuidString)",
                isDirectory: true
            )
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-app-cancel-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sockets,
            withIntermediateDirectories: true
        )
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: root,
            socketRootDirectoryURL: sockets,
            environment: ["CMUX_TAG": "cancel-request"],
            authenticationToken: "cancel-test-token"
        )
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
        let responder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true}"#,
            responseDelay: 2
        )
        defer { responder.stop() }
        let connection = PersistentSocketLineConnection()
        let request = Task {
            await ComputerUseRuntimeService.sendDaemonRequestForTesting(
                ["method": "application_surface_start"],
                paths: paths,
                transport: SocketTransport(),
                timeout: 5,
                socketURL: paths.daemonSocketURL,
                persistentConnection: connection
            )
        }
        let requestDeadline = ContinuousClock.now + .seconds(1)
        while responder.receivedRequests.isEmpty,
              ContinuousClock.now < requestDeadline {
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        #expect(!responder.receivedRequests.isEmpty)
        let cancelledAt = ContinuousClock.now

        request.cancel()
        let response = await request.value

        #expect(response == nil)
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        await connection.invalidate()
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
            onStateChanged: { _, _ in },
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

    @Test func applicationCaptureFocusCanBeRecognizedAndYielded() async {
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
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            panel.close()
            window.contentView = nil
            window.orderOut(nil)
        }
        window.contentView = view
        panel.focus()

        #expect(panel.ownedFocusIntent(for: view, in: window) == .panel)
        #expect(panel.yieldFocusIntent(.panel, in: window))
        #expect(window.firstResponder !== view)
        #expect(view.isReleasingForwardedInput)
        await view.waitUntilForwardedInputReleased()
    }

    @Test func inactiveWorkspaceHostRevokesApplicationCaptureInputOwnership() throws {
        let settingKey = PaneFirstClickFocusSettings.enabledKey
        let previousSetting = UserDefaults.standard.object(forKey: settingKey)
        UserDefaults.standard.set(true, forKey: settingKey)
        defer {
            if let previousSetting {
                UserDefaults.standard.set(previousSetting, forKey: settingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: settingKey)
            }
        }

        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: FakeApplicationSurfaceRuntime()
        )!
        let size = NSSize(width: 400, height: 300)
        let hostingView = NSHostingView(
            rootView: applicationPanelContent(
                panel: panel,
                allowsPointerInput: false
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderBack(nil)
        defer {
            panel.close()
            window.orderOut(nil)
            window.contentView = nil
        }

        settleApplicationPanel(hostingView)
        let captureView = try #require(
            firstApplicationCaptureView(in: hostingView)
        )

        #expect(!captureView.acceptsFirstMouse(for: nil))
    }

    @Test func applicationInputConnectionCanOwnStartBeforeSessionIDExists() {
        let registry = ApplicationSurfaceInputConnectionRegistry(
            transport: SocketTransport()
        )

        let first = registry.makeConnection()
        let second = registry.makeConnection()
        #expect(first !== second)
        #expect(registry.connection(for: "first") == nil)

        registry.register(first, for: "first")
        registry.register(second, for: "second")

        #expect(registry.connection(for: "first") === first)
        #expect(registry.connection(for: "second") === second)
        registry.removeConnection(for: "first")
        #expect(registry.connection(for: "first") == nil)
    }

    @Test func helperFailureFansOutWithoutPerSurfacePolling() async {
        let registry = ApplicationSurfaceFailureEventRegistry()
        var first = registry.events(for: "first").makeAsyncIterator()
        var second = registry.events(for: "second").makeAsyncIterator()

        registry.failAll(with: .helperUnavailable)

        #expect(await first.next() == .helperUnavailable)
        #expect(await first.next() == nil)
        #expect(await second.next() == .helperUnavailable)
        #expect(await second.next() == nil)
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

    @Test func inputRequiresPaneOwnershipAttachmentAndFirstPresentedFrame() {
        func ready(
            hasInputOwnership: Bool = true,
            attachmentAcknowledged: Bool,
            firstFramePresented: Bool
        ) -> Bool {
            ApplicationCaptureView.inputIsReady(
                hasInputOwnership: hasInputOwnership,
                shouldCaptureNow: true,
                hasSession: true,
                hasLease: true,
                attachmentAcknowledged: attachmentAcknowledged,
                firstFramePresented: firstFramePresented,
                isReleasingInput: false,
                isStopping: false
            )
        }

        #expect(!ready(
            hasInputOwnership: false,
            attachmentAcknowledged: true,
            firstFramePresented: true
        ))
        #expect(!ready(
            attachmentAcknowledged: false,
            firstFramePresented: false
        ))
        #expect(!ready(
            attachmentAcknowledged: true,
            firstFramePresented: false
        ))
        #expect(!ready(
            attachmentAcknowledged: false,
            firstFramePresented: true
        ))
        #expect(ready(
            attachmentAcknowledged: true,
            firstFramePresented: true
        ))
    }

    @Test func losingPaneInputOwnershipReleasesForwardedInput() async {
        let view = ApplicationCaptureView(
            windowID: 42,
            processID: 43,
            targetFrameRate: 60,
            runtime: FakeApplicationSurfaceRuntime(),
            leaseProvider: { nil },
            onStateChanged: { _, _ in },
            onMovedToWindow: { _ in }
        )

        view.setInputOwnership(true)
        view.setInputOwnership(false)

        #expect(view.isReleasingForwardedInput)
        await view.waitUntilForwardedInputReleased()
        #expect(!view.isReleasingForwardedInput)
    }

    @Test func frameTransportFailuresResolveThroughTheAppStringCatalog() {
        let expected = String(
            localized: "panel.application.captureFailed.detail",
            defaultValue: "cmux could not capture this window. Try again or choose another window."
        )

        #expect(
            ApplicationCaptureView.localizedTransportFailureDetail(
                .invalidTransport
            ) == expected
        )
        #expect(
            ApplicationCaptureView.localizedTransportFailureDetail(
                .producerFailed
            ) == expected
        )
    }

    @Test func captureFailureOverlayPreservesLocalizedRuntimeGuidance() {
        let fallback = String(
            localized: "panel.application.captureFailed.detail",
            defaultValue: "cmux could not capture this window. Try again or choose another window."
        )

        #expect(
            ApplicationPanelView.localizedCaptureFailureDetail(
                "Close another application pane and try again."
            ) == "Close another application pane and try again."
        )
        #expect(ApplicationPanelView.localizedCaptureFailureDetail(nil) == fallback)
    }

    @Test func captureLivenessAllowsStaticContentAfterFirstFrame() {
        var state = ApplicationCaptureLivenessState(startedAt: 10)

        #expect(state.failure(
            at: 17.9,
            firstFrameTimeout: 8
        ) == nil)
        #expect(state.failure(
            at: 18,
            firstFrameTimeout: 8
        ) == .firstFrameTimedOut)

        state.recordFrame(at: 20)
        #expect(state.failure(
            at: 120,
            firstFrameTimeout: 8
        ) == nil)
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

    @Test func mouseReleaseOutsideLetterboxUsesLastForwardedPoint() {
        let lastLeftPoint = CGPoint(x: 0.25, y: 0.75)
        let lastRightPoint = CGPoint(x: 0.8, y: 0.2)

        #expect(ApplicationCaptureView.resolvedMousePoint(
            kind: .leftMouseUp,
            normalizedPoint: nil,
            lastLeftPoint: lastLeftPoint,
            lastRightPoint: lastRightPoint
        ) == lastLeftPoint)
        #expect(ApplicationCaptureView.resolvedMousePoint(
            kind: .rightMouseUp,
            normalizedPoint: nil,
            lastLeftPoint: lastLeftPoint,
            lastRightPoint: lastRightPoint
        ) == lastRightPoint)
        #expect(ApplicationCaptureView.resolvedMousePoint(
            kind: .leftMouseDown,
            normalizedPoint: nil,
            lastLeftPoint: lastLeftPoint,
            lastRightPoint: lastRightPoint
        ) == nil)
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

    @Test func modifierTransitionsUsePhysicalEventState() {
        let leftShiftDown =
            NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICELSHIFTKEYMASK)
        let rightShiftDown =
            NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICERSHIFTKEYMASK)

        #expect(ApplicationCaptureView.modifierKeyIsDown(
            keyCode: UInt16(kVK_Shift),
            modifierFlagsRawValue: leftShiftDown
        ) == true)
        #expect(ApplicationCaptureView.modifierKeyIsDown(
            keyCode: UInt16(kVK_Shift),
            modifierFlagsRawValue: 0
        ) == false)
        #expect(ApplicationCaptureView.modifierKeyIsDown(
            keyCode: UInt16(kVK_Shift),
            modifierFlagsRawValue: rightShiftDown
        ) == false)
        #expect(ApplicationCaptureView.modifierKeyIsDown(
            keyCode: UInt16(kVK_RightShift),
            modifierFlagsRawValue: rightShiftDown
        ) == true)
    }

    @Test func applicationCaptureHonorsInactiveWindowFirstClickSetting() async {
        let key = PaneFirstClickFocusSettings.enabledKey
        let previousValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let view = ApplicationCaptureView(
            windowID: 42,
            processID: 43,
            targetFrameRate: 60,
            runtime: FakeApplicationSurfaceRuntime(),
            leaseProvider: { nil },
            onStateChanged: { _, _ in },
            onMovedToWindow: { _ in }
        )

        view.setInputOwnership(true)
        UserDefaults.standard.set(true, forKey: key)
        #expect(view.acceptsFirstMouse(for: nil))
        UserDefaults.standard.set(false, forKey: key)
        #expect(!view.acceptsFirstMouse(for: nil))
        UserDefaults.standard.set(true, forKey: key)
        view.setInputOwnership(false)
        #expect(!view.acceptsFirstMouse(for: nil))
        await view.waitUntilForwardedInputReleased()
    }

    @Test func inputPumpRejectsNonMotionEventsBeyondItsBound() async {
        var delivered: [ApplicationSurfaceInputEvent] = []
        let pump = ApplicationSurfaceInputPump(maximumQueuedEventCount: 2) { events in
            delivered.append(contentsOf: events)
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

    @Test func applicationInputSerializesTheDisplayedFrameSequence() {
        let arguments = ComputerUseRuntimeService.applicationSurfaceEventArguments(
            sessionID: "surface-one",
            event: ApplicationSurfaceInputEvent(
                kind: .mouseMoved,
                frameSequence: 73,
                x: 0.25,
                y: 0.75
            )
        )

        #expect((arguments["frame_sequence"] as? NSNumber)?.uint64Value == 73)
    }

    @Test func inputPumpQueuesNamedKeyPairAtomically() async {
        var delivered: [ApplicationSurfaceInputEvent] = []
        let pump = ApplicationSurfaceInputPump(maximumQueuedEventCount: 1) { events in
            delivered.append(contentsOf: events)
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
        let pump = ApplicationSurfaceInputPump(maximumQueuedEventCount: 2) { events in
            delivered.append(contentsOf: events)
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

    @Test func inputPumpCoalescesScrollBurstsBeforeApplyingBackpressure() async {
        var delivered: [ApplicationSurfaceInputEvent] = []
        let pump = ApplicationSurfaceInputPump(maximumQueuedEventCount: 2) { events in
            delivered.append(contentsOf: events)
            return true
        }

        for _ in 0..<100 {
            #expect(pump.enqueue(ApplicationSurfaceInputEvent(
                kind: .scroll,
                x: 0.25,
                y: 0.75,
                modifiers: UInt64(NSEvent.ModifierFlags.shift.rawValue),
                deltaX: 1,
                deltaY: -2
            )) == .accepted)
        }
        await pump.waitUntilIdle()

        #expect(delivered == [
            ApplicationSurfaceInputEvent(
                kind: .scroll,
                x: 0.25,
                y: 0.75,
                modifiers: UInt64(NSEvent.ModifierFlags.shift.rawValue),
                deltaX: 100,
                deltaY: -200
            ),
        ])
    }

    @Test func inputPumpBatchesBacklogWithoutDelayingFirstEvent() async {
        var batches: [[ApplicationSurfaceInputEvent]] = []
        var releaseFirstBatch: CheckedContinuation<Void, Never>?
        let pump = ApplicationSurfaceInputPump(
            maximumQueuedEventCount: 64,
            batchSender: { events in
                batches.append(events)
                if batches.count == 1 {
                    await withCheckedContinuation { continuation in
                        releaseFirstBatch = continuation
                    }
                }
                return true
            }
        )
        let first = ApplicationSurfaceInputEvent(
            kind: .key,
            keyCode: 1,
            keyDown: true
        )
        #expect(pump.enqueue(first) == .accepted)
        while batches.isEmpty {
            await Task.yield()
        }
        #expect(batches == [[first]])

        let backlog = (2 ... 33).map {
            ApplicationSurfaceInputEvent(
                kind: .key,
                keyCode: UInt16($0),
                keyDown: true
            )
        }
        for event in backlog {
            #expect(pump.enqueue(event) == .accepted)
        }
        releaseFirstBatch?.resume()
        await pump.waitUntilIdle()

        #expect(batches.count == 2)
        #expect(batches[1] == backlog)
    }

    @Test func inputPumpNeverExceedsTheHelperProtocolBatchLimit() async {
        var batches: [[ApplicationSurfaceInputEvent]] = []
        var releaseFirstBatch: CheckedContinuation<Void, Never>?
        let pump = ApplicationSurfaceInputPump(
            maximumQueuedEventCount: 128,
            batchSender: { events in
                batches.append(events)
                if batches.count == 1 {
                    await withCheckedContinuation { continuation in
                        releaseFirstBatch = continuation
                    }
                }
                return true
            }
        )
        let first = ApplicationSurfaceInputEvent(
            kind: .key,
            keyCode: 1,
            keyDown: true
        )
        #expect(pump.enqueue(first) == .accepted)
        while batches.isEmpty {
            await Task.yield()
        }

        let backlog = (2 ... 101).map {
            ApplicationSurfaceInputEvent(
                kind: .key,
                keyCode: UInt16($0),
                keyDown: true
            )
        }
        for event in backlog {
            #expect(pump.enqueue(event) == .accepted)
        }
        releaseFirstBatch?.resume()
        await pump.waitUntilIdle()

        #expect(batches.map(\.count) == [1, 64, 36])
        #expect(Array(batches.dropFirst().joined()) == backlog)
    }

    @Test func inputPumpSynthesizesReleasesForDeliveredPresses() async {
        var delivered: [ApplicationSurfaceInputEvent] = []
        let pump = ApplicationSurfaceInputPump { events in
            delivered.append(contentsOf: events)
            return true
        }
        let keyDown = ApplicationSurfaceInputEvent(kind: .key, keyCode: 56, keyDown: true)
        let mouseDown = ApplicationSurfaceInputEvent(
            kind: .leftMouseDown,
            frameSequence: 41,
            x: 0.25,
            y: 0.5
        )
        let mouseDrag = ApplicationSurfaceInputEvent(
            kind: .leftMouseDragged,
            frameSequence: 42,
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
            frameSequence: 42,
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
        #expect(panel.captureTarget == ApplicationCaptureTarget(
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
            onStateChanged: { _, _ in },
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

    @Test func dismantlingRepresentableSuspendsItsHostedCapture() {
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: FakeApplicationSurfaceRuntime()
        )!
        let view = panel.captureView(windowID: 42, processID: 43)
        let mountID = UUID()
        panel.updateCaptureViewMount(
            isVisibleInUI: true,
            allowsPointerInput: false,
            view: view,
            mountID: mountID
        )
        #expect(panel.captureEligibleForCurrentVisibility)

        ApplicationCaptureRepresentable.dismantleNSView(
            view,
            coordinator: mountID
        )

        #expect(!panel.captureEligibleForCurrentVisibility)
        panel.close()
    }

    @Test func staleRepresentableTeardownPreservesTheReplacementMount() {
        let firstClickSettingKey = PaneFirstClickFocusSettings.enabledKey
        let previousFirstClickSetting = UserDefaults.standard.object(
            forKey: firstClickSettingKey
        )
        UserDefaults.standard.set(true, forKey: firstClickSettingKey)
        defer {
            if let previousFirstClickSetting {
                UserDefaults.standard.set(
                    previousFirstClickSetting,
                    forKey: firstClickSettingKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: firstClickSettingKey
                )
            }
        }
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: FakeApplicationSurfaceRuntime()
        )!
        let staleView = panel.captureView(windowID: 42, processID: 43)
        let staleMountID = UUID()
        panel.updateCaptureViewMount(
            isVisibleInUI: true,
            allowsPointerInput: false,
            view: staleView,
            mountID: staleMountID
        )
        let replacementView = panel.captureView(windowID: 42, processID: 43)
        let replacementMountID = UUID()
        panel.updateCaptureViewMount(
            isVisibleInUI: true,
            allowsPointerInput: true,
            view: replacementView,
            mountID: replacementMountID
        )
        #expect(staleView === replacementView)
        #expect(replacementView.acceptsFirstMouse(for: nil))

        ApplicationCaptureRepresentable.dismantleNSView(
            staleView,
            coordinator: staleMountID
        )

        #expect(panel.captureEligibleForCurrentVisibility)
        #expect(replacementView.acceptsFirstMouse(for: nil))
        panel.close()
    }

    @Test func leavingCanvasRestoresSplitCaptureEligibility() {
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
        let container = NSView()
        let mount = CanvasPaneContentMount(
            content: .hosted(
                panel,
                view,
                CanvasHostedPanelPresentation(
                    isFocused: false,
                    allowsPointerInput: true,
                    pointerInputOwner: view
                )
            ),
            panelId: panel.id,
            container: container,
            onFocusPanel: { _ in }
        )

        mount.setRendering(false)
        #expect(!panel.captureEligibleForCurrentVisibility)

        mount.unmount()
        #expect(panel.captureEligibleForCurrentVisibility)
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

    @Test func dormantApplicationCaptureStartsWithSuspendedHealth() {
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: FakeApplicationSurfaceRuntime()
        )!

        #expect(panel.captureStateDescription == "suspended")
        panel.close()
    }

    @Test func pickerFailureSeparatesStableCodeFromLocalizedDetail() {
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            targetFrameRate: 60,
            runtime: FakeApplicationSurfaceRuntime()
        )!
        panel.pickerModel.phase = .failed("Localized helper failure")

        #expect(panel.captureFailureCode == "window_list_failed")
        #expect(panel.captureFailureDetail == "Localized helper failure")
        panel.close()
    }

    @Test func terminalCaptureFailureSurvivesVisibilityChanges() {
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
        let view = ApplicationCaptureView(
            windowID: 42,
            processID: 43,
            targetFrameRate: 60,
            runtime: runtime,
            leaseProvider: { nil },
            onStateChanged: { _, _ in },
            onMovedToWindow: { _ in }
        )
        panel.attach(view, token: token)
        panel.updateCaptureState(.windowUnavailable, token: token)

        panel.setCaptureVisibleInUI(false, view: view)

        #expect(panel.captureStateDescription == "window_unavailable")
        panel.close()
    }

    @Test func captureFailurePreservesLocalizedRuntimeDetailUntilRetry() {
        let panel = ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: 43,
            title: "Preview",
            targetFrameRate: 60,
            runtime: FakeApplicationSurfaceRuntime()
        )!
        let token = panel.beginCaptureSession()

        panel.updateCaptureState(
            .failed,
            failureDetail: "Localized helper failure",
            token: token
        )

        #expect(panel.captureFailureCode == "capture_failed")
        #expect(panel.captureFailureDetail == "Localized helper failure")

        panel.updateCaptureState(.starting, token: token)

        #expect(panel.captureFailureCode == nil)
        #expect(panel.captureFailureDetail == nil)
        panel.close()
    }

    @Test func unavailableApplicationEditingKeyEquivalentFallsThroughToMainMenu() throws {
        _ = NSApplication.shared
        let runtime = FakeApplicationSurfaceRuntime()
        let view = ApplicationCaptureView(
            windowID: 42,
            processID: 43,
            targetFrameRate: 60,
            runtime: runtime,
            leaseProvider: { nil },
            onStateChanged: { _, _ in },
            onMovedToWindow: { _ in }
        )
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "i",
            charactersIgnoringModifiers: "i",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_I)
        ))

        var fallbackCallCount = 0
        let handled = view.performKeyEquivalent(
            with: event
        ) {
            fallbackCallCount += 1
            return true
        }
        #expect(handled)
        #expect(fallbackCallCount == 1)
    }

    @Test func applicationEditingCommandsFollowTheProducedCharacter() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Q)
        ))

        #expect(
            ApplicationCommandEquivalentRoutingPolicy()
                .shouldRouteThroughContentFirst(event)
        )
    }

    @Test func explicitCmuxShortcutWinsOverFocusedApplicationPane() throws {
        _ = NSApplication.shared
        let runtime = FakeApplicationSurfaceRuntime()
        let view = ApplicationCaptureView(
            windowID: 42,
            processID: 43,
            targetFrameRate: 60,
            runtime: runtime,
            leaseProvider: { nil },
            onStateChanged: { _, _ in },
            onMovedToWindow: { _ in }
        )
        let windowID = UUID()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(
            "cmux.main.\(windowID.uuidString)"
        )
        window.contentView = view
        #expect(window.makeFirstResponder(view))

        let action = KeyboardShortcutSettings.Action.showNotifications
        let previousShortcutData = UserDefaults.standard.data(
            forKey: action.defaultsKey
        )
        let previousSettingsFileStore =
            KeyboardShortcutSettings.installIsolatedTestFileStore(
                prefix: "cmux-application-shortcut-routing"
            )
        KeyboardShortcutSettings.setShortcut(
            action.defaultShortcut,
            for: action
        )

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
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(applicationSurfaceRuntime: runtime)
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        appDelegate.clearConfiguredShortcutChordState()
        defer {
            _ = appDelegate.dismissNotificationsPopoverIfShown()
            appDelegate.clearConfiguredShortcutChordState()
            AppDelegate.shared = previousAppDelegate
            KeyboardShortcutSettings.settingsFileStore =
                previousSettingsFileStore
            if let previousShortcutData {
                UserDefaults.standard.set(
                    previousShortcutData,
                    forKey: action.defaultsKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: action.defaultsKey
                )
            }
            window.contentView = nil
            window.close()
        }

        #expect(appDelegate.handleConfiguredShortcutKeyEquivalent(event))
    }

    @Test func applicationSurfacePaneRestoresWithoutReusingOSWindowIDs() throws {
        let runtime = FakeApplicationSurfaceRuntime()
        let source = Workspace(applicationSurfaceRuntime: runtime)
        let sourcePane = try #require(
            source.bonsplitController.allPaneIds.first
        )
        let sourcePanel = try #require(source.newApplicationSurface(
            inPane: sourcePane,
            windowID: 42,
            processID: 43,
            title: "Dictionary",
            targetFrameRate: 45
        ))
        defer { sourcePanel.close() }

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        _ = try #require(
            snapshot.panels.first { $0.type == .application }
        )

        let restored = Workspace(applicationSurfaceRuntime: runtime)
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanel = try #require(
            restored.panels.values
                .compactMap { $0 as? ApplicationPanel }
                .first
        )
        defer { restoredPanel.close() }

        #expect(restoredPanel.captureTarget == nil)
        #expect(restoredPanel.targetFrameRate == 45)
        #expect(restoredPanel.runtime === runtime)
        #expect(
            restored.panelTitle(panelId: restoredPanel.id)
                == String(
                    localized: "panel.application.defaultTitle",
                    defaultValue: "Application"
                )
        )
    }

    @Test func pickerFailuresDoNotExposeRawHelperDiagnostics() async throws {
        let privateDiagnostic =
            "Failed to map /Users/private/Library/Application Support/cmux/frame"
        let runtime = FakeApplicationSurfaceRuntime()
        runtime.windowListError = NSError(
            domain: "ComputerUseHelper",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: privateDiagnostic]
        )
        let lease = ApplicationSurfaceRuntimeLease(
            service: ComputerUseRuntimeService(),
            identifier: UUID()
        )
        let panel = try #require(ApplicationPanel(
            workspaceId: UUID(),
            targetFrameRate: 60,
            runtime: runtime,
            runtimeLease: lease
        ))
        defer { panel.close() }

        panel.refreshAvailableWindows()
        while panel.pickerModel.phase == .loading {
            await Task.yield()
        }

        guard case let .failed(message) = panel.pickerModel.phase else {
            Issue.record("Expected a sanitized picker failure")
            return
        }
        #expect(!message.contains(privateDiagnostic))
        #expect(!message.contains("/Users/private"))
    }

    @Test func restoredWorkspacesKeepApplicationSurfaceRuntime() throws {
        let runtime = FakeApplicationSurfaceRuntime()
        let manager = TabManager(applicationSurfaceRuntime: runtime)
        let persistedSnapshot = manager.sessionSnapshot(includeScrollback: false)

        manager.restoreSessionSnapshot(persistedSnapshot)
        var workspace = try #require(manager.selectedWorkspace)
        var pane = try #require(workspace.bonsplitController.allPaneIds.first)
        var panel = try #require(workspace.newApplicationSurface(
            inPane: pane,
            windowID: 42,
            processID: 43,
            title: "Preview"
        ))
        #expect(panel.runtime === runtime)
        panel.close()

        manager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        ))
        workspace = try #require(manager.selectedWorkspace)
        pane = try #require(workspace.bonsplitController.allPaneIds.first)
        panel = try #require(workspace.newApplicationSurface(
            inPane: pane,
            windowID: 44,
            processID: 45,
            title: "Dictionary"
        ))
        #expect(panel.runtime === runtime)
        panel.close()
    }

    @Test func socketApplicationControlRequiresTrustedMode() {
        #expect(TerminalController.applicationSurfaceSocketControlIsAllowed(
            accessMode: .cmuxOnly
        ))
        #expect(TerminalController.applicationSurfaceSocketControlIsAllowed(
            accessMode: .password
        ))
        #expect(!TerminalController.applicationSurfaceSocketControlIsAllowed(
            accessMode: .automation
        ))
        #expect(!TerminalController.applicationSurfaceSocketControlIsAllowed(
            accessMode: .allowAll
        ))
        #expect(!TerminalController.applicationSurfaceSocketControlIsAllowed(
            accessMode: .off
        ))
    }

    @Test func socketApplicationControlRejectsAuthorizationFromPriorMode() throws {
        let controller = TerminalController.shared
        controller.stop()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-app-auth-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        controller.start(
            tabManager: TabManager(),
            socketPath: directory.appendingPathComponent("cmux.sock").path,
            accessMode: .automation
        )
        #expect(controller.socketServer.isRunning)
        let staleAuthorization = ControlSocketRequestAuthorization(
            acceptedAccessMode: .automation,
            generation: controller.socketServer.connectionAuthorizationGeneration,
            passwordAuthorization: SocketPasswordAuthorization()
        )

        #expect(controller.socketServer.reconfigure(accessMode: .cmuxOnly))
        #expect(!controller.applicationSurfaceSocketControlIsAuthorized(
            staleAuthorization
        ))
        let staleCreateResolution = controller.controlSurfaceCreate(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: nil,
                surfaceID: nil,
                paneID: nil
            ),
            inputs: ControlSurfaceCreateInputs(
                typeRaw: "application",
                providerRaw: nil,
                rendererRaw: nil,
                urlRaw: nil,
                applicationWindowID: 42,
                applicationProcessID: 43,
                applicationTitle: "Preview",
                applicationFrameRate: 60,
                workingDirectory: nil,
                initialCommand: nil,
                tmuxStartCommand: nil,
                remotePTYSessionID: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                requestedPaneID: nil,
                requestedFocus: false
            ),
            authorization: staleAuthorization
        )
        #expect(staleCreateResolution == .applicationControlUnavailable(
            message: TerminalController.applicationSurfaceSocketControlUnavailableMessage
        ))

        let currentAuthorization = ControlSocketRequestAuthorization(
            acceptedAccessMode: .cmuxOnly,
            generation: controller.socketServer.connectionAuthorizationGeneration,
            passwordAuthorization: SocketPasswordAuthorization()
        )
        #expect(controller.applicationSurfaceSocketControlIsAuthorized(
            currentAuthorization
        ))
    }

    @Test func implicitSendKeyTargetsFocusedApplicationSurface() throws {
        let runtime = FakeApplicationSurfaceRuntime()
        let workspace = Workspace(applicationSurfaceRuntime: runtime)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newApplicationSurface(
            inPane: pane,
            windowID: 42,
            processID: 43,
            title: "Dictionary",
            focus: true
        ))

        let target = workspace.controlDefaultSurfaceTarget(paneID: nil)

        #expect(target?.surfaceID == panel.id)
        #expect(target?.panel === panel)
        panel.close()
    }

    @Test func implicitSendKeyTargetsApplicationSurfaceInRoutedPane() throws {
        let runtime = FakeApplicationSurfaceRuntime()
        let workspace = Workspace(applicationSurfaceRuntime: runtime)
        let rootPane = try #require(
            workspace.bonsplitController.allPaneIds.first
        )
        let applicationPane = try #require(
            workspace.bonsplitController.splitPane(
                rootPane,
                orientation: .horizontal,
                withTab: nil,
                initialDividerPosition: 0.5
            )
        )
        let panel = try #require(workspace.newApplicationSurface(
            inPane: applicationPane,
            windowID: 42,
            processID: 43,
            title: "Dictionary",
            focus: true
        ))
        workspace.bonsplitController.focusPane(rootPane)

        let target = workspace.controlDefaultSurfaceTarget(
            paneID: applicationPane.id
        )

        #expect(target?.surfaceID == panel.id)
        #expect(target?.panel === panel)
        panel.close()
    }

    @Test func applicationSurfaceHasPublicSidebarKind() {
        #expect(CmuxSidebarSurfaceKind.application.rawValue == "application")
        #expect(
            CmuxSidebarSurfaceKind(panelType: .application)
                == .application
        )
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

    @Test func applicationSurfaceMoveRejectsRemoteTmuxMirrorDestinationWithoutDetachingSource() throws {
        let app = AppDelegate()
        let windowID = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(
            windowId: windowID,
            tabManager: manager
        )
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowID)
        }

        let runtime = FakeApplicationSurfaceRuntime()
        let source = try #require(manager.selectedWorkspace)
        let sourcePane = try #require(
            source.bonsplitController.allPaneIds.first
        )
        let panel = try #require(source.newApplicationSurface(
            inPane: sourcePane,
            windowID: 42,
            processID: 43,
            title: "Preview",
            runtime: runtime
        ))
        let destination = manager.addWorkspace(
            title: "Remote tmux",
            select: false
        )
        destination.isRemoteTmuxMirror = true
        let destinationPanelIDs = Set(destination.panels.keys)

        #expect(!app.moveSurface(
            panelId: panel.id,
            toWorkspace: destination.id,
            focus: false,
            focusWindow: false
        ))
        #expect(source.panels[panel.id] as? ApplicationPanel === panel)
        #expect(source.surfaceIdFromPanelId(panel.id) != nil)
        #expect(destination.panels[panel.id] == nil)
        #expect(Set(destination.panels.keys) == destinationPanelIDs)
        panel.close()
    }

    @Test func workspaceUsesItsInjectedApplicationSurfaceRuntime() throws {
        let runtime = FakeApplicationSurfaceRuntime()
        let workspace = Workspace(applicationSurfaceRuntime: runtime)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)

        let panel = try #require(workspace.newApplicationSurface(
            inPane: pane,
            windowID: 42,
            processID: 43,
            title: "Preview"
        ))

        #expect(panel.runtime === runtime)
        panel.close()
    }

    @Test func applicationSurfaceCannotMoveIntoDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager =
                TerminalController.shared.activeTabManagerForCallerNotification()
            let runtime = FakeApplicationSurfaceRuntime()
            let appDelegate = AppDelegate()
            let manager = TabManager(
                autoWelcomeIfNeeded: false,
                applicationSurfaceRuntime: runtime
            )
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: manager
            )
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(
                    windowId: windowID
                )
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let pane = try #require(
                workspace.bonsplitController.allPaneIds.first
            )
            let application = try #require(workspace.newApplicationSurface(
                inPane: pane,
                windowID: 42,
                processID: 43,
                title: "Dictionary",
                focus: false
            ))
            let sourceTabID = try #require(
                workspace.surfaceIdFromPanelId(application.id)
            )
            let dock = workspace.dockSplit
            let rootPane = try #require(
                dock.bonsplitController.allPaneIds.first
            )

            #expect(!appDelegate.canMoveSurfaceIntoDock(
                sourceTabId: sourceTabID.uuid,
                destinationDock: dock
            ))
            #expect(!appDelegate.moveSurfaceIntoDock(
                sourceTabId: sourceTabID.uuid,
                destinationDock: dock,
                destination: .insert(
                    targetPane: rootPane,
                    targetIndex: nil
                )
            ))
            #expect(workspace.panels[application.id] === application)
            #expect(dock.panel(for: sourceTabID) == nil)
        }
    }

    @Test func cliListsOnlyCapturableApplicationWindows() throws {
        let cliProcessID = pid_t(900)
        let applicationProcessID = pid_t(901)
        let hostProcessID = pid_t(902)
        let excludedProcessIDs: Set<pid_t> = [
            cliProcessID,
            hostProcessID,
        ]
        let base: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 42),
            kCGWindowOwnerPID as String: NSNumber(value: applicationProcessID),
            kCGWindowOwnerName as String: "Dictionary",
            kCGWindowName as String: "Dictionary",
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1),
            kCGWindowIsOnscreen as String: true,
            kCGWindowSharingState as String: NSNumber(value: 1),
            kCGWindowBounds as String: [
                "X": 10,
                "Y": 20,
                "Width": 800,
                "Height": 600,
            ] as NSDictionary,
        ]
        let regularApplication: (pid_t) -> Bool = {
            $0 == applicationProcessID
        }
        let filter = ApplicationWindowListFilter(
            excludedProcessIDs: excludedProcessIDs,
            isRegularApplication: regularApplication
        )

        let listed = try #require(filter.entry(base))
        #expect(listed["window_id"] as? Int == 42)
        #expect((listed["width"] as? NSNumber)?.doubleValue == 800)
        #expect((listed["height"] as? NSNumber)?.doubleValue == 600)

        var invalid = base
        invalid[kCGWindowOwnerPID as String] = NSNumber(
            value: cliProcessID
        )
        #expect(filter.entry(invalid) == nil)

        invalid = base
        invalid[kCGWindowOwnerPID as String] = NSNumber(
            value: hostProcessID
        )
        #expect(ApplicationWindowListFilter(
            excludedProcessIDs: excludedProcessIDs,
            isRegularApplication: { _ in true }
        ).entry(invalid) == nil)

        invalid = base
        invalid[kCGWindowSharingState as String] = NSNumber(value: 0)
        #expect(filter.entry(invalid) == nil)

        invalid = base
        invalid.removeValue(forKey: kCGWindowSharingState as String)
        #expect(filter.entry(invalid) == nil)

        invalid = base
        invalid[kCGWindowSharingState as String] = "1"
        #expect(filter.entry(invalid) == nil)

        invalid = base
        invalid[kCGWindowAlpha as String] = NSNumber(value: 0)
        #expect(filter.entry(invalid) == nil)

        invalid = base
        invalid[kCGWindowIsOnscreen as String] = false
        #expect(filter.entry(invalid) == nil)

        invalid = base
        invalid[kCGWindowBounds as String] = [
            "X": 10,
            "Y": 20,
            "Width": 0,
            "Height": 600,
        ] as NSDictionary
        #expect(filter.entry(invalid) == nil)

        #expect(ApplicationWindowListFilter(
            excludedProcessIDs: excludedProcessIDs,
            isRegularApplication: { _ in false }
        ).entry(base) == nil)
    }

    @Test func applicationTargetsRejectTheCurrentCmuxProcess() throws {
        let runtime = FakeApplicationSurfaceRuntime()
        #expect(ApplicationPanel(
            workspaceId: UUID(),
            windowID: 42,
            processID: getpid(),
            title: "cmux",
            targetFrameRate: 60,
            runtime: runtime
        ) == nil)

        let panel = try #require(ApplicationPanel(
            workspaceId: UUID(),
            targetFrameRate: 60,
            runtime: runtime
        ))
        panel.selectWindow(ApplicationWindowDescriptor(
            windowID: 42,
            processID: getpid(),
            owner: "cmux",
            title: "cmux",
            width: 800,
            height: 600
        ))
        #expect(panel.captureTarget == nil)
    }

    @Test func applicationPointerDownSynchronizesWorkspaceFocus() throws {
        let runtime = FakeApplicationSurfaceRuntime()
        let workspace = Workspace(applicationSurfaceRuntime: runtime)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let previousPanelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.newApplicationSurface(
            inPane: pane,
            windowID: 42,
            processID: 43,
            title: "Preview",
            focus: false
        ))
        let view = panel.captureView(windowID: 42, processID: 43)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        #expect(workspace.focusedPanelId == previousPanelID)
        view.setInputOwnership(true)
        view.mouseDown(with: event)
        #expect(workspace.focusedPanelId == panel.id)
        panel.close()
    }

    private func applicationPanelContent(
        panel: ApplicationPanel,
        allowsPointerInput: Bool
    ) -> PanelContentView {
        PanelContentView(
            panel: panel,
            workspaceId: panel.workspaceId,
            paneId: PaneID(),
            isFocused: false,
            isSelectedInPane: true,
            isVisibleInUI: true,
            allowsPointerInput: allowsPointerInput,
            portalPriority: 0,
            isSplit: false,
            appearance: PanelAppearance(
                backgroundColor: .windowBackgroundColor,
                foregroundColor: .labelColor,
                dividerColor: Color(nsColor: .separatorColor),
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0,
                usesClearContentBackground: false
            ),
            windowAppearance: .rightSidebarPanelViewTestDefault,
            customSidebarTabManager: nil,
            hasUnreadNotification: false,
            terminalAgentContext: "",
            onFocus: {},
            onRequestPanelFocus: {},
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
    }

    private func firstApplicationCaptureView(
        in view: NSView
    ) -> ApplicationCaptureView? {
        if let captureView = view as? ApplicationCaptureView {
            return captureView
        }
        for subview in view.subviews {
            if let captureView = firstApplicationCaptureView(in: subview) {
                return captureView
            }
        }
        return nil
    }

    private func settleApplicationPanel(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

@MainActor
private final class FakeApplicationSurfaceRuntime: ApplicationSurfaceRuntime {
    var windowListError: (any Error)?

    func acquireApplicationSurfaceLease() async -> ApplicationSurfaceRuntimeLease? {
        nil
    }

    func listApplicationWindows(
        lease: ApplicationSurfaceRuntimeLease
    ) async throws -> [ApplicationWindowDescriptor] {
        if let windowListError {
            throw windowListError
        }
        return []
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

    func acknowledgeApplicationSurfaceAttachment(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async throws {}

    func sendApplicationSurfaceEvent(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String,
        event: ApplicationSurfaceInputEvent
    ) async throws {}
}
