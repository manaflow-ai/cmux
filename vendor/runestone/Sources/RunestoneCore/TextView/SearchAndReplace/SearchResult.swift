import Foundation

/// A match returned by performing a search query.
public struct SearchResult: Hashable, Equatable {
    /// Unique identifier of the result.
    public let id: String = UUID().uuidString
    /// Range of the matched text.
    public let range: NSRange
    /// Location of line on which the matched text starts.
    public let startLocation: TextLocation
    /// Location of line on which the matched text ends.
    public let endLocation: TextLocation

    /// Creates a search result.
    /// - Parameters:
    ///   - range: Range of the matched text.
    ///   - startLocation: Location where the match starts.
    ///   - endLocation: Location where the match ends.
    public init(range: NSRange, startLocation: TextLocation, endLocation: TextLocation) {
        self.range = range
        self.startLocation = startLocation
        self.endLocation = endLocation
    }
}
