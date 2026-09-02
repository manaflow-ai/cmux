import Foundation
import Testing

@Suite struct WelcomeLogoAnimationTests {
    private let renderer = WelcomeLogoFrameRenderer(taglineColor: "\u{001B}[38;2;130;130;140m")

    @Test func frameZeroIsTheCanonicalGradient() {
        let rows = renderer.rows(frameIndex: 0)
        #expect(rows.count == WelcomeLogoFrameRenderer.rowCount)
        for (index, row) in rows.enumerated() {
            // One SGR, then the indented glyphs, exactly like the original static logo.
            #expect(row.hasPrefix(WelcomeLogoFrameRenderer.gradient[index].sgr + WelcomeLogoFrameRenderer.glyphs[index] + WelcomeLogoFrameRenderer.reset))
        }
        #expect(WelcomeLogoFrameRenderer.glyphs == ["  ::", "    ::::", "      ::::::", "        ::::::", "      ::::::", "    ::::", "  ::"])
        #expect(rows[1].contains("\u{001B}[38;2;0;212;255mc\u{001B}[38;2;24;181;250mm\u{001B}[38;2;48;150;245mu\u{001B}[38;2;124;58;237mx"))
        #expect(rows[3].contains("the open source terminal"))
        #expect(rows[4].contains("built for coding agents"))
    }

    @Test func pulseTravelsLeftToRightAndLeavesTheLogoCanonical() {
        let frames = WelcomeLogoFrameRenderer.frameCount
        #expect(frames > 0)
        #expect(renderer.rows(frameIndex: frames) == renderer.rows(frameIndex: 0))
        #expect(renderer.rows(frameIndex: frames + 5) == renderer.rows(frameIndex: 0))

        // Column 1 (row 0's single pair) is disturbed before column 6 (row 3's last pair).
        func firstShiftedFrame(column: Int) -> Int? {
            (1..<frames).first { WelcomeLogoFrameRenderer.paletteShift(pairColumn: column, frameIndex: $0) > 0 }
        }
        let leftStart = firstShiftedFrame(column: 1)
        let rightStart = firstShiftedFrame(column: 6)
        #expect(leftStart != nil && rightStart != nil)
        #expect(leftStart! < rightStart!)

        // At the pulse center the shift peaks at pulseWidth and falls off with distance.
        let centerFrame = Int((Double(3 + WelcomeLogoFrameRenderer.pulseWidth) / WelcomeLogoFrameRenderer.pulseSpeed).rounded())
        #expect(WelcomeLogoFrameRenderer.paletteShift(pairColumn: 3, frameIndex: centerFrame) == WelcomeLogoFrameRenderer.pulseWidth)
        #expect(WelcomeLogoFrameRenderer.paletteShift(pairColumn: 5, frameIndex: centerFrame) == WelcomeLogoFrameRenderer.pulseWidth - 2)
        #expect(WelcomeLogoFrameRenderer.paletteShift(pairColumn: 3 + WelcomeLogoFrameRenderer.pulseWidth, frameIndex: centerFrame) == 0)

        // Every animated frame differs from the canonical one while the pulse is inside the logo.
        #expect(renderer.rows(frameIndex: centerFrame) != renderer.rows(frameIndex: 0))
    }

    @Test func pingPongPaletteHasNoSeam() {
        let palette = WelcomeLogoFrameRenderer.pingPongPalette
        #expect(palette.count == 12)
        #expect(palette.first == WelcomeLogoFrameRenderer.gradient.first)
        #expect(palette[6] == WelcomeLogoFrameRenderer.gradient.last)
        #expect(palette.last == WelcomeLogoFrameRenderer.gradient[1])
    }

