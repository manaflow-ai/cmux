import Foundation

/// Identifies the protocol-v7 cursor shape.
public enum CmuxRenderCursorStyle: String, Codable, Sendable, Equatable {
    /// A full-cell block.
    case block

    /// A horizontal line at the cell baseline.
    case underline

    /// A vertical beam at the cell leading edge.
    case bar
}
