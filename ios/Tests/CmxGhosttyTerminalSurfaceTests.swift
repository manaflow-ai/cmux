import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import cmux_ios

@MainActor
final class CmxGhosttyTerminalSurfaceTests: XCTestCase {
    nonisolated(unsafe) private var surfaceViews: [SurfaceViewTeardownHandle] = []

    override func tearDown() {
        let handles = surfaceViews
        surfaceViews = []
        MainActor.assumeIsolated {
            for handle in handles {
                handle.dispose()
            }
        }
        super.tearDown()
    }

    func testGhosttySurfaceForwardsPtyBytesUnchanged() {
        let stream = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x63, 0x6D, 0x75, 0x78, 0x0D, 0x0A])

        let forwarded = GhosttyTerminalSurfaceView.forwardTerminalOutputBytes(stream)

        XCTAssertEqual(forwarded, stream)
    }

    func testGhosttySurfaceDetectsStateReplacementOutputForActiveAreaScroll() {
        XCTAssertTrue(GhosttyTerminalSurfaceView.shouldForceScrollToActiveAreaForOutput(Data([0x1B, 0x63])))
        XCTAssertTrue(GhosttyTerminalSurfaceView.shouldForceScrollToActiveAreaForOutput(Data("\u{1B}[?1049h".utf8)))
        XCTAssertTrue(GhosttyTerminalSurfaceView.shouldForceScrollToActiveAreaForOutput(Data("\u{1B}[?1049l".utf8)))
        XCTAssertFalse(GhosttyTerminalSurfaceView.shouldForceScrollToActiveAreaForOutput(Data("ordinary pty output".utf8)))
    }

    func testGhosttySurfaceDoesNotProbeBlankReplayAfterResetOnlyChunk() {
        XCTAssertFalse(
            GhosttyTerminalSurfaceView.shouldProbeBlankSurfaceAfterOutput(
                Data([0x1B, 0x63]),
                accessibilityText: ""
            )
        )
        XCTAssertFalse(
            GhosttyTerminalSurfaceView.shouldProbeBlankSurfaceAfterOutput(
                Data("\u{1B}creplayed content\r\n".utf8),
                accessibilityText: "replayed content\n"
            )
        )
        XCTAssertFalse(
            GhosttyTerminalSurfaceView.shouldProbeBlankSurfaceAfterOutput(
                Data("live output\r\n".utf8),
                accessibilityText: "live output\n"
            )
        )
        XCTAssertTrue(
            GhosttyTerminalSurfaceView.shouldProbeBlankSurfaceAfterOutput(
                Data("\u{1B}[2J\u{1B}[H".utf8),
                accessibilityText: ""
            )
        )
        XCTAssertTrue(
            GhosttyTerminalSurfaceView.shouldProbeBlankSurfaceAfterOutput(
                Data("\u{1B}[?1049h\u{1B}[2J\u{1B}[H".utf8),
                accessibilityText: ""
            )
        )
    }

    func testGhosttySurfaceInitializesRealLibghosttyRenderer() throws {
        let (surfaceView, _) = try makeSurfaceView()

        XCTAssertNotNil(surfaceView.surface)
        XCTAssertTrue(surfaceView.layer is CAMetalLayer)
    }

    func testGhosttySurfaceRendersAnsiOutput() async throws {
        let (surfaceView, _) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let renderedExpectation = expectation(description: "Ghostty rendered PTY output")
        renderedExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
            if rendered.contains("cmux-color") {
                renderedExpectation.fulfill()
            }
        }

        surfaceView.processOutput(Data("\u{1B}[31mcmux-color\u{1B}[0m\r\n".utf8))

        await fulfillment(of: [renderedExpectation], timeout: 5.0)
        XCTAssertTrue((surfaceView.accessibilityRenderedTextForTesting() ?? "").contains("cmux-color"))
    }

    func testGhosttySurfaceAccessibilityValueTracksPtyTranscriptWithoutAnsi() async throws {
        let (surfaceView, _) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let accessibilityExpectation = expectation(description: "Ghostty surfaced PTY text to accessibility")
        accessibilityExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let value = surfaceView.accessibilityValue ?? ""
            if value.contains("ui-test$") && value.contains("typed output") {
                accessibilityExpectation.fulfill()
            }
        }

        surfaceView.processOutput(Data("\u{1B}[38;2;166;226;46mui-test$ \u{1B}[0mtyped output\r\n".utf8))

        await fulfillment(of: [accessibilityExpectation], timeout: 5.0)
        let value = try XCTUnwrap(surfaceView.accessibilityValue)
        XCTAssertTrue(value.contains("ui-test$"))
        XCTAssertTrue(value.contains("typed output"))
        XCTAssertFalse(value.contains("[38;2"))
    }

    func testGhosttySurfaceCoalescesSingleBytePtyChunksInOrder() async throws {
        let (surfaceView, _) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let renderedExpectation = expectation(description: "Ghostty rendered coalesced PTY output")
        renderedExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
            if rendered.contains("coalesced-output") {
                renderedExpectation.fulfill()
            }
        }

        for byte in Data("coalesced-output\r\n".utf8) {
            surfaceView.processOutput(Data([byte]))
        }

        await fulfillment(of: [renderedExpectation], timeout: 5.0)
        XCTAssertTrue((surfaceView.accessibilityRenderedTextForTesting() ?? "").contains("coalesced-output"))
    }

    func testGhosttySurfaceKeepsViewportPinnedToLiveOutput() async throws {
        let (surfaceView, _) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
        surfaceView.layoutIfNeeded()
        surfaceView.applyViewSize(cols: 30, rows: 8)

        let bottomMarker = "LIVE_BOTTOM_AFTER_OUTPUT"
        let renderedExpectation = expectation(description: "Ghostty viewport followed live output")
        renderedExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let viewport = surfaceView.renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT) ?? ""
            if viewport.contains(bottomMarker) {
                renderedExpectation.fulfill()
            }
        }

        let history = (0..<40)
            .map { "scrollback-line-\($0)" }
            .joined(separator: "\r\n")
        surfaceView.processOutput(Data((history + "\r\n").utf8))
        surfaceView.processOutput(Data((bottomMarker + "\r\n").utf8))

        await fulfillment(of: [renderedExpectation], timeout: 5.0)
        let viewport = surfaceView.renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT) ?? ""
        XCTAssertTrue(viewport.contains(bottomMarker))
    }

    func testGhosttySurfaceEmitsOutboundBytesForTypedText() async throws {
        let (surfaceView, delegate) = try makeSurfaceView()

        let inputExpectation = expectation(description: "Ghostty emitted typed input")
        delegate.onInput = { data in
            if data == Data("a".utf8) {
                inputExpectation.fulfill()
            }
        }

        surfaceView.simulateTextInputForTesting("a")

        await fulfillment(of: [inputExpectation], timeout: 2.0)
    }

    func testGhosttyAccessoryBarEmitsModifierSequences() throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        var inputs: [Data] = []
        delegate.onInput = { data in
            inputs.append(data)
        }

        surfaceView.simulateAccessoryActionForTesting(.control)
        surfaceView.simulateTextInputForTesting("c")
        surfaceView.simulateAccessoryActionForTesting(.alternate)
        surfaceView.simulateAccessoryActionForTesting(.leftArrow)
        surfaceView.updateHostPlatform(.macOS)
        surfaceView.simulateAccessoryActionForTesting(.command)
        surfaceView.simulateAccessoryActionForTesting(.rightArrow)

        XCTAssertEqual(inputs, [
            Data([0x03]),
            Data([0x1B, 0x62]),
            Data([0x05]),
        ])
    }

    func testGhosttyAccessoryBarExposesFullTerminalActionSet() {
        let actions = Set(TerminalInputAccessoryAction.allCases)

        XCTAssertTrue(actions.isSuperset(of: [
            .hideKeyboard,
            .control,
            .alternate,
            .command,
            .shift,
            .escape,
            .tab,
            .enter,
            .backspace,
            .deleteForward,
            .upArrow,
            .downArrow,
            .leftArrow,
            .rightArrow,
            .home,
            .end,
            .pageUp,
            .pageDown,
            .tilde,
            .pipe,
            .ctrlC,
            .ctrlD,
            .ctrlZ,
            .ctrlL,
        ]))
    }

    func testGhosttyAccessoryBarKeepsActionsInsideScrollerAndShowsMacCommand() throws {
        let (surfaceView, _) = try makeSurfaceView()
        let defaultIdentifiers = Set(surfaceView.accessoryActionIdentifiersForTesting)

        XCTAssertTrue(defaultIdentifiers.isSuperset(of: [
            "terminal.inputAccessory.hideKeyboard",
            "terminal.inputAccessory.control",
            "terminal.inputAccessory.alt",
            "terminal.inputAccessory.shift",
            "terminal.inputAccessory.zoomOut",
            "terminal.inputAccessory.zoomIn",
            "terminal.inputAccessory.escape",
            "terminal.inputAccessory.tab",
            "terminal.inputAccessory.enter",
            "terminal.inputAccessory.backspace",
            "terminal.inputAccessory.deleteForward",
            "terminal.inputAccessory.up",
            "terminal.inputAccessory.down",
            "terminal.inputAccessory.left",
            "terminal.inputAccessory.right",
            "terminal.inputAccessory.claude",
            "terminal.inputAccessory.codex",
            "terminal.inputAccessory.home",
            "terminal.inputAccessory.end",
            "terminal.inputAccessory.pageUp",
            "terminal.inputAccessory.pageDown",
            "terminal.inputAccessory.tilde",
            "terminal.inputAccessory.pipe",
            "terminal.inputAccessory.ctrlC",
            "terminal.inputAccessory.ctrlD",
            "terminal.inputAccessory.ctrlZ",
            "terminal.inputAccessory.ctrlL",
        ]))
        XCTAssertFalse(defaultIdentifiers.contains("terminal.inputAccessory.command"))

        surfaceView.updateHostPlatform(.macOS)

        XCTAssertTrue(surfaceView.accessoryActionIdentifiersForTesting.contains("terminal.inputAccessory.command"))
    }

    func testGhosttyAccessoryChromeTracksTerminalColumnInsideWideKeyboard() {
        let frame = TerminalAccessoryChromeLayout.frame(
            sourceFrame: CGRect(x: 432, y: 92, width: 936, height: 1200),
            accessoryFrame: CGRect(x: 0, y: 1320, width: 1368, height: 44),
            accessoryBounds: CGRect(x: 0, y: 0, width: 1368, height: 44)
        )

        XCTAssertEqual(frame, CGRect(x: 432, y: 0, width: 936, height: 44))
    }

    func testGhosttyFontZoomClampsRepeatedGesturesToMobileBounds() async throws {
        let (surfaceView, _) = try makeSurfaceView()
        let appliedExpectation = expectation(description: "Ghostty applied final clamped font size")
        surfaceView.onFontZoomAppliedForTesting = { fontSize in
            if fontSize == 30 {
                appliedExpectation.fulfill()
            }
        }

        for _ in 0..<100 {
            _ = surfaceView.simulateFontZoomForTesting(.decrease)
        }
        let minimum = surfaceView.fontSizeForTesting
        XCTAssertFalse(surfaceView.simulateFontZoomForTesting(.decrease))

        for _ in 0..<100 {
            _ = surfaceView.simulateFontZoomForTesting(.increase)
        }
        let maximum = surfaceView.fontSizeForTesting
        XCTAssertFalse(surfaceView.simulateFontZoomForTesting(.increase))
        XCTAssertGreaterThanOrEqual(minimum, 9)
        XCTAssertLessThanOrEqual(maximum, 30)
        await fulfillment(of: [appliedExpectation], timeout: 5.0)
    }

    func testGhosttyPinchZoomAppliesWhileGestureIsStillChanging() async throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        let appliedExpectation = expectation(description: "Ghostty applied live pinch zoom")
        surfaceView.onFontZoomAppliedForTesting = { fontSize in
            if fontSize == 18 {
                appliedExpectation.fulfill()
            }
        }
        delegate.resizeCount = 0

        surfaceView.simulateLivePinchZoomStepForTesting([.increase])
        surfaceView.simulateLivePinchZoomStepForTesting([.increase])

        await fulfillment(of: [appliedExpectation], timeout: 5.0)
        XCTAssertNotNil(delegate.lastSize)
        XCTAssertGreaterThan(delegate.resizeCount, 0)
        XCTAssertEqual(surfaceView.fontSizeForTesting, 18)
        XCTAssertFalse(surfaceView.isDisplayLinkActiveForTesting)
    }

    func testGhosttyPinchZoomStaysResponsiveAfterRepeatedRenderedZooms() async throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let renderedExpectation = expectation(description: "Ghostty rendered before repeated zoom")
        renderedExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
            if rendered.contains("zoom-test$") {
                renderedExpectation.fulfill()
            }
        }
        surfaceView.processOutput(Data("zoom-test$ ".utf8))
        await fulfillment(of: [renderedExpectation], timeout: 5.0)

        let zoomExpectation = expectation(description: "Ghostty drained coalesced repeated zooms without blocking input")
        zoomExpectation.assertForOverFulfill = false
        surfaceView.onFontZoomQueueDrainedForTesting = {
            zoomExpectation.fulfill()
        }
        for _ in 0..<32 {
            surfaceView.simulatePinchZoomCycleForTesting([.decrease])
            surfaceView.simulatePinchZoomCycleForTesting([.increase])
        }
        await fulfillment(of: [zoomExpectation], timeout: 5.0)

        let inputExpectation = expectation(description: "Ghostty accepted input after repeated zoom")
        delegate.onInput = { data in
            if data == Data("x".utf8) {
                inputExpectation.fulfill()
            }
        }
        surfaceView.simulateTextInputForTesting("x")

        await fulfillment(of: [inputExpectation], timeout: 2.0)
        XCTAssertEqual(surfaceView.fontSizeForTesting, 16)
        XCTAssertFalse(surfaceView.isDisplayLinkActiveForTesting)
    }

    func testGhosttySurfaceCanResetAndReplayBufferedOutput() async throws {
        let (surfaceView, _) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let replayedExpectation = expectation(description: "Ghostty replayed output after surface reset")
        replayedExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
            if rendered.contains("replayed-after-reset") {
                replayedExpectation.fulfill()
            }
        }

        surfaceView.resetAndReplayOutput([
            Data("\u{1B}[2J\u{1B}[Hreplayed-after-reset\r\n".utf8),
        ])

        await fulfillment(of: [replayedExpectation], timeout: 5.0)
        XCTAssertTrue((surfaceView.accessibilityRenderedTextForTesting() ?? "").contains("replayed-after-reset"))
    }

    func testGhosttySurfaceResetDropsQueuedOutputBeforeReplay() async throws {
        let (surfaceView, _) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let replayedExpectation = expectation(description: "Ghostty ignored stale pending output")
        replayedExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
            if rendered.contains("fresh-after-reset") {
                replayedExpectation.fulfill()
            }
        }

        surfaceView.processOutput(Data("stale-before-reset\r\n".utf8))
        surfaceView.resetAndReplayOutput([
            Data("\u{1B}[2J\u{1B}[Hfresh-after-reset\r\n".utf8),
        ])

        await fulfillment(of: [replayedExpectation], timeout: 5.0)
        let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
        XCTAssertTrue(rendered.contains("fresh-after-reset"))
        XCTAssertFalse(rendered.contains("stale-before-reset"))
        let accessibilityValue = surfaceView.accessibilityValue ?? ""
        XCTAssertTrue(accessibilityValue.contains("fresh-after-reset"))
        XCTAssertFalse(accessibilityValue.contains("stale-before-reset"))
    }

    func testGhosttySurfaceBlankReplayRequestsPtyReplayWithoutSurfaceReset() async throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let processedExpectation = expectation(description: "Ghostty processed blank PTY output")
        processedExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            processedExpectation.fulfill()
        }

        surfaceView.processOutput(Data("\u{1B}[2J\u{1B}[H".utf8))

        await fulfillment(of: [processedExpectation], timeout: 5.0)
        XCTAssertEqual(delegate.surfaceResetRequestCount, 0)
        XCTAssertEqual(delegate.ptyReplayRequestCount, 1)
    }

    func testGhosttySurfaceBlankOutputRequestsReplayWithoutSurfaceResetAfterRender() async throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let processedExpectation = expectation(description: "Ghostty processed blank alternate-screen output")
        processedExpectation.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            processedExpectation.fulfill()
        }

        surfaceView.processOutput(Data("\u{1B}[?1049h\u{1B}[2J\u{1B}[H".utf8))

        await fulfillment(of: [processedExpectation], timeout: 5.0)
        XCTAssertEqual(delegate.surfaceResetRequestCount, 0)
        XCTAssertEqual(delegate.ptyReplayRequestCount, 1)
    }

    func testGhosttySurfaceCanForceInitialGridReportAfterCoordinatorBinding() throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()
        delegate.lastSize = nil

        surfaceView.reportCurrentGridSize()

        XCTAssertNotNil(delegate.lastSize)
        XCTAssertGreaterThan(delegate.lastSize?.columns ?? 0, 0)
        XCTAssertGreaterThan(delegate.lastSize?.rows ?? 0, 0)
    }

    func testGhosttySurfaceTerminalReuseReportsCurrentGridSize() throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()
        delegate.lastSize = nil

        surfaceView.resetForTerminalReuse()

        XCTAssertNotNil(delegate.lastSize)
        XCTAssertGreaterThan(delegate.lastSize?.columns ?? 0, 0)
        XCTAssertGreaterThan(delegate.lastSize?.rows ?? 0, 0)
    }

    func testRemoteConfigOverrideRefreshesSurfaceBackground() throws {
        let (surfaceView, _) = try makeSurfaceView()
        defer { _ = GhosttyRuntime.applyRemoteConfigOverride(nil) }

        XCTAssertTrue(GhosttyRuntime.applyRemoteConfigOverride("background = #010203\n"))

        XCTAssertEqual(surfaceView.backgroundColor?.cmuxRGB255, [1, 2, 3])
    }

    func testRemoteConfigOverrideReportsVisibleSurfaceGeometry() throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        defer { _ = GhosttyRuntime.applyRemoteConfigOverride(nil) }
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()
        delegate.lastSize = nil

        XCTAssertTrue(GhosttyRuntime.applyRemoteConfigOverride("font-size = 12\n"))

        XCTAssertNotNil(delegate.lastSize)
        XCTAssertGreaterThan(delegate.lastSize?.columns ?? 0, 0)
        XCTAssertGreaterThan(delegate.lastSize?.rows ?? 0, 0)
    }

    func testMaximumViewportGridSizeIgnoresForcedRenderClamp() throws {
        let (surfaceView, _) = try makeSurfaceView()
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        surfaceView.applyViewSize(cols: 20, rows: 10)
        let maximum = try XCTUnwrap(surfaceView.maximumViewportGridSize())

        XCTAssertGreaterThan(maximum.columns, 20)
        XCTAssertGreaterThan(maximum.rows, 10)
    }

    func testConnectedSurfaceAttachRendersCachedBacklogAndRequestsFreshReplay() async throws {
        let sessionFactory = SurfaceAttachRecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            terminalSessionFactory: sessionFactory,
            startHiveDiscoveryOnInit: false,
            launchTicket: nil,
            launchAutoconnect: false
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """
        store.connect()
        let session = sessionFactory.session
        session.delegate?.terminalSession(session, didReceive: .welcome(serverVersion: "3", sessionID: "ios-test"))
        session.delegate?.terminalSession(session, didReceive: .nativeSnapshot(Self.singleTabSnapshot(tabID: 41)))
        store.terminalScreenDidAppear()
        session.clearRequestedPtyReplays()
        session.delegate?.terminalSession(
            session,
            didReceive: .ptyBytes(tabID: 41, data: Data("stale-before-attach\r\n".utf8))
        )

        var visibleGridSize: TerminalGridSize?
        var surfaceResetNonce = 0
        let coordinator = CmxGhosttyTerminalView.Coordinator(
            visibleGridSize: Binding(
                get: { visibleGridSize },
                set: { visibleGridSize = $0 }
            ),
            surfaceResetNonce: Binding(
                get: { surfaceResetNonce },
                set: { surfaceResetNonce = $0 }
            )
        )
        let surfaceView = GhosttyTerminalSurfaceView(runtime: try GhosttyRuntime.shared(), delegate: coordinator)
        surfaceViews.append(SurfaceViewTeardownHandle(surfaceView))
        surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        surfaceView.layoutIfNeeded()

        let cachedBacklogRendered = expectation(description: "cached backlog rendered")
        cachedBacklogRendered.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
            if rendered.contains("stale-before-attach") {
                cachedBacklogRendered.fulfill()
            }
        }

        coordinator.apply(store: store, terminalID: 41, renderSize: nil, hostPlatform: .macOS, to: surfaceView)

        await fulfillment(of: [cachedBacklogRendered], timeout: 5.0)
        XCTAssertTrue((surfaceView.accessibilityRenderedTextForTesting() ?? "").contains("stale-before-attach"))
        XCTAssertEqual(session.requestedPtyReplayTerminalIDs.last, 41)
        XCTAssertFalse(session.requestedPtyReplayTerminalIDs.isEmpty)
        let freshReplayRendered = expectation(description: "fresh replay rendered")
        freshReplayRendered.assertForOverFulfill = false
        surfaceView.onOutputProcessedForTesting = {
            let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
            if rendered.contains("fresh-after-attach") {
                freshReplayRendered.fulfill()
            }
        }
        session.delegate?.terminalSession(
            session,
            didReceive: .ptyBytes(tabID: 41, data: Data("fresh-after-attach\r\n".utf8))
        )

        await fulfillment(of: [freshReplayRendered], timeout: 5.0)
        let rendered = surfaceView.accessibilityRenderedTextForTesting() ?? ""
        XCTAssertTrue(rendered.contains("fresh-after-attach"))
    }

    func testCoordinatorResizeDoesNotRequestSurfaceReset() throws {
        let sessionFactory = SurfaceAttachRecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            terminalSessionFactory: sessionFactory,
            startHiveDiscoveryOnInit: false,
            launchTicket: nil,
            launchAutoconnect: false
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """
        store.connect()
        let session = sessionFactory.session
        session.delegate?.terminalSession(session, didReceive: .welcome(serverVersion: "3", sessionID: "ios-test"))
        session.delegate?.terminalSession(session, didReceive: .nativeSnapshot(Self.singleTabSnapshot(tabID: 41)))
        store.terminalScreenDidAppear()

        var visibleGridSize: TerminalGridSize?
        var surfaceResetNonce = 0
        let coordinator = CmxGhosttyTerminalView.Coordinator(
            visibleGridSize: Binding(
                get: { visibleGridSize },
                set: { visibleGridSize = $0 }
            ),
            surfaceResetNonce: Binding(
                get: { surfaceResetNonce },
                set: { surfaceResetNonce = $0 }
            )
        )
        let surfaceView = GhosttyTerminalSurfaceView(runtime: try GhosttyRuntime.shared(), delegate: coordinator)
        surfaceViews.append(SurfaceViewTeardownHandle(surfaceView))

        coordinator.apply(store: store, terminalID: 41, renderSize: nil, hostPlatform: .macOS, to: surfaceView)
        coordinator.ghosttyTerminalSurfaceView(
            surfaceView,
            didResize: TerminalGridSize(columns: 30, rows: 25, pixelWidth: 900, pixelHeight: 1_200)
        )

        XCTAssertEqual(surfaceResetNonce, 0)
        XCTAssertEqual(visibleGridSize, TerminalGridSize(columns: 30, rows: 25, pixelWidth: 900, pixelHeight: 1_200))
    }

    private func makeSurfaceView() throws -> (GhosttyTerminalSurfaceView, DelegateRecorder) {
        let delegate = DelegateRecorder()
        let runtime = try GhosttyRuntime.shared()
        let surfaceView = GhosttyTerminalSurfaceView(runtime: runtime, delegate: delegate)
        surfaceViews.append(SurfaceViewTeardownHandle(surfaceView))
        return (surfaceView, delegate)
    }

    private static func singleTabSnapshot(tabID: UInt64) -> CmxNativeSnapshot {
        CmxNativeSnapshot(
            workspaces: [
                CmxNativeWorkspaceInfo(
                    id: 11,
                    title: "main",
                    spaceCount: 1,
                    tabCount: 1,
                    terminalCount: 1,
                    pinned: false,
                    color: nil
                ),
            ],
            activeWorkspace: 0,
            activeWorkspaceID: 11,
            spaces: [
                CmxNativeSpaceInfo(id: 21, title: "space-1", paneCount: 1, terminalCount: 1),
            ],
            activeSpace: 0,
            activeSpaceID: 21,
            panels: .leaf(
                panelID: 31,
                tabs: [
                    CmxNativeTabInfo(id: tabID, title: "shell", hasActivity: false, bellCount: 0),
                ],
                active: 0,
                activeTabID: tabID
            ),
            focusedPanelID: 31,
            focusedTabID: tabID
        )
    }
}

