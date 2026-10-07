/// The scrollback seam's default: every search answers `.unsupported`.
public struct UnavailableTerminalScrollbackSearch: TerminalScrollbackSearch {
    public init() {}

    public func search(_ query: String, in target: TerminalSearchTarget, limit: Int) async throws -> [ScrollbackMatch] {
        throw TerminalScrollbackSearchError.unsupported
    }
}