    @Test func pairsInOneRowCanCarryDifferentColors() {
        // Mid-pulse, row 2's three pairs sit at different distances from the center.
        let centerFrame = Int((Double(3 + WelcomeLogoFrameRenderer.pulseWidth) / WelcomeLogoFrameRenderer.pulseSpeed).rounded())
        let row = renderer.row(2, frameIndex: centerFrame)
        let sgrCount = row.components(separatedBy: "\u{001B}[38;2;").count - 1
        #expect(sgrCount == 3)
        #expect(row.hasPrefix("\u{001B}[38;2;"))
        #expect(row.hasSuffix(WelcomeLogoFrameRenderer.reset + renderer.trailer(row: 2)))
        // Indent stays after the first SGR and before the first pair.
        #expect(row.contains("m      ::"))
    }

    @Test func staticTextIsIdenticalAcrossFrames() {
        for frame in 0...WelcomeLogoFrameRenderer.frameCount {
            for row in 0..<WelcomeLogoFrameRenderer.rowCount {
                #expect(renderer.row(row, frameIndex: frame).hasSuffix(WelcomeLogoFrameRenderer.reset + renderer.trailer(row: row)))
            }
        }
    }

    @Test func relativeRepaintSequenceIsSelfContainedRelativeToTheSavedCursor() {
        let sequence = WelcomeLogoAnimator.repaintSequence(rows: ["A", "B", "C"], placement: .relative(linesAboveCursor: 10))
        #expect(sequence.hasPrefix("\u{001B}7"))
        #expect(sequence.hasSuffix("\u{001B}8"))
        #expect(sequence.contains("\u{001B}8\u{001B}[10A\r\u{001B}[2KA"))
        #expect(sequence.contains("\u{001B}8\u{001B}[9A\r\u{001B}[2KB"))
        #expect(sequence.contains("\u{001B}8\u{001B}[8A\r\u{001B}[2KC"))
        #expect(!sequence.contains("\n"))
    }

    @Test func absoluteRepaintSequenceAddressesRowsAndRestoresTheCursor() {
        let sequence = WelcomeLogoAnimator.repaintSequence(rows: ["A", "B", "C"], placement: .absolute(topRow: 4))
        #expect(sequence == "\u{001B}7\u{001B}[4;1H\u{001B}[2KA\u{001B}[5;1H\u{001B}[2KB\u{001B}[6;1H\u{001B}[2KC\u{001B}8")
    }

    @Test func shouldAnimateGates() {
        let base = ["TERM": "xterm-256color"]
        #expect(WelcomeLogoAnimator.shouldAnimate(environment: base, isTTY: true, terminalRows: 40, linesAboveCursor: 30))
        #expect(!WelcomeLogoAnimator.shouldAnimate(environment: base, isTTY: false, terminalRows: 40, linesAboveCursor: 30))
        #expect(!WelcomeLogoAnimator.shouldAnimate(environment: base, isTTY: true, terminalRows: nil, linesAboveCursor: 30))
        // Logo top row scrolled off: 30 lines above the cursor need 31 rows.
        #expect(!WelcomeLogoAnimator.shouldAnimate(environment: base, isTTY: true, terminalRows: 30, linesAboveCursor: 30))
        #expect(WelcomeLogoAnimator.shouldAnimate(environment: base, isTTY: true, terminalRows: 31, linesAboveCursor: 30))
        #expect(!WelcomeLogoAnimator.shouldAnimate(environment: ["TERM": "dumb"], isTTY: true, terminalRows: 40, linesAboveCursor: 30))
        #expect(!WelcomeLogoAnimator.shouldAnimate(environment: [:], isTTY: true, terminalRows: 40, linesAboveCursor: 30))
        #expect(!WelcomeLogoAnimator.shouldAnimate(environment: base.merging(["NO_COLOR": "1"]) { $1 }, isTTY: true, terminalRows: 40, linesAboveCursor: 30))
        #expect(!WelcomeLogoAnimator.shouldAnimate(environment: base.merging(["CI": "true"]) { $1 }, isTTY: true, terminalRows: 40, linesAboveCursor: 30))
        #expect(!WelcomeLogoAnimator.shouldAnimate(environment: base.merging(["CMUX_WELCOME_ANIMATE": "0"]) { $1 }, isTTY: true, terminalRows: 40, linesAboveCursor: 30))
        #expect(WelcomeLogoAnimator.shouldAnimate(environment: base.merging(["CMUX_WELCOME_ANIMATE": "1"]) { $1 }, isTTY: true, terminalRows: 40, linesAboveCursor: 30))
    }

