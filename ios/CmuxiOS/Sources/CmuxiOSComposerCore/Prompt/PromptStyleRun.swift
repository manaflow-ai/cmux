import Foundation

/// A span the prompt editor styles without changing the text (markdown-lite).
public struct PromptStyleRun: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case heading
        case bold
        case code
        case bullet
        case mention
    }

    public var kind: Kind
    /// UTF-16 range in the prompt.
    public var range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}
