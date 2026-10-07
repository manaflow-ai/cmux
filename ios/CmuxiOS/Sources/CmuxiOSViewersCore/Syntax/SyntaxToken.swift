/// A highlighted span in UTF-16 offsets.
public struct SyntaxToken: Hashable, Sendable {
    public var range: Range<Int>
    public var kind: SyntaxTokenKind

    public init(_ range: Range<Int>, _ kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}
