import Foundation
import Testing
@testable import CnxTerminal

@Suite struct AlternateScreenDetectorTests {
    @Test func entersAndLeavesAcrossChunks() {
        var detector = AlternateScreenDetector()
        #expect(detector.scan(Data("hello \u{1B}[?10".utf8)) == nil)
        #expect(detector.scan(Data("49h\u{1B}[H".utf8)) == true)
        #expect(detector.isActive)
        #expect(detector.scan(Data("\u{1B}[?1049l".utf8)) == false)
    }

    @Test func ignoresOtherPrivateModes() {
        var detector = AlternateScreenDetector()
        #expect(detector.scan(Data("\u{1B}[?25l\u{1B}[?2004h".utf8)) == nil)
        #expect(!detector.isActive)
    }
}

@Suite struct ArtifactExtractorTests {
    @Test func findsPathsLinksAndDirectories() {
        var extractor = ArtifactExtractor()
        let text = """
        \u{1B}[1;32m   Compiling\u{1B}[0m serde v1.0.217 (crates.io)
          --> src/link/mux.rs:142:9
           Artifact target/release/cnx-hostd (8.4 MB)
           Report   docs/architecture.md, index.html
           PR https://github.com/manaflow-ai/cmux/pull/1234.
        drwxr-xr-x  aziz staff 4.0K Oct  9 18:22 screenshots
        finished in 48.21s, 2026/10/07

        """
        let found = extractor.scan(Data(text.utf8))
        let byReference = Dictionary(uniqueKeysWithValues: found.map { ($0.reference, $0) })
        #expect(byReference["src/link/mux.rs"]?.kind == .code)
        #expect(byReference["src/link/mux.rs"]?.line == 142)
        #expect(byReference["target/release/cnx-hostd"]?.kind == .binary)
        #expect(byReference["docs/architecture.md"]?.kind == .markdown)
        #expect(byReference["index.html"]?.kind == .html)
        #expect(byReference["https://github.com/manaflow-ai/cmux/pull/1234"]?.kind == .link)
        #expect(byReference["screenshots/"]?.kind == .directory)
        #expect(byReference["v1.0.217"] == nil)
        #expect(byReference["crates.io"] == nil)
        #expect(byReference["48.21s"] == nil)
        #expect(byReference["2026/10/07"] == nil)
    }

    @Test func reportsEachReferenceOnceAndKeepsPartialLines() {
        var extractor = ArtifactExtractor()
        #expect(extractor.scan(Data("see READ".utf8)).isEmpty)
        #expect(extractor.scan(Data("ME.md\n".utf8)).map(\.reference) == ["README.md"])
        #expect(extractor.scan(Data("README.md again\n".utf8)).isEmpty)
    }
}

#if os(iOS)
@MainActor @Suite struct TerminalScreenLogicTests {
    @Test func joystickGears() {
        #expect(JoystickEngine.gear(for: 4) == 0)
        #expect(JoystickEngine.gear(for: 10) == 1)
        #expect(JoystickEngine.gear(for: 20) == 2)
        #expect(JoystickEngine.gear(for: 30) == 3)
        #expect(JoystickEngine.direction(for: CGSize(width: -12, height: 3)) == .left)
        #expect(JoystickEngine.direction(for: CGSize(width: 2, height: 15)) == .down)
    }

    @Test func frameMatchingPrefersTheExpectedShift() {
        let previous: [UInt64] = [0, 1, 2, 3, 4, 5, 6, 7, 0, 0]
        let moved: [UInt64] = [3, 4, 5, 6, 7, 0, 0, 0, 0, 0]
        #expect(TerminalViewController.matchScore(previous, moved, shift: 3) == 1)
        #expect(TerminalViewController.matchScore(previous, moved, shift: 0) == 0)
    }
}
#endif

/// The Mac's 42-row screen on the bottom of a 151-row mirror (offset 109).
@Suite struct TerminalRowShiftTests {
    private func run(_ chunks: [String], offset: Int = 109, rows: Int = 42) -> String {
        var shift = TerminalRowShift()
        return chunks.map { String(decoding: shift.filter(Data($0.utf8), offset: offset, remoteRows: rows), as: UTF8.self) }.joined()
    }

    @Test func replayLandsOnTheBottomRows() {
        // The daemon's replay: reset, history, then the cursor on its row 42.
        let out = run(["\u{1B}c", "1\r\n2\r\n$ ", "\u{1B}[42;30H"])
        #expect(out == "\u{1B}c" + String(repeating: "\n", count: 109) + "1\r\n2\r\n$ \u{1B}[151;30H")
    }

    @Test func rowAddressingShiftsAcrossChunks() {
        #expect(run(["\u{1B}[", "5;", "1H x \u{1B}[H \u{1B}[3d"]) == "\u{1B}[114;1H x \u{1B}[110;1H \u{1B}[112d")
        // Column-only and relative moves are untouched.
        #expect(run(["\u{1B}[5G\u{1B}[2A\u{1B}[K"]) == "\u{1B}[5G\u{1B}[2A\u{1B}[K")
    }

    @Test func alternateScreenIsNotShifted() {
        let out = run(["\u{1B}[?1049h\u{1B}[1;1Hvim\u{1B}[42;1H", "\u{1B}[?1049l\u{1B}[42;1H"])
        #expect(out == "\u{1B}[?1049h\u{1B}[1;1Hvim\u{1B}[42;1H\u{1B}[?1049l\u{1B}7\u{1B}[r\u{1B}8\u{1B}[151;1H")
        // vim's region for its 42 rows stays as is on the alternate screen; leaving resets it.
        #expect(run(["\u{1B}[?1049h\u{1B}[1;42r", "\u{1B}[?1049l"]) == "\u{1B}[?1049h\u{1B}[1;42r\u{1B}[?1049l\u{1B}7\u{1B}[r\u{1B}8")
    }

    @Test func fullScreenRegionKeepsTheScrollback() {
        #expect(run(["\u{1B}[1;42r"]) == "\u{1B}[r")
        #expect(run(["\u{1B}[r"]) == "\u{1B}[r")
        #expect(run(["\u{1B}[2;10r"]) == "\u{1B}[111;119r")
    }

    @Test func stringsPassThrough() {
        let osc = "\u{1B}]7;file://host/Users/x[1;1H\u{07}\u{1B}]2;t\u{1B}\\\u{1B}[1;1H"
        #expect(run([osc]) == "\u{1B}]7;file://host/Users/x[1;1H\u{07}\u{1B}]2;t\u{1B}\\\u{1B}[110;1H")
        #expect(run(["\u{1B}[1;1H"], offset: 0) == "\u{1B}[1;1H")
        #expect(run(["\u{1B}(B\u{1B}[?25l"]) == "\u{1B}(B\u{1B}[?25l")
    }
}
