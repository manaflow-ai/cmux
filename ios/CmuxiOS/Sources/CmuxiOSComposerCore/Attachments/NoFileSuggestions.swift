import Foundation

/// No suggestions: mentions are typed as text.
public struct NoFileSuggestions: ComposerFileSuggesting {
    public init() {}

    public func suggestions(for query: String, target: ComposerTarget, limit: Int) async -> [String] { [] }
}
