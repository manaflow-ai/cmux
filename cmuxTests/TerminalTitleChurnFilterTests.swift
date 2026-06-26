import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the terminal-title spinner churn that drives the
/// reentrant `NSHostingView` layout faults in #6507 / #4735: an agent or CLI
/// tool that animates its title with Braille spinner glyphs on every frame must
/// collapse to a single stable title so the per-frame `.ghosttyDidSetTitle`
/// posts stop flooding the main-thread panel-title / toolbar / sidebar layout
/// path.
@Suite struct TerminalTitleChurnFilterTests {
    /// The Braille spinner alphabet most CLI tools / agents cycle through.
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    @Test func collapsesLeadingBrailleSpinnerToStableLabel() {
        for frame in Self.spinnerFrames {
            #expect(
                TerminalTitleChurnFilter.collapseSpinnerFrames("\(frame) Working…") == "Working…",
                "frame \(frame) must collapse to the stable label"
            )
        }
    }

    @Test func collapsesLeadingSpaceBeforeSpinner() {
        #expect(TerminalTitleChurnFilter.collapseSpinnerFrames("  ⠙  Building project") == "Building project")
    }

    @Test func collapsesMultipleLeadingBrailleGlyphs() {
        #expect(TerminalTitleChurnFilter.collapseSpinnerFrames("⠋⠙⠹ Compiling") == "Compiling")
    }

    @Test func preservesPlainTitlesAndTrimsOnly() {
        #expect(TerminalTitleChurnFilter.collapseSpinnerFrames("npm install") == "npm install")
        #expect(TerminalTitleChurnFilter.collapseSpinnerFrames("  zsh — ~/proj  ") == "zsh — ~/proj")
    }

    @Test func preservesNonLeadingBrailleGlyphs() {
        // Braille only counts as a spinner when it LEADS the title; a glyph
        // mid-title is real content and must survive.
        #expect(TerminalTitleChurnFilter.collapseSpinnerFrames("Build ⠋ step") == "Build ⠋ step")
    }

    @Test func steadySpinnerEmitsExactlyOneDispatch() {
        var filter = TerminalTitleChurnFilter()
        var dispatched: [String] = []
        for frame in Self.spinnerFrames {
            if let title = filter.titleToDispatch(for: "\(frame) Working…") {
                dispatched.append(title)
            }
        }
        #expect(dispatched == ["Working…"], "a steady spinner must collapse to one post, got \(dispatched)")
    }

    @Test func distinctLabelsStayDistinct() {
        var filter = TerminalTitleChurnFilter()
        var dispatched: [String] = []
        for raw in ["⠋ Reading", "⠙ Reading", "⠹ Writing", "⠸ Writing", "⠼ Done"] {
            if let title = filter.titleToDispatch(for: raw) {
                dispatched.append(title)
            }
        }
        #expect(dispatched == ["Reading", "Writing", "Done"])
    }

    @Test func pureSpinnerFrameDoesNotBlankPriorLabel() {
        var filter = TerminalTitleChurnFilter()
        #expect(filter.titleToDispatch(for: "⠋ Working…") == "Working…")
        // A frame that is only the spinner glyph carries no label; it must not
        // be dispatched (which would blank the title shown a moment ago), and a
        // later labelled frame is still deduped against the settled label.
        #expect(filter.titleToDispatch(for: "⠙") == nil)
        #expect(filter.titleToDispatch(for: "⠹ Working…") == nil)
    }

    @Test func identicalNonSpinnerTitlesDedup() {
        var filter = TerminalTitleChurnFilter()
        #expect(filter.titleToDispatch(for: "zsh") == "zsh")
        #expect(filter.titleToDispatch(for: "zsh") == nil)
        #expect(filter.titleToDispatch(for: "vim") == "vim")
    }
}
