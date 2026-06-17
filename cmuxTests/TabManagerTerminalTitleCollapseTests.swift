import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the sidebar-freeze caused by CLI tools that update
/// the terminal title on every animation frame with a leading braille spinner
/// glyph (pnpm, npm, cargo, codex, …). The frame-by-frame title churn used to
/// flood the panel-title coalescer and toolbar command-text updater and starve
/// sidebar hit-testing. The fix collapses such titles to a stable form so the
/// redundant frames dedupe instead of re-driving the main thread (issue #6291).
@Suite struct TabManagerTerminalTitleCollapseTests {

    /// A sequence of spinner frames whose only difference is the leading braille
    /// glyph must collapse to a single stable panel title, so consecutive frames
    /// are deduplicated rather than each driving a panel-title mutation.
    @Test func testCodexSpinnerTerminalTitlesCollapseToStablePanelTitle() {
        let spinnerFrames = [
            "⠋ codex: building",
            "⠙ codex: building",
            "⠹ codex: building",
            "⠸ codex: building",
            "⠼ codex: building",
            "⠴ codex: building",
            "⠦ codex: building",
            "⠧ codex: building",
            "⠇ codex: building",
            "⠏ codex: building",
        ]

        let stableTitles = spinnerFrames.map { TabManager.stableTerminalPanelTitle($0) }
        let distinct = Set(stableTitles)

        #expect(distinct == ["codex: building"])
        #expect(stableTitles.allSatisfy { $0 == "codex: building" })
    }

    /// A title with no leading spinner glyph is only whitespace-trimmed, never
    /// otherwise mutated.
    @Test func testNonSpinnerTitleIsPreservedExceptForTrimming() {
        #expect(TabManager.stableTerminalPanelTitle("  pnpm install  ") == "pnpm install")
        #expect(TabManager.stableTerminalPanelTitle("zsh") == "zsh")
        // A leading hyphen/letter is real title text and must survive intact.
        #expect(TabManager.stableTerminalPanelTitle("- my project") == "- my project")
    }

    /// Frames that differ in their trailing (non-spinner) text remain distinct,
    /// so genuine title changes still propagate.
    @Test func testDistinctTrailingTextRemainsDistinct() {
        #expect(
            TabManager.stableTerminalPanelTitle("⠋ pnpm install")
                != TabManager.stableTerminalPanelTitle("⠙ pnpm build")
        )
    }

    /// Behavior-level coverage of the #6291 repro: a long stream of spinner
    /// frames must result in only ONE effective title update once dedup runs.
    ///
    /// Both dedup layers key off the same value and the same equality: the
    /// source-level guard (`GhosttyNSView.lastPublishedTerminalTitle != stable`)
    /// and the coalescer guard (`pendingPanelTitleUpdates[key] == trimmed`) each
    /// compare the *collapsed* title against the last one and drop it when
    /// unchanged. This replays that shared predicate over the real
    /// `stableTerminalPanelTitle` to assert the flood collapses to a single
    /// publish — the property that stops sidebar hit-testing from being starved.
    /// (The guards themselves are `private`/AppKit-bound, so this exercises the
    /// production collapse function plus the exact dedup rule rather than the
    /// UI wiring.)
    @Test func testSpinnerStreamYieldsSingleEffectiveTitleUpdate() {
        // 120 frames cycling every braille glyph, same trailing text — exactly
        // the pnpm/cargo/codex churn that froze the sidebar.
        let glyphs = Array(TabManager.terminalTitleSpinnerCharacters)
        let frames = (0..<120).map { "\(glyphs[$0 % glyphs.count]) pnpm install" }

        var publishedCount = 0
        var lastPublished: String? = nil
        for frame in frames {
            let stable = TabManager.stableTerminalPanelTitle(frame)
            guard lastPublished != stable else { continue }
            lastPublished = stable
            publishedCount += 1
        }

        #expect(publishedCount == 1)
        #expect(lastPublished == "pnpm install")
    }

    /// A genuine title change after a spinner stream still publishes: dedup must
    /// suppress only redundant frames, never a real transition (e.g. install →
    /// build → done), so the panel/toolbar keep reflecting real progress.
    @Test func testGenuineTransitionsStillPublishAfterDedup() {
        let stream = [
            "⠋ pnpm install", "⠙ pnpm install", "⠹ pnpm install",  // frame churn
            "⠋ pnpm build", "⠙ pnpm build",                        // real change → 1
            "done",                                                  // real change → 1
        ]

        var published: [String] = []
        var lastPublished: String? = nil
        for frame in stream {
            let stable = TabManager.stableTerminalPanelTitle(frame)
            guard lastPublished != stable else { continue }
            lastPublished = stable
            published.append(stable)
        }

        #expect(published == ["pnpm install", "pnpm build", "done"])
    }
}
