import TreeSitter

final class TreeSitterTree {
    let pointer: OpaquePointer
    var rootNode: TreeSitterNode {
        TreeSitterNode(node: ts_tree_root_node(pointer))
    }

    init(_ tree: OpaquePointer) {
        self.pointer = tree
    }

    deinit {
        ts_tree_delete(pointer)
    }

    func apply(_ inputEdit: TreeSitterInputEdit) {
        withUnsafePointer(to: TSInputEdit(inputEdit)) { inputEditPointer in
            ts_tree_edit(pointer, inputEditPointer)
        }
    }

    func rangesChanged(comparingTo otherTree: TreeSitterTree) -> [TreeSitterTextRange] {
        var count = CUnsignedInt(0)
        let ptr = ts_tree_get_changed_ranges(pointer, otherTree.pointer, &count)
        return UnsafeBufferPointer(start: ptr, count: Int(count)).map { range in
            let startPoint = TreeSitterTextPoint(range.start_point)
            let endPoint = TreeSitterTextPoint(range.end_point)
            let startByte = ByteCount(range.start_byte)
            let endByte = ByteCount(range.end_byte)
            return TreeSitterTextRange(startPoint: startPoint, endPoint: endPoint, startByte: startByte, endByte: endByte)
        }
    }
}

extension TreeSitterTree: CustomDebugStringConvertible {
    var debugDescription: String {
        "[TreeSitterTree rootNode=\(rootNode)]"
    }
}
