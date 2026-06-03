import XCTest
@testable import cmux_DEV

final class GhosttySurfaceContractTests: XCTestCase {
    func testGhosttySurfaceForwardsDaemonOutputBytesUnchanged() {
        let stream = Data([0x63, 0x6D, 0x75, 0x78, 0x0D, 0x0A, 0x25, 0x0A, 0xCE, 0xBB])

        let forwarded = GhosttySurfaceView.forwardDaemonOutputBytes(stream)

        XCTAssertEqual(
            forwarded,
            stream,
            "iOS must not rewrite daemon VT bytes before handing them to Ghostty."
        )
    }

    func testGhosttySurfaceShowsBottomOfInitialReplay() async throws {
        let surfaceView = try await MainActor.run {
            let (surfaceView, _) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
            surfaceView.layoutIfNeeded()
            return surfaceView
        }

        let renderedExpectation = expectation(description: "initial replay rendered at bottom")
        renderedExpectation.assertForOverFulfill = false
        await MainActor.run {
            surfaceView.onOutputProcessedForTesting = {
                let rendered = surfaceView.renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT) ?? ""
                if rendered.contains("lawrence in / λ") {
                    renderedExpectation.fulfill()
                }
            }
            let lines = (1...80).map { String(format: "replay line %03d\r\n", $0) }.joined()
            surfaceView.processOutput(Data("\(lines)lawrence in / λ ".utf8))
        }

