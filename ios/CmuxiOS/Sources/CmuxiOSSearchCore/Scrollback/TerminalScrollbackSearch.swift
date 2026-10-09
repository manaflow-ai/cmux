/// Seam for searching one terminal's scrollback (c15-search.md section 7).
/// The real implementation pages `terminal.history {before, max_bytes}` over
/// C1's attach, strips escapes, matches each line with `SearchMatcher`
/// (substring tiers only) and stops at a byte budget. Not built while
/// cmux-tui answers `terminal.history` with `proto.unsupported`.
public protocol TerminalScrollbackSearch: Sendable {
    func search(_ query: String, in target: TerminalSearchTarget, limit: Int) async throws -> [ScrollbackMatch]
}
