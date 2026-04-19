import Foundation

/// Character pair to be registered with a text view.
public protocol CharacterPair {
    /// Leading component of the character pair. For example an opening bracket.
    var leading: String { get }
    /// Trailing component of the character pair. For example a closing bracket.
    var trailing: String { get }
}
