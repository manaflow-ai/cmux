import Foundation

/// A location in the text.
public struct TextLocation: Hashable, Equatable {
    /// Zero-based line number.
    public let lineNumber: Int
    /// Column in the line.
    public let column: Int

    /// Initializes TextLocation from the given line and column
    public init (lineNumber: Int, column: Int) {
        self.lineNumber = lineNumber
        self.column = column
    }

    init(_ linePosition: LinePosition) {
        self.lineNumber = linePosition.row
        self.column = linePosition.column
    }
}
