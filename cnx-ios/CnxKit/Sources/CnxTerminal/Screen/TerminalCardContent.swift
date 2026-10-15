/// What a terminal tab's grid card shows.
public enum TerminalCardContent: Equatable, Sendable {
    /// The connecting placeholder over the last frame (the session started).
    case connecting
    /// The page's snapshot (or a saved frame).
    case snapshot
    /// The Mac's screen as text, fetched for a tab not opened in this launch.
    case screenText
    /// The static labeled placeholder.
    case placeholder

    public static func choose(sessionStarted: Bool, connecting: Bool, hasSnapshot: Bool, screenText: String?) -> Self {
        if sessionStarted, connecting { return .connecting }
        return hasSnapshot ? .snapshot : .placeholder
    }
}