    @Test func detachedPlacementNeedsRoomBelowTheCursor() {
        // Cursor on row 40 of 50 with the logo starting 32 rows up.
        #expect(WelcomeLogoAnimator.detachedPlacement(cursorRow: 40, linesAboveCursor: 32, terminalRows: 50) == .absolute(topRow: 8))
        // Exactly at the scroll margin is still fine.
        #expect(WelcomeLogoAnimator.detachedPlacement(cursorRow: 48, linesAboveCursor: 32, terminalRows: 50) == .absolute(topRow: 16))
        // A prompt newline could scroll the logo: refuse.
        #expect(WelcomeLogoAnimator.detachedPlacement(cursorRow: 49, linesAboveCursor: 32, terminalRows: 50) == nil)
        #expect(WelcomeLogoAnimator.detachedPlacement(cursorRow: 50, linesAboveCursor: 32, terminalRows: 50) == nil)
        // Logo top above the screen: refuse.
        #expect(WelcomeLogoAnimator.detachedPlacement(cursorRow: 20, linesAboveCursor: 32, terminalRows: 50) == nil)
    }

    @Test func parsesCursorPositionReports() {
        #expect(WelcomeLogoAnimator.parseCursorReportRow(Array("\u{001B}[34;1R".utf8)) == 34)
        #expect(WelcomeLogoAnimator.parseCursorReportRow(Array("\u{001B}[7;120R".utf8)) == 7)
        // Typeahead before the report is ignored.
        #expect(WelcomeLogoAnimator.parseCursorReportRow(Array("ls\u{001B}[12;1R".utf8)) == 12)
        // Incomplete reports are not a result yet.
        #expect(WelcomeLogoAnimator.parseCursorReportRow(Array("\u{001B}[12;".utf8)) == nil)
        #expect(WelcomeLogoAnimator.parseCursorReportRow(Array("\u{001B}[12;1".utf8)) == nil)
        #expect(WelcomeLogoAnimator.parseCursorReportRow(Array("\u{001B}[".utf8)) == nil)
        // Other CSI sequences are not reports.
        #expect(WelcomeLogoAnimator.parseCursorReportRow(Array("\u{001B}[1;1H".utf8)) == nil)
        #expect(WelcomeLogoAnimator.parseCursorReportRow(Array("\u{001B}[?1;2c".utf8)) == nil)
    }

    @Test func queryCursorRowReturnsNilWithoutATerminal() {
        var fds = [Int32](repeating: -1, count: 2)
        #expect(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        #expect(WelcomeLogoAnimator.queryCursorRow(inputFD: fds[0], outputFD: fds[1], timeout: 0.05) == nil)
    }

    @Test func renderLoopWritesEveryFrameThenTheCanonicalFrame() {
        let placement = WelcomeLogoAnimator.Placement.relative(linesAboveCursor: 20)
        let animator = WelcomeLogoAnimator(
            renderer: renderer,
            configuration: .init(frameCount: 5, frameInterval: 0.01, placement: placement)
        )
        var writes: [String] = []
        var sleeps: [TimeInterval] = []
        animator.renderLoop(
            write: { writes.append($0); return true },
            sleep: { sleeps.append($0) },
            isCancelled: { false }
        )
        #expect(sleeps == Array(repeating: 0.01, count: 5))
        #expect(writes.count == 6)
        for frame in 1...5 {
            #expect(writes[frame - 1] == WelcomeLogoAnimator.repaintSequence(rows: renderer.rows(frameIndex: frame), placement: placement))
        }
        #expect(writes.last == WelcomeLogoAnimator.repaintSequence(rows: renderer.rows(frameIndex: 0), placement: placement))
    }

