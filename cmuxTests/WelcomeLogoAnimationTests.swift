import Foundation
import Testing

@Suite struct WelcomeLogoAnimationTests {
    private let renderer = WelcomeLogoFrameRenderer(taglineColor: "\u{001B}[38;2;130;130;140m")

    @Test func frameZeroIsTheCanonicalGradient() {
        let rows = renderer.rows(frameIndex: 0)
        #expect(rows.count == WelcomeLogoFrameRenderer.rowCount)
        for (index, row) in rows.enumerated() {
            #expect(row.hasPrefix(WelcomeLogoFrameRenderer.gradient[index].sgr + WelcomeLogoFrameRenderer.glyphs[index]))
        }
        #expect(rows[1].contains("\u{001B}[38;2;0;212;255mc\u{001B}[38;2;24;181;250mm\u{001B}[38;2;48;150;245mu\u{001B}[38;2;124;58;237mx"))
        #expect(rows[3].contains("the open source terminal"))
        #expect(rows[4].contains("built for coding agents"))
    }

    @Test func waveFlowsUpwardAndLoopsWithoutASeam() {
        let palette = WelcomeLogoFrameRenderer.pingPongPalette
        #expect(palette.count == 12)
        #expect(palette.first == WelcomeLogoFrameRenderer.gradient.first)
        #expect(palette[6] == WelcomeLogoFrameRenderer.gradient.last)
        #expect(palette.last == WelcomeLogoFrameRenderer.gradient[1])

        // Row 0 at frame 1 takes row 1's frame-0 color.
        #expect(WelcomeLogoFrameRenderer.color(row: 0, frameIndex: 1) == WelcomeLogoFrameRenderer.color(row: 1, frameIndex: 0))
        // A full cycle returns to the canonical gradient.
        let cycle = WelcomeLogoFrameRenderer.cycleLength
        #expect(renderer.rows(frameIndex: cycle) == renderer.rows(frameIndex: 0))
        #expect(renderer.rows(frameIndex: 2 * cycle) == renderer.rows(frameIndex: 0))
        #expect(renderer.rows(frameIndex: 1) != renderer.rows(frameIndex: 0))
    }

    @Test func staticTextIsIdenticalAcrossFrames() {
        for frame in 0..<WelcomeLogoFrameRenderer.cycleLength {
            for row in 0..<WelcomeLogoFrameRenderer.rowCount {
                #expect(renderer.row(row, frameIndex: frame).hasSuffix(WelcomeLogoFrameRenderer.reset + renderer.trailer(row: row)))
            }
        }
    }

    @Test func repaintSequenceIsSelfContainedRelativeToTheSavedCursor() {
        let rows = ["A", "B", "C"]
        let sequence = WelcomeLogoAnimator.repaintSequence(rows: rows, linesAboveCursor: 10)
        #expect(sequence.hasPrefix("\u{001B}7"))
        #expect(sequence.hasSuffix("\u{001B}8"))
        #expect(sequence.contains("\u{001B}8\u{001B}[10A\r\u{001B}[2KA"))
        #expect(sequence.contains("\u{001B}8\u{001B}[9A\r\u{001B}[2KB"))
        #expect(sequence.contains("\u{001B}8\u{001B}[8A\r\u{001B}[2KC"))
        #expect(!sequence.contains("\n"))
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

    @Test func renderLoopWritesEveryFrameThenTheCanonicalFrame() {
        let animator = WelcomeLogoAnimator(
            renderer: renderer,
            configuration: .init(frameCount: 5, frameInterval: 0.01, linesAboveCursor: 20)
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
            #expect(writes[frame - 1] == WelcomeLogoAnimator.repaintSequence(rows: renderer.rows(frameIndex: frame), linesAboveCursor: 20))
        }
        #expect(writes.last == WelcomeLogoAnimator.repaintSequence(rows: renderer.rows(frameIndex: 0), linesAboveCursor: 20))
    }

    @Test func cancellationStopsEarlyButStillRestoresTheCanonicalFrame() {
        let animator = WelcomeLogoAnimator(
            renderer: renderer,
            configuration: .init(frameCount: 50, frameInterval: 0.01, linesAboveCursor: 20)
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
        #expect(writes.last == WelcomeLogoAnimator.repaintSequence(rows: renderer.rows(frameIndex: 0), linesAboveCursor: 20))
    }

    @Test func writerFailureStopsWithoutFurtherWrites() {
        let animator = WelcomeLogoAnimator(
            renderer: renderer,
            configuration: .init(frameCount: 10, frameInterval: 0.01, linesAboveCursor: 20)
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
            configuration: .init(frameCount: 3, frameInterval: 0.001, linesAboveCursor: 20)
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
            configuration: .init(frameCount: 10_000, frameInterval: 0.001, linesAboveCursor: 20)
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
