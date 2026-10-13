import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Status bar line parsing")
struct BottomStatusBarRunTests {
    @Test func plainTextIsOneUnstyledRun() {
        #expect(BottomStatusBarRun.parse("5h 52%") == [BottomStatusBarRun(text: "5h 52%")])
    }

    @Test func truecolorAndResetSplitRuns() {
        let runs = BottomStatusBarRun.parse("\u{1b}[38;2;250;179;135mClaude\u{1b}[0m 52%")
        #expect(runs == [
            BottomStatusBarRun(text: "Claude", color: .rgb(250, 179, 135)),
            BottomStatusBarRun(text: " 52%"),
        ])
    }

    @Test func boldDimAndPaletteColors() {
        let runs = BottomStatusBarRun.parse("\u{1b}[1;31mhot\u{1b}[22;2;94mcold")
        #expect(runs == [
            BottomStatusBarRun(text: "hot", color: .palette(1), bold: true),
            BottomStatusBarRun(text: "cold", color: .palette(12), dim: true),
        ])
    }

    /// OSC 8 may end with ESC \ or BEL, and an SGR reset inside the link must
    /// not close it.
    @Test func hyperlinksSurviveResetsAndBothTerminators() {
        let line = "\u{1b}]8;;cmux-action:codex\u{1b}\\\u{1b}[34mCodex\u{1b}[0m!\u{1b}]8;;\u{07} rest"
        #expect(BottomStatusBarRun.parse(line) == [
            BottomStatusBarRun(text: "Codex", color: .palette(4), link: "cmux-action:codex"),
            BottomStatusBarRun(text: "!", link: "cmux-action:codex"),
            BottomStatusBarRun(text: " rest"),
        ])
    }

    @Test func linkTargetKeepsSemicolonsAndParameters() {
        let runs = BottomStatusBarRun.parse("\u{1b}]8;id=a;https://example.com/a;b\u{1b}\\x\u{1b}]8;;\u{1b}\\")
        #expect(runs == [BottomStatusBarRun(text: "x", link: "https://example.com/a;b")])
    }

    @Test func otherEscapesAndControlCharactersAreDropped() {
        let runs = BottomStatusBarRun.parse("\u{1b}[2K\u{1b}]0;title\u{07}a\u{1b}[48;2;1;2;3mb\u{08}\u{1b}=c")
        #expect(runs == [BottomStatusBarRun(text: "abc")])
    }

    @Test func truncatedSequencesDoNotCrash() {
        #expect(BottomStatusBarRun.parse("ok\u{1b}[38;2;1") == [BottomStatusBarRun(text: "ok")])
        #expect(BottomStatusBarRun.parse("ok\u{1b}") == [BottomStatusBarRun(text: "ok")])
        #expect(BottomStatusBarRun.parse("\u{1b}]8;;https://x") == [])
    }
}

@MainActor
@Suite("Status bar command feed")
struct BottomStatusBarFeedTests {
    /// Waits for the feed to show `expected`, up to `seconds`; returns what it shows then.
    private func shownText(_ feed: BottomStatusBarFeed, expecting expected: String, seconds: Double = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if feed.runs.map(\.text).joined() == expected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return feed.runs.map(\.text).joined()
    }

    @Test func lastLineWithoutNewlineIsShownWhenTheCommandExits() async throws {
        let feed = BottomStatusBarFeed()
        defer { feed.run("") }
        feed.run("printf 'first\\nlast'")
        #expect(try await shownText(feed, expecting: "last") == "last")
    }

    @Test func oneShotCommandWithoutNewlineIsNotReportedAsSilent() async throws {
        let feed = BottomStatusBarFeed()
        defer { feed.run("") }
        feed.run("printf only")
        #expect(try await shownText(feed, expecting: "only") == "only")
    }
}
