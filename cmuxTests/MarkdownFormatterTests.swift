import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pins the pure string edits behind the markdown formatting toolbar: what
/// gets replaced, with what, and where the selection lands afterwards.
struct MarkdownFormatterTests {
    private func apply(_ edit: MarkdownFormatter.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func boldWrapsSelectionAndKeepsItSelected() {
        let text = "make this strong"
        let selection = NSRange(location: 5, length: 4) // "this"
        let edit = MarkdownFormatter.edit(for: .bold, in: text, selection: selection)
        #expect(apply(edit, to: text) == "make **this** strong")
        #expect(edit.selection == NSRange(location: 7, length: 4))
    }

    @Test func boldWithoutSelectionParksCaretBetweenMarkers() {
        let edit = MarkdownFormatter.edit(for: .bold, in: "ab", selection: NSRange(location: 1, length: 0))
        #expect(apply(edit, to: "ab") == "a****b")
        #expect(edit.selection == NSRange(location: 3, length: 0))
    }

    @Test func headingReplacesExistingLevelInsteadOfStacking() {
        let text = "## old heading\n"
        let edit = MarkdownFormatter.edit(for: .heading1, in: text, selection: NSRange(location: 3, length: 0))
        #expect(apply(edit, to: text) == "# old heading\n")
    }

    @Test func headingTogglesOffWhenReapplied() {
        let text = "# title\n"
        let edit = MarkdownFormatter.edit(for: .heading1, in: text, selection: NSRange(location: 2, length: 0))
        #expect(apply(edit, to: text) == "title\n")
    }

    @Test func bulletPrefixesEverySelectedLine() {
        let text = "one\ntwo\nthree\n"
        let selection = NSRange(location: 0, length: 9) // through "t" of line 3
        let edit = MarkdownFormatter.edit(for: .bulletList, in: text, selection: selection)
        #expect(apply(edit, to: text) == "- one\n- two\n- three\n")
    }

    @Test func numberedListCountsFromOne() {
        let text = "a\nb\n"
        let edit = MarkdownFormatter.edit(for: .numberedList, in: text, selection: NSRange(location: 0, length: 3))
        #expect(apply(edit, to: text) == "1. a\n2. b\n")
    }

    @Test func linkSelectsUrlPlaceholderForSelectedText() {
        let text = "visit docs now"
        let selection = NSRange(location: 6, length: 4) // "docs"
        let edit = MarkdownFormatter.edit(for: .link, in: text, selection: selection)
        let result = apply(edit, to: text)
        #expect(result == "visit [docs](url) now")
        #expect((result as NSString).substring(with: edit.selection) == "url")
    }

    @Test func quotePrefixesLinesTouchedBySelection() {
        let text = "alpha\nbeta\n"
        let edit = MarkdownFormatter.edit(for: .quote, in: text, selection: NSRange(location: 7, length: 0))
        #expect(apply(edit, to: text) == "alpha\n> beta\n")
    }
}
