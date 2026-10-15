import CnxArtifacts
import CoreGraphics
import Foundation
import Testing
@testable import CnxTerminal

/// The per-frame output queue: bounded work per frame, order kept,
/// backpressure thresholds (verify/terminal-flood.md).
@Suite struct TerminalOutputQueueTests {
    @Test func manyChunksBecomeOneBatchPerFrame() {
        var queue = TerminalOutputQueue()
        for index in 0..<500 { queue.append(Data("line \(index)\r\n".utf8)) }
        let total = queue.pendingBytes
        guard case .bytes(let batch)? = queue.next(budget: 1 << 20) else { Issue.record("no batch"); return }
        #expect(batch.count == total)
        #expect(String(decoding: batch, as: UTF8.self).hasPrefix("line 0\r\nline 1\r\n"))
        #expect(queue.isEmpty)
        #expect(queue.next() == nil)
    }

    @Test func eachFrameTakesAtMostTheBudgetInOrder() {
        var queue = TerminalOutputQueue()
        var expected = Data()
        for index in 0..<100 {
            let chunk = Data(repeating: UInt8(index), count: 1000)
            expected.append(chunk)
            queue.append(chunk)
        }
        var out = Data()
        var frames = 0
        while case .bytes(let batch)? = queue.next(budget: 4096) {
            #expect(batch.count <= 4096)
            out.append(batch)
            frames += 1
        }
        #expect(out == expected)
        #expect(frames == 25)
        #expect(queue.pendingBytes == 0)
    }

    @Test func alternateScreenSwitchWaitsForTheBytesBeforeIt() {
        var queue = TerminalOutputQueue()
        queue.append(Data("before".utf8))
        queue.append(alternateScreen: true)
        queue.append(Data("after".utf8))
        #expect(queue.next(budget: 3) == .bytes(Data("bef".utf8)))
        #expect(queue.next(budget: 100) == .bytes(Data("ore".utf8)))
        #expect(queue.next() == .alternateScreen(true))
        #expect(queue.next() == .bytes(Data("after".utf8)))
        #expect(queue.next() == nil)
    }

    @Test func highAndLowWater() {
        var queue = TerminalOutputQueue()
        queue.append(Data(count: TerminalOutputQueue.highWater + 1))
        #expect(queue.isOverHighWater)
        #expect(!queue.isUnderLowWater)
        while queue.pendingBytes >= TerminalOutputQueue.lowWater { _ = queue.next() }
        #expect(queue.isUnderLowWater)
    }
}

/// Typing brings the prompt back; output never yanks a reader who scrolled up.
@Suite struct TerminalFollowPolicyTests {
    @Test func outputKeepsTheBottomPinnedWhileFollowing() {
        var policy = TerminalFollowPolicy()
        #expect(policy.documentResized(offsetY: 100, maxOffsetY: 400, userIsScrolling: false) == 400)
        // Never while the finger is on the scroll view.
        #expect(policy.documentResized(offsetY: 100, maxOffsetY: 400, userIsScrolling: true) == nil)
    }

    @Test func outputDoesNotMoveAReaderWhoScrolledUp() {
        var policy = TerminalFollowPolicy()
        policy.userScrolled(offsetY: 100, maxOffsetY: 2000, rowHeight: 17)
        #expect(!policy.following)
        #expect(policy.documentResized(offsetY: 100, maxOffsetY: 2400, userIsScrolling: false) == nil)
        #expect(!policy.following)
    }

    @Test func typingJumpsToThePromptAndFollowsAgain() {
        var policy = TerminalFollowPolicy()
        policy.userScrolled(offsetY: 100, maxOffsetY: 2000, rowHeight: 17)
        #expect(policy.input(isTUI: false, offsetY: 100, maxOffsetY: 2000) == 2000)
        #expect(policy.following)
        // Already at the bottom: nothing to move.
        #expect(policy.input(isTUI: false, offsetY: 2000, maxOffsetY: 2000) == nil)
        // A TUI owns its screen.
        policy.userScrolled(offsetY: 0, maxOffsetY: 2000, rowHeight: 17)
        #expect(policy.input(isTUI: true, offsetY: 0, maxOffsetY: 2000) == nil)
    }

