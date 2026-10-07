/// One line of a hunk with its numbers on each side and the changed span
/// inside it (UTF-16 offsets into `text`) when a removal pairs with an
/// addition.
public struct DiffLine: Hashable, Sendable {
    public var kind: DiffLineKind
    /// The line without its diff prefix.
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    public var emphasis: Range<Int>?

    public init(kind: DiffLineKind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil, emphasis: Range<Int>? = nil) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.emphasis = emphasis
    }
}