        await fulfillment(of: [renderedExpectation], timeout: 2.0)
        let rendered = await MainActor.run {
            surfaceView.renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT) ?? ""
        }

        XCTAssertTrue(rendered.contains("lawrence in / λ"))
        XCTAssertFalse(
            rendered.contains("replay line 001"),
            "Initial replay should land at the active bottom, not the top of scrollback: \(rendered)"
        )
    }

    func testGhosttySurfaceReportsGridSizeAfterLayout() async throws {
        let (_, delegate) = try await MainActor.run {
            let (surfaceView, delegate) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 480, height: 320)
            surfaceView.layoutIfNeeded()
            return (surfaceView, delegate)
        }

        let size = try await MainActor.run {
            try XCTUnwrap(delegate.lastSize)
        }
        XCTAssertGreaterThan(size.columns, 0)
        XCTAssertGreaterThan(size.rows, 0)
    }

    func testGhosttySurfaceReportsFullBoundsAsNaturalCapacityWhenKeyboardHidden() async throws {
        let (snapshot, size) = try await MainActor.run {
            let (surfaceView, delegate) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            surfaceView.layoutIfNeeded()
            return (
                surfaceView.debugGeometrySnapshotForTesting(),
                try XCTUnwrap(delegate.lastSize)
            )
        }

        XCTAssertEqual(snapshot.renderRect.width, snapshot.boundsSize.width, accuracy: 0.5)
        XCTAssertEqual(snapshot.renderRect.height, snapshot.boundsSize.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(
            size.pixelHeight,
            Int((snapshot.boundsSize.height * snapshot.screenScale).rounded(.down)) - 1,
            "The hidden keyboard accessory must not subtract rows from this device's reported natural capacity."
        )
    }

    func testGhosttySurfaceKeepsRenderedGridAboveKeyboardAccessory() async throws {
        let (closedSnapshot, openSnapshot, closedSize, openSize) = try await MainActor.run {
            let (surfaceView, delegate) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            surfaceView.layoutIfNeeded()
            let closedSnapshot = surfaceView.debugGeometrySnapshotForTesting()
            let closedSize = try XCTUnwrap(delegate.lastSize)

            surfaceView.setKeyboardHeightForTesting(220)
            surfaceView.layoutIfNeeded()

            return (
                closedSnapshot,
                surfaceView.debugGeometrySnapshotForTesting(),
                closedSize,
                try XCTUnwrap(delegate.lastSize)
            )
        }

        XCTAssertEqual(openSnapshot.renderRect.height, 480, accuracy: 1)
        XCTAssertLessThan(openSnapshot.renderRect.height, closedSnapshot.renderRect.height)
        XCTAssertLessThan(openSize.rows, closedSize.rows)
        XCTAssertLessThanOrEqual(
            openSize.pixelHeight,
            Int((openSnapshot.renderRect.height * openSnapshot.screenScale).rounded(.down)) + 1
        )
    }

    func testGhosttySurfaceReassertsNaturalSizeWhenEffectiveGridIsSmaller() async throws {
        let (natural, reportedSizes) = try await MainActor.run {
            let (surfaceView, delegate) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            surfaceView.layoutIfNeeded()
            let natural = try XCTUnwrap(delegate.lastSize)

            surfaceView.applyViewSize(
                cols: max(1, natural.columns - 4),
                rows: max(1, natural.rows - 4)
            )
            surfaceView.focusInput()

            return (natural, delegate.reportedSizes)
        }

        XCTAssertGreaterThanOrEqual(reportedSizes.count, 2)
        XCTAssertEqual(reportedSizes.last?.columns, natural.columns)
        XCTAssertEqual(reportedSizes.last?.rows, natural.rows)
    }

    func testGhosttySurfaceFillsContainerWhenEffectiveGridIsWithinOneCellOfNaturalCapacity() async throws {
        let snapshot = try await MainActor.run {
            let (surfaceView, delegate) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            surfaceView.layoutIfNeeded()
            let natural = try XCTUnwrap(delegate.lastSize)
            surfaceView.applyViewSize(
                cols: max(1, natural.columns - 1),
                rows: natural.rows
            )
            surfaceView.layoutIfNeeded()
            return surfaceView.debugGeometrySnapshotForTesting()
        }

        XCTAssertEqual(snapshot.renderRect.width, snapshot.boundsSize.width, accuracy: 0.5)
        XCTAssertEqual(snapshot.renderRect.height, snapshot.boundsSize.height, accuracy: 0.5)
    }

    func testGhosttySurfacePinsRenderedGridToEffectiveGrid() async throws {
        let (snapshot, targetColumns, targetRows) = try await MainActor.run {
            let (surfaceView, delegate) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            surfaceView.layoutIfNeeded()
            let natural = try XCTUnwrap(delegate.lastSize)
            let targetColumns = max(1, natural.columns - 4)
            let targetRows = natural.rows

            surfaceView.applyViewSize(cols: targetColumns, rows: targetRows)
            surfaceView.layoutIfNeeded()

            return (
                surfaceView.debugGeometrySnapshotForTesting(),
                targetColumns,
                targetRows
            )
        }

        let renderedSize = try XCTUnwrap(snapshot.renderedSize)
        XCTAssertEqual(renderedSize.columns, targetColumns)
        XCTAssertEqual(renderedSize.rows, targetRows)
    }

    func testGhosttySurfaceShowsVisibleBoundsAroundConstrainedGrid() async throws {
        let snapshot = try await MainActor.run {
            let (surfaceView, delegate) = try makeSurfaceView()
            surfaceView.frame = CGRect(x: 0, y: 0, width: 820, height: 900)
            surfaceView.layoutIfNeeded()
            let natural = try XCTUnwrap(delegate.lastSize)

            surfaceView.applyViewSize(
                cols: max(1, natural.columns - 12),
                rows: max(1, natural.rows - 8)
            )
            surfaceView.layoutIfNeeded()

            return surfaceView.debugGeometrySnapshotForTesting()
        }

        XCTAssertTrue(snapshot.isLetterboxBorderVisible)
        let borderPathBounds = try XCTUnwrap(snapshot.letterboxBorderPathBounds)
        XCTAssertGreaterThanOrEqual(borderPathBounds.minX, 0)
        XCTAssertGreaterThanOrEqual(borderPathBounds.minY, 0)
        XCTAssertLessThanOrEqual(borderPathBounds.maxX, snapshot.boundsSize.width)
        XCTAssertLessThanOrEqual(borderPathBounds.maxY, snapshot.boundsSize.height)
        XCTAssertEqual(borderPathBounds.width, snapshot.renderRect.width, accuracy: 2)
        XCTAssertEqual(borderPathBounds.height, snapshot.renderRect.height, accuracy: 2)
    }

    func testGhosttySurfaceEmitsOutboundBytesForTypedText() async throws {
        let (surfaceView, delegate) = try await MainActor.run {
            try makeSurfaceView()
        }

        let dataExpectation = expectation(description: "ghostty surface emitted typed bytes")
        await MainActor.run {
            delegate.onInput = { data in
                if data == Data("a".utf8) {
                    dataExpectation.fulfill()
                }
            }
        }

        await MainActor.run {
            surfaceView.simulateTextInputForTesting("a")
        }

        await fulfillment(of: [dataExpectation], timeout: 2.0)
    }

    func testShowOnScreenKeyboardActionFocusesTargetSurface() async throws {
        let (surfaceView, _) = try await MainActor.run {
            try makeSurfaceView()
        }

        let focusExpectation = expectation(description: "show keyboard action focuses target surface")
        await MainActor.run {
            surfaceView.onFocusInputRequestedForTesting = {
                focusExpectation.fulfill()
            }
        }

        let handled = try await MainActor.run {
            let surface = try XCTUnwrap(surfaceView.surface)
            return GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: surface,
                tag: GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD
            )
        }

        XCTAssertTrue(handled)
        await fulfillment(of: [focusExpectation], timeout: 2.0)
    }

    func testCopyTitleActionWritesCurrentSurfaceTitleToClipboard() async throws {
        let (surfaceView, _) = try await MainActor.run {
            try makeSurfaceView()
        }

        let recorder = await MainActor.run { ClipboardRecorder() }
        await MainActor.run {
            GhosttyRuntime.setClipboardHandlersForTesting(
                reader: { Optional<String>.none },
                writer: { value in
                    recorder.value = value
                }
            )
        }
        defer {
            Task { @MainActor in
                GhosttyRuntime.resetClipboardHandlersForTesting()
            }
        }

        let handled = try await MainActor.run {
            let surface = try XCTUnwrap(surfaceView.surface)
            XCTAssertTrue(
                GhosttyRuntime.simulateSurfaceSetTitleActionForTesting(
                    surface: surface,
                    title: "deploy terminal"
                )
            )
            return GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: surface,
                tag: GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD
            )
        }

        XCTAssertTrue(handled)
        let copiedValue = await MainActor.run { recorder.value }
        XCTAssertEqual(copiedValue, "deploy terminal")
    }

    func testRingBellActionPostsSurfaceBellNotification() async throws {
        let (surfaceView, _) = try await MainActor.run {
            try makeSurfaceView()
        }

        let bellExpectation = expectation(description: "ring bell action posts surface notification")
        let observer = await MainActor.run {
            NotificationCenter.default.addObserver(
                forName: .ghosttySurfaceDidRingBell,
                object: surfaceView,
                queue: .main
            ) { _ in
                bellExpectation.fulfill()
            }
        }
        defer {
            Task { @MainActor in
                NotificationCenter.default.removeObserver(observer)
            }
        }

        let handled = try await MainActor.run {
            let surface = try XCTUnwrap(surfaceView.surface)
            return GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: surface,
                tag: GHOSTTY_ACTION_RING_BELL
            )
        }

        XCTAssertTrue(handled)
        await fulfillment(of: [bellExpectation], timeout: 2.0)
    }

    @MainActor
    private func makeSurfaceView() throws -> (GhosttySurfaceView, GhosttySurfaceTestDelegate) {
        let runtime = try GhosttyRuntime.shared()
        let delegate = GhosttySurfaceTestDelegate()
        let surfaceView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        return (surfaceView, delegate)
    }

}

@MainActor
private final class ClipboardRecorder {
    var value: String?
}

@MainActor
private final class GhosttySurfaceTestDelegate: GhosttySurfaceViewDelegate {
    var lastSize: TerminalGridSize?
    var reportedSizes: [TerminalGridSize] = []
    var onInput: ((Data) -> Void)?

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
        onInput?(data)
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
        lastSize = size
        reportedSizes.append(size)
    }
}
