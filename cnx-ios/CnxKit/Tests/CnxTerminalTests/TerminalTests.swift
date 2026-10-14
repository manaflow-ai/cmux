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

    /// e2e-live.md: a path the Mac's grid wrapped arrived as two rows, and the
    /// stream scan listed `/live/work/demo/REA` and `DME.md`.
    @Test func wrappedPathInTheStreamIsTwoFragments() {
        var extractor = ArtifactExtractor()
        let found = extractor.scan(Data("cat /live/work/demo/REA\r\nDME.md\r\n".utf8))
        #expect(found.map(\.reference) == ["/live/work/demo/REA", "DME.md"])
    }

    @Test func rowsThatFillTheWidthJoinTheNextRow() {
        // 20 columns: the first row is full, so the next one continues it.
        let rows = "$ cat /live/work/dem\no/README.md\nshort line\n$ "
        #expect(ArtifactExtractor.logicalLines(in: rows, columns: 20)
            == ["$ cat /live/work/demo/README.md", "short line", "$ "])
        // Without a width, rows are lines as written.
        #expect(ArtifactExtractor.logicalLines(in: rows, columns: nil).count == 4)
        // A full row that ends in a space is a finished line.
        #expect(ArtifactExtractor.logicalLines(in: "abcdefghi \nnext", columns: 10) == ["abcdefghi ", "next"])
        // A full-width rule is a line of its own, so the path after it keeps its start.
        #expect(ArtifactExtractor.logicalLines(in: "----------\n/etc/hosts", columns: 10) == ["----------", "/etc/hosts"])
    }

    @Test func screenTextReplacesWrappedFragments() {
        var extractor = ArtifactExtractor()
        var artifacts = extractor.scan(Data("open docs/a.md\r\ncat /live/work/demo/REA\r\nDME.md\r\nhttps://example.com/lo\r\nng/page\r\n".utf8))
        #expect(artifacts.map(\.reference).contains("/live/work/demo/REA"))
        // Ghostty's screen read joins soft-wrapped rows into one logical line.
        let screen = "open docs/a.md\ncat /live/work/demo/README.md\nhttps://example.com/long/page\n"
        artifacts = extractor.reconcile(artifacts, screenText: screen, columns: nil)
        #expect(artifacts.map(\.reference) == ["docs/a.md", "/live/work/demo/README.md", "https://example.com/long/page"])
        // The whole reference takes its first fragment's place.
        #expect(artifacts.map(\.order) == artifacts.map(\.order).sorted())
        // Later output does not list it again.
        #expect(extractor.scan(Data("ls /live/work/demo/README.md\n".utf8)).isEmpty)
    }

    /// Seen live (round2.md): a command over three rows left its middle row,
    /// `e/r2/live/.../2026-10-13-round2-verifica`, as a folder.
    @Test func aMiddlePieceIsReplacedToo() {
        var extractor = ArtifactExtractor()
        let stream = "ls /Users/cmux/cnx-ios-e2\r\ne/r2/live/work/demo/reports/2026-10-13-round2-verifica\r\ntion/long-folder/x.md\r\n"
        var artifacts = extractor.scan(Data(stream.utf8))
        #expect(artifacts.count == 3)
        artifacts = extractor.reconcile(artifacts, screenText: "ls /Users/cmux/cnx-ios-e2e/r2/live/work/demo/reports/2026-10-13-round2-verification/long-folder/x.md\n", columns: nil)
        #expect(artifacts.map(\.reference) == ["/Users/cmux/cnx-ios-e2e/r2/live/work/demo/reports/2026-10-13-round2-verification/long-folder/x.md"])
    }

    /// R2-7 (seen live): the command line listed the whole path first, then
    /// `ls -l` output wrapped it at 53 columns; the piece `p/cnx-...md` stayed.
    @Test func aPieceOfAPathAlreadyListedWholeGoes() {
        var extractor = ArtifactExtractor()
        let stream = "clear; ls -l /tmp/cnx-e2e-070024-sample.md\r\n-rw-r--r--@ 1 aziz  wheel  40 Oct 14 07:00 /tm\r\np/cnx-e2e-070024-sample.md\r\n"
        var artifacts = extractor.scan(Data(stream.utf8))
        #expect(artifacts.map(\.reference).contains("p/cnx-e2e-070024-sample.md"))
        let screen = "clear; ls -l /tmp/cnx-e2e-070024-sample.md\n-rw-r--r--@ 1 aziz  wheel  40 Oct 14 07:00 /tmp/cnx-e2e-070024-sample.md\n"
        artifacts = extractor.reconcile(artifacts, screenText: screen, columns: nil)
        #expect(artifacts.map(\.reference) == ["/tmp/cnx-e2e-070024-sample.md"])
    }

    /// R3-3 (seen live): pieces of wrapped paths in scrollback, after the
    /// whole path left the screen.
    @Test func fragmentsInScrollbackGo() {
        let list = [
            TerminalArtifact(reference: "/tmp/cnx-e2e-091910.txt", kind: .text),
            TerminalArtifact(reference: "rivate/tmp/cnx-e2e-091910.txt", kind: .text),
            TerminalArtifact(reference: "1910.txt", kind: .text),
            TerminalArtifact(reference: "/tm", kind: .directory),
            TerminalArtifact(reference: "docs/a.md", kind: .markdown),
            TerminalArtifact(reference: "/repo/docs/a.md", kind: .markdown),
            TerminalArtifact(reference: "https://cmux.com/a", kind: .link),
        ]
        #expect(ArtifactExtractor.droppingFragments(list).map(\.reference)
                == ["/tmp/cnx-e2e-091910.txt", "docs/a.md", "/repo/docs/a.md", "https://cmux.com/a"])
    }

    @Test func tmpAndPrivateTmpAreOneEntry() {
        var extractor = ArtifactExtractor()
        let artifacts = extractor.scan(Data("cat /tmp/x.md\nopen /private/tmp/x.md\n".utf8))
        #expect(artifacts.map(\.reference) == ["/tmp/x.md"])
        #expect(ArtifactExtractor.canonical("/private/var/log/a.txt") == "/var/log/a.txt")
        let merged = extractor.reconcile(artifacts, screenText: "open /private/tmp/x.md\n", columns: nil)
        #expect(merged.map(\.reference) == ["/tmp/x.md"])
    }

    @Test func reconcileKeepsHistoryThatLeftTheScreen() {
        var extractor = ArtifactExtractor()
        let artifacts = extractor.scan(Data("old/notes.md\n".utf8))
        let merged = extractor.reconcile(artifacts, screenText: "new/plan.md\n", columns: nil)
        #expect(merged.map(\.reference) == ["old/notes.md", "new/plan.md"])
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
