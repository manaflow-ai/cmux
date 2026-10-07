/// A parsed Markdown file.
public struct MarkdownDocument: Hashable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public init(parsing text: String) {
        blocks = MarkdownParser().parse(text)
    }

    /// Task items anywhere in the document: (done, total).
    public var taskProgress: (done: Int, total: Int) {
        var done = 0
        var total = 0
        func visit(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .list(let list):
                    for item in list.items {
                        if let checked = item.isChecked {
                            total += 1
                            if checked { done += 1 }
                        }
                        visit(item.blocks)
                    }
                case .quote(let inner):
                    visit(inner)
                default:
                    continue
                }
            }
        }
        visit(blocks)
        return (done, total)
    }
}
