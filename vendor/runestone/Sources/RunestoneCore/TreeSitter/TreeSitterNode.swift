import TreeSitter

final class TreeSitterNode {
    let rawValue: TSNode
    var expressionString: String? {
        if let str = ts_node_string(rawValue) {
            let result = String(cString: str)
            str.deallocate()
            return result
        } else {
            return nil
        }
    }
    var type: String? {
        if let str = ts_node_type(rawValue) {
            return String(cString: str)
        } else {
            return nil
        }
    }
    var startByte: ByteCount {
        ByteCount(ts_node_start_byte(rawValue))
    }
    var endByte: ByteCount {
        ByteCount(ts_node_end_byte(rawValue))
    }
    var startPoint: TreeSitterTextPoint {
        TreeSitterTextPoint(ts_node_start_point(rawValue))
    }
    var endPoint: TreeSitterTextPoint {
        TreeSitterTextPoint(ts_node_end_point(rawValue))
    }
    var byteRange: ByteRange {
        ByteRange(from: startByte, to: endByte)
    }
    var parent: TreeSitterNode? {
        getRelationship(using: ts_node_parent)
    }
    var previousSibling: TreeSitterNode? {
        getRelationship(using: ts_node_prev_sibling)
    }
    var nextSibling: TreeSitterNode? {
        getRelationship(using: ts_node_next_sibling)
    }
    var textRange: TreeSitterTextRange {
        TreeSitterTextRange(startPoint: startPoint, endPoint: endPoint, startByte: startByte, endByte: endByte)
    }
    var childCount: Int {
        Int(ts_node_child_count(rawValue))
    }

    init(node: TSNode) {
        self.rawValue = node
    }

    func descendantForRange(from startPoint: TreeSitterTextPoint, to endPoint: TreeSitterTextPoint) -> TreeSitterNode {
        let node = ts_node_descendant_for_point_range(rawValue, startPoint.rawValue, endPoint.rawValue)
        return Self(node: node)
    }

    func child(at index: Int) -> Self? {
        if index < childCount {
            let node = ts_node_child(rawValue, UInt32(index))
            return Self(node: node)
        } else {
            return nil
        }
    }
}

private extension TreeSitterNode {
    private func getRelationship(using f: (TSNode) -> TSNode) -> TreeSitterNode? {
        let node = f(rawValue)
        if ts_node_is_null(node) {
            return nil
        } else {
            return TreeSitterNode(node: node)
        }
    }
}

extension TreeSitterNode: Hashable {
    static func == (lhs: TreeSitterNode, rhs: TreeSitterNode) -> Bool {
        lhs.rawValue.id == rhs.rawValue.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.id)
    }
}

extension TreeSitterNode: CustomDebugStringConvertible {
    var debugDescription: String {
        "[TreeSitterNode startByte=\(startByte) endByte=\(endByte) startPoint=\(startPoint) endPoint=\(endPoint)]"
    }
}
