/// One list item: its blocks (text first, nested lists after) and, for a
/// task item (`- [ ]`, `- [x]`), whether it is done.
public struct MarkdownListItem: Hashable, Sendable {
    /// nil: not a task item.
    public var isChecked: Bool?
    public var blocks: [MarkdownBlock]

    public init(isChecked: Bool? = nil, blocks: [MarkdownBlock]) {
        self.isChecked = isChecked
        self.blocks = blocks
    }

    public var isTask: Bool { isChecked != nil }
}