    @Test func clearedScrollbackFollowsAgain() {
        var policy = TerminalFollowPolicy()
        policy.userScrolled(offsetY: 100, maxOffsetY: 2000, rowHeight: 17)
        policy.scrollbackChanged(from: 900, to: 950, screenRows: 150)
        #expect(!policy.following)
        // Ghostty trimming old pages at the scrollback limit (or a reflow) is not a clear.
        policy.scrollbackChanged(from: 50_000, to: 49_200, screenRows: 150)
        #expect(!policy.following)
        policy.scrollbackChanged(from: 950, to: 150, screenRows: 150) // clear (ESC [3J)
        #expect(policy.following)
    }

    @Test func aDocumentEndingAboveTheScreenSnapsBack() {
        // Scrolled up, then the document shrank under the place on screen
        // (only blank rows would show there): back to the bottom.
        var policy = TerminalFollowPolicy()
        policy.userScrolled(offsetY: 1500, maxOffsetY: 3000, rowHeight: 17)
        #expect(policy.documentResized(offsetY: 1500, maxOffsetY: 200, userIsScrolling: false) == 200)
        #expect(policy.following)
    }
}

@Suite struct UserInputTests {
    @Test func onlyWhatThePersonTypedCounts() {
        #expect(TerminalInputAction.text("a").isUserInput)
        #expect(TerminalInputAction.paste("ls\n").isUserInput)
        #expect(!TerminalInputAction.preedit("ka").isUserInput)
        #expect(!TerminalInputAction.text("").isUserInput)
        var router = TerminalInputRouter()
        let actions = router.key(usage: TerminalHIDUsage.up, extra: [])
        #expect(actions.contains { $0.isUserInput })
        #expect(actions.filter(\.isUserInput).count == actions.filter { if case .key(let e) = $0 { e.isPress } else { false } }.count)
    }
}

@Suite struct KeyBarClippingTests {
    @Test func keysWhoseCenterIsUnderThePinnedGroupOrPastTheEndAreHidden() {
        let clipping = KeyBarClipping()
        let visible = CGRect(x: 120, y: 0, width: 200, height: 44) // scrolled by 120
        #expect(clipping.isActivatable(CGRect(x: 130, y: 0, width: 40, height: 34), in: visible))
        // Cut at the leading edge, center showing: a tap at its center hits it.
        #expect(clipping.isActivatable(CGRect(x: 110, y: 0, width: 40, height: 34), in: visible))
        #expect(!clipping.isActivatable(CGRect(x: 90, y: 0, width: 40, height: 34), in: visible)) // under esc/ctrl/alt
        #expect(!clipping.isActivatable(CGRect(x: 310, y: 0, width: 40, height: 34), in: visible)) // under the joystick
        #expect(clipping.isActivatable(CGRect(x: 0, y: 0, width: 40, height: 34), in: nil))
    }
}

@MainActor @Suite struct TerminalArtifactCollectorTests {
    @Test func scansOffTheMainThreadAndPublishesInOrder() async {
        var published: [[TerminalArtifact]] = []
        let collector = TerminalArtifactCollector { published.append($0) }
        collector.scan(Data("open docs/a.md\r\n".utf8))
        collector.scan(Data("see https://example.com/x and src/b.rs\r\nnothing here\r\n".utf8))
        await collector.flush()
        #expect(published.last?.map(\.reference) == ["docs/a.md", "https://example.com/x", "src/b.rs"])
        // A line split across batches is one reference.
        collector.scan(Data("cat lib/c".utf8))
        collector.scan(Data(".swift\r\n".utf8))
        await collector.flush()
        #expect(published.last?.last?.reference == "lib/c.swift")
    }

    @Test func reconcileJoinsAPathTheStreamSawInPieces() async {
        var published: [[TerminalArtifact]] = []
        let collector = TerminalArtifactCollector { published.append($0) }
        collector.scan(Data("cat /live/work/demo/REA\r\nDME.md\r\n".utf8))
        collector.reconcile(screenText: "cat /live/work/demo/README.md\n", columns: nil)
        await collector.flush()
        #expect(published.last?.map(\.reference).contains("/live/work/demo/README.md") == true)
    }
}
