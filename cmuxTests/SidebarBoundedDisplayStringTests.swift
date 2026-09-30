import Testing
@testable import cmux_DEV

/// The marker `sidebarBoundedDisplayString` appends when it cuts a block.
///
/// Sidebar text is scanned for GitHub references after it is bounded, and the
/// reference parser trims trailing `.` before reading a number. An ASCII `...`
/// marker is therefore invisible to it: a row cut mid-number reads
/// `owner/repo#84...`, parses as `owner/repo#84`, and offers a link to a
/// different issue than the one the author wrote
/// (https://github.com/manaflow-ai/cmux/issues/15882). A single `…` is not
/// trimmed, so the same cut fails to parse and stays plain text, which is the
/// outcome a reader can trust.
///
/// The marker is also what every other user-visible truncation in the app
/// already uses, so this is the spelling the sidebar was the last to adopt.
@Suite
struct SidebarBoundedDisplayStringTests {
    /// Longer than any bound a caller passes, so the cut always happens.
    private let long = String(repeating: "sidebar description text ", count: 500)

    @Test
    func aValueCutByTheCharacterBoundIsMarkedWithAnEllipsisCharacter() {
        let result = long.sidebarBoundedDisplayString(
            maxDisplayedLines: 12,
            maxDisplayedCharacters: 64
        )

        #expect(result.hasSuffix("…"))
        #expect(!result.hasSuffix("."))
    }

    @Test
    func aValueCutByTheLineBoundIsMarkedWithAnEllipsisCharacter() {
        // The other of the two break paths. Both append the same marker, and a
        // fix that reaches only one of them leaves the hazard in place for
        // multi-line metadata blocks, which is most of them.
        let lines = Array(repeating: "one line of a metadata block", count: 40)
            .joined(separator: "\n")

        let result = lines.sidebarBoundedDisplayString(
            maxDisplayedLines: 3,
            maxDisplayedCharacters: 4096
        )

        #expect(result.hasSuffix("…"))
        #expect(!result.hasSuffix("."))
    }

    @Test
    func aCutThatLeavesNothingToShowIsStillJustTheMarker() {
        // The kept prefix trims away to nothing, so the marker stands alone.
        let result = String(repeating: " ", count: 500).sidebarBoundedDisplayString(
            maxDisplayedLines: 12,
            maxDisplayedCharacters: 64
        )

        #expect(result == "…")
    }

    @Test
    func aValueInsideBothBoundsIsReturnedUnchanged() {
        // No marker at all when nothing was cut: the early return is what keeps
        // ordinary short rows from growing a trailing character.
        let short = "a short description"

        #expect(
            short.sidebarBoundedDisplayString(
                maxDisplayedLines: 12,
                maxDisplayedCharacters: 4096
            ) == short
        )
    }
}
