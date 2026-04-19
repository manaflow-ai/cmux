import TreeSitter

final class TreeSitterQueryCursor {
    private let pointer: OpaquePointer
    private let query: TreeSitterQuery
    private let node: TreeSitterNode
    private var haveExecuted = false

    init(query: TreeSitterQuery, node: TreeSitterNode) {
        self.pointer = ts_query_cursor_new()
        self.query = query
        self.node = node
    }

    deinit {
        ts_query_cursor_delete(pointer)
    }

    func setQueryRange(_ range: ByteRange) {
        let start = UInt32(range.location.value)
        let end = UInt32((range.location + range.length).value)
        ts_query_cursor_set_byte_range(pointer, start, end)
    }

    func execute() {
        if !haveExecuted {
            haveExecuted = true
            ts_query_cursor_exec(pointer, query.pointer, node.rawValue)
        }
    }

    func validCaptures(in stringView: StringView) -> [TreeSitterCapture] {
        guard haveExecuted else {
            fatalError("Cannot get captures of a query that has not been executed.")
        }
        var match = TSQueryMatch(id: 0, pattern_index: 0, capture_count: 0, captures: nil)
        var result: [TreeSitterCapture] = []
        while ts_query_cursor_next_match(pointer, &match) {
            let captureCount = Int(match.capture_count)
            let captureBuffer = UnsafeBufferPointer<TSQueryCapture>(start: match.captures, count: captureCount)
            let captures: [TreeSitterCapture] = captureBuffer.compactMap { capture in
                let node = TreeSitterNode(node: capture.node)
                let captureName = query.captureName(forId: capture.index)
                let predicates = query.predicates(forPatternIndex: UInt32(match.pattern_index))
                return TreeSitterCapture(node: node, index: capture.index, name: captureName, predicates: predicates)
            }
            let match = TreeSitterQueryMatch(captures: captures)
            let evaluator = TreeSitterTextPredicatesEvaluator(match: match, stringView: stringView)
            result += captures.filter { capture in
                capture.byteRange.length > 0 && evaluator.evaluatePredicates(in: capture)
            }
        }
        return result
    }
}