    @Test func defaultConfigurationEndsOnTheCanonicalFrame() {
        let configuration = WelcomeLogoAnimator.Configuration(placement: .absolute(topRow: 3))
        #expect(configuration.frameCount == WelcomeLogoFrameRenderer.frameCount - 1)
        #expect(configuration.duration < 1.5)
        // The frame after the last animated one is canonical, so the final paint is seamless.
        #expect(renderer.rows(frameIndex: configuration.frameCount + 1) == renderer.rows(frameIndex: 0))
    }

    @Test func cancellationStopsEarlyButStillRestoresTheCanonicalFrame() {
        let placement = WelcomeLogoAnimator.Placement.absolute(topRow: 5)
        let animator = WelcomeLogoAnimator(
            renderer: renderer,
            configuration: .init(frameCount: 50, frameInterval: 0.01, placement: placement)
        )
        var writes: [String] = []
        var ticks = 0
        animator.renderLoop(
            write: { writes.append($0); return true },
            sleep: { _ in ticks += 1 },
            isCancelled: { ticks >= 3 }
        )
        #expect(ticks == 3)
        // Frames 1 and 2 were painted, frame 3 was cancelled after its sleep.
        #expect(writes.count == 3)
        #expect(writes.last == WelcomeLogoAnimator.repaintSequence(rows: renderer.rows(frameIndex: 0), placement: placement))
    }

    @Test func writerFailureStopsWithoutFurtherWrites() {
        let animator = WelcomeLogoAnimator(
            renderer: renderer,
            configuration: .init(frameCount: 10, frameInterval: 0.01, placement: .relative(linesAboveCursor: 20))
        )
        var writes = 0
        animator.renderLoop(
            write: { _ in writes += 1; return writes < 2 },
            sleep: { _ in },
            isCancelled: { false }
        )
        #expect(writes == 2)
    }

    @Test func startRendersOnABackgroundThreadAndSignalsCompletion() {
        let animator = WelcomeLogoAnimator(
            renderer: renderer,
            configuration: .init(frameCount: 3, frameInterval: 0.001, placement: .relative(linesAboveCursor: 20))
        )
        let lock = NSLock()
        var offMainWrites = 0
        var totalWrites = 0
        let handle = animator.start(
            write: { _ in
                lock.lock()
                defer { lock.unlock() }
                totalWrites += 1
                if !Thread.isMainThread { offMainWrites += 1 }
                return true
            },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
        #expect(handle.wait(timeout: 5))
        lock.lock()
        defer { lock.unlock() }
        #expect(totalWrites == 4)
        #expect(offMainWrites == 4)
    }

    @Test func handleCancelStopsARunningAnimation() {
        let animator = WelcomeLogoAnimator(
            renderer: renderer,
            configuration: .init(frameCount: 10_000, frameInterval: 0.001, placement: .relative(linesAboveCursor: 20))
        )
        let lock = NSLock()
        var writes = 0
        let handle = animator.start(
            write: { _ in
                lock.lock()
                writes += 1
                lock.unlock()
                return true
            },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
        #expect(!handle.wait(timeout: 0.05))
        handle.cancel()
        #expect(handle.wait(timeout: 5))
        lock.lock()
        defer { lock.unlock() }
        #expect(writes < 10_001)
        #expect(writes >= 1)
    }

    @Test func writeAllWritesTheWholeStringToAPipe() throws {
        var fds = [Int32](repeating: -1, count: 2)
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]) }
        let text = String(repeating: "x", count: 4096) + "\u{001B}[0m"
        #expect(WelcomeLogoAnimator.writeAll(fd: fds[1], text))
        close(fds[1])
        var buffer = [UInt8](repeating: 0, count: 8192)
        var received = Data()
        while true {
            let count = read(fds[0], &buffer, buffer.count)
            if count <= 0 { break }
            received.append(buffer, count: count)
        }
        #expect(received == Data(text.utf8))
    }
}
