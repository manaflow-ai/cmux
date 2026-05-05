import QuartzCore
import UIKit
import XCTest
@testable import cmux_ios

@MainActor
final class CmxGhosttyTerminalSurfaceTests: XCTestCase {
    private var surfaceViews: [GhosttyTerminalSurfaceView] = []

    override func tearDown() {
        for surfaceView in surfaceViews {
            surfaceView.disposeSurface()
        }
        surfaceViews = []
        super.tearDown()
    }

    func testGhosttySurfaceForwardsPtyBytesUnchanged() {
        let stream = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x63, 0x6D, 0x75, 0x78, 0x0D, 0x0A])

        let forwarded = GhosttyTerminalSurfaceView.forwardTerminalOutputBytes(stream)

        XCTAssertEqual(forwarded, stream)
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

    func testGhosttyPinchZoomCoalescesGeometrySyncUntilGestureEnd() async throws {
        let (surfaceView, delegate) = try makeSurfaceView()
        let appliedExpectation = expectation(description: "Ghostty applied coalesced pinch zoom")
        surfaceView.onFontZoomAppliedForTesting = { fontSize in
            if fontSize == 24 {
                appliedExpectation.fulfill()
            }
        }
        delegate.resizeCount = 0

        surfaceView.simulatePinchZoomCycleForTesting(Array(repeating: .increase, count: 8))
        surfaceView.simulatePinchZoomCycleForTesting([.decrease, .increase])

        await fulfillment(of: [appliedExpectation], timeout: 5.0)
        XCTAssertNotNil(delegate.lastSize)
        XCTAssertEqual(delegate.resizeCount, 1)
        XCTAssertEqual(surfaceView.fontSizeForTesting, 24)
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

        let zoomExpectation = expectation(description: "Ghostty applied repeated zooms without blocking input")
        surfaceView.onFontZoomAppliedForTesting = { fontSize in
            if fontSize == 16 {
                zoomExpectation.fulfill()
            }
        }
        delegate.resizeCount = 0
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
        XCTAssertGreaterThan(delegate.resizeCount, 0)
        XCTAssertEqual(surfaceView.fontSizeForTesting, 16)
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

    private func makeSurfaceView() throws -> (GhosttyTerminalSurfaceView, DelegateRecorder) {
        let delegate = DelegateRecorder()
        let runtime = try GhosttyRuntime.shared()
        let surfaceView = GhosttyTerminalSurfaceView(runtime: runtime, delegate: delegate)
        surfaceViews.append(surfaceView)
        return (surfaceView, delegate)
    }
}

@MainActor
private final class DelegateRecorder: GhosttyTerminalSurfaceViewDelegate {
    var onInput: ((Data) -> Void)?
    var lastSize: TerminalGridSize?
    var resizeCount = 0

    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didProduceInput data: Data) {
        onInput?(data)
    }

    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didResize size: TerminalGridSize) {
        lastSize = size
        resizeCount += 1
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
