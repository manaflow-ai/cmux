import Foundation

/// Classifies completed terminal viewport reads used during initial presentation.
public struct CmuxTerminalViewport: Sendable, Equatable {
    /// Visible terminal rows separated by newlines.
    public let text: String

    /// Creates a viewport classifier.
    /// - Parameter text: Visible terminal rows separated by newlines.
    public init(text: String) {
        self.text = text
    }

    /// Whether output contains more than zsh's transient, indented PROMPT_SP marker.
    public var hasPresentableInitialOutput: Bool {
        let visible = text.enumerated().filter { !$0.element.isWhitespace }
        guard let first = visible.first else { return false }
        return visible.count > 1 || first.element != "%" || first.offset < 2
    }
}
