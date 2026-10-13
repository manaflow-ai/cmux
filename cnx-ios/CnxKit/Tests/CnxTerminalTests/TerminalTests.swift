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
