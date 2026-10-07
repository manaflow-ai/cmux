/// The color class of a highlighted span.
public enum SyntaxTokenKind: Hashable, Sendable, CaseIterable {
    case keyword
    case string
    case comment
    case number
    case type
    /// Markup tag names.
    case tag
    /// Markup attributes, JSON/YAML/TOML keys.
    case attribute
    /// Markdown headings.
    case heading
}
