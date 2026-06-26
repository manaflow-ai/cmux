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
///
/// Behavior is exercised through the production entry point
/// `titleToDispatch(for:surfaceID:)` (no test seam into private helpers).
@MainActor
@Suite struct TerminalTitleChurnFilterTests {
    /// The Braille spinner alphabet most CLI tools / agents cycle through.
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private let surfaceA = UUID()
    private let surfaceB = UUID()

    /// First-dispatch result for a fresh filter — isolates the collapse output
    /// from the dedup/empty-frame logic.
    private func collapsed(_ raw: String) -> String? {
        var filter = TerminalTitleChurnFilter()
        return filter.titleToDispatch(for: raw, surfaceID: surfaceA)
    }

    @Test func collapsesLeadingBrailleSpinnerToStableLabel() {
        for frame in Self.spinnerFrames {
            #expect(collapsed("\(frame) Working…") == "Working…", "frame \(frame) must collapse to the stable label")
        }
    }

    @Test func collapsesLeadingSpaceBeforeSpinner() {
        #expect(collapsed("  ⠙  Building project") == "Building project")
    }

    @Test func collapsesMultipleLeadingBrailleGlyphs() {
        #expect(collapsed("⠋⠙⠹ Compiling") == "Compiling")
    }

    @Test func preservesPlainTitlesExactly() {
        // A title with no leading spinner is returned verbatim — the churn fix
        // must not silently trim ordinary OSC titles (intentional padding too).
        #expect(collapsed("npm install") == "npm install")
        #expect(collapsed("  zsh — ~/proj  ") == "  zsh — ~/proj  ")
    }

    @Test func preservesNonLeadingBrailleGlyphs() {
        // Braille only counts as a spinner when it LEADS the title; a glyph
        // mid-title is real content and must survive.
        #expect(collapsed("Build ⠋ step") == "Build ⠋ step")
    }

    @Test func steadySpinnerEmitsExactlyOneDispatch() {
        var filter = TerminalTitleChurnFilter()
        var dispatched: [String] = []
        for frame in Self.spinnerFrames {
            if let title = filter.titleToDispatch(for: "\(frame) Working…", surfaceID: surfaceA) {
                dispatched.append(title)
            }
        }
        #expect(dispatched == ["Working…"], "a steady spinner must collapse to one post, got \(dispatched)")
    }

    @Test func distinctLabelsStayDistinct() {
        var filter = TerminalTitleChurnFilter()
        var dispatched: [String] = []
        for raw in ["⠋ Reading", "⠙ Reading", "⠹ Writing", "⠸ Writing", "⠼ Done"] {
            if let title = filter.titleToDispatch(for: raw, surfaceID: surfaceA) {
                dispatched.append(title)
            }
        }
        #expect(dispatched == ["Reading", "Writing", "Done"])
    }

    @Test func pureSpinnerFrameDoesNotBlankPriorLabel() {
        var filter = TerminalTitleChurnFilter()
        #expect(filter.titleToDispatch(for: "⠋ Working…", surfaceID: surfaceA) == "Working…")
        // A frame that is only the spinner glyph carries no label; it must not
        // be dispatched (which would blank the title shown a moment ago), and a
        // later labelled frame is still deduped against the settled label.
        #expect(filter.titleToDispatch(for: "⠙", surfaceID: surfaceA) == nil)
        #expect(filter.titleToDispatch(for: "⠹ Working…", surfaceID: surfaceA) == nil)
    }

    @Test func identicalNonSpinnerTitlesDedup() {
        var filter = TerminalTitleChurnFilter()
        #expect(filter.titleToDispatch(for: "zsh", surfaceID: surfaceA) == "zsh")
        #expect(filter.titleToDispatch(for: "zsh", surfaceID: surfaceA) == nil)
        #expect(filter.titleToDispatch(for: "vim", surfaceID: surfaceA) == "vim")
    }

    @Test func surfaceChangeReDispatchesMatchingTitle() {
        // A view reused for a new surface must re-dispatch that surface's first
        // title even when its collapsed label matches the previous surface's
        // last one — downstream subscribers are keyed on surface identity.
        var filter = TerminalTitleChurnFilter()
        #expect(filter.titleToDispatch(for: "⠋ Working…", surfaceID: surfaceA) == "Working…")
        #expect(filter.titleToDispatch(for: "⠙ Working…", surfaceID: surfaceA) == nil)
        #expect(filter.titleToDispatch(for: "⠹ Working…", surfaceID: surfaceB) == "Working…")
    }
}
