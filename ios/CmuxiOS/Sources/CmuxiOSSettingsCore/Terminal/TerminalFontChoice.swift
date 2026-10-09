/// The terminal font picked in Settings. Only fonts that render on every
/// iPhone: Ghostty's embedded font and the monospaced families iOS ships.
public enum TerminalFontChoice: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// Ghostty's embedded JetBrains Mono.
    case standard
    case menlo
    case courierNew

    public var id: String { rawValue }

    /// The `font-family` value; nil keeps the embedded font.
    public var ghosttyFamily: String? {
        switch self {
        case .standard: nil
        case .menlo: "Menlo"
        case .courierNew: "Courier New"
        }
    }
}