private struct SurfaceViewTeardownHandle: @unchecked Sendable {
    private let surfaceView: GhosttyTerminalSurfaceView

    init(_ surfaceView: GhosttyTerminalSurfaceView) {
        self.surfaceView = surfaceView
    }

    @MainActor
    func dispose() {
        surfaceView.disposeSurface()
    }
}

@MainActor
private final class DelegateRecorder: GhosttyTerminalSurfaceViewDelegate {
    var onInput: ((Data) -> Void)?
    var lastSize: TerminalGridSize?
    var resizeCount = 0
    var surfaceResetRequestCount = 0
    var ptyReplayRequestCount = 0

    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didProduceInput data: Data) {
        onInput?(data)
    }

    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didResize size: TerminalGridSize) {
        lastSize = size
        resizeCount += 1
    }

    func ghosttyTerminalSurfaceViewDidRequestSurfaceReset(_ surfaceView: GhosttyTerminalSurfaceView) {
        surfaceResetRequestCount += 1
    }

    func ghosttyTerminalSurfaceViewDidRequestPtyReplay(_ surfaceView: GhosttyTerminalSurfaceView) {
        ptyReplayRequestCount += 1
    }
}

@MainActor
private final class SurfaceAttachRecordingTerminalSessionFactory: CmxTerminalSessionMaking {
    let session = SurfaceAttachRecordingTerminalSession()

    func makeSession(
        rawTicket: String,
        ticket: CmxBridgeTicket,
        pairingSecret: String?,
        stackAuthSession: CmxStackAuthSession?
    ) throws -> any CmxTerminalSession {
        session
    }
}

@MainActor
private final class SurfaceAttachRecordingTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?
    private(set) var requestedPtyReplayTerminalIDs: [UInt64] = []

    func start(viewport: CmxWireViewport) {}
    func sendInput(_ data: Data, terminalID: UInt64) {}
    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64) {}
    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport]) {}
    func sendCommand(_ command: CmxClientCommand) {}
    func disconnect() {}

    func requestPtyReplay(terminalID: UInt64) {
        requestedPtyReplayTerminalIDs.append(terminalID)
    }

    func clearRequestedPtyReplays() {
        requestedPtyReplayTerminalIDs = []
    }
}

private extension UIColor {
    var cmuxRGB255: [Int]? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return [red, green, blue].map { Int(($0 * 255).rounded()) }
    }
}
