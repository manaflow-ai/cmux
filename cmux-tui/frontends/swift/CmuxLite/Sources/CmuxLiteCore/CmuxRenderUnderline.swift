import Foundation

/// Identifies the exact underline presentation requested by a render run.
public enum CmuxRenderUnderline: String, Codable, Sendable, Equatable {
    /// A single straight underline.
    case single

    /// Two parallel straight underlines.
    case double

    /// A curved underline.
    case curly

    /// A dotted underline.
    case dotted

    /// A dashed underline.
    case dashed
}
