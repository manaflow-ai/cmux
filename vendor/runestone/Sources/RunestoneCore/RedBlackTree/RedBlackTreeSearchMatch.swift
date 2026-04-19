import Foundation

final class RedBlackTreeSearchMatch<NodeID: RedBlackTreeNodeID, NodeValue: RedBlackTreeNodeValue, Data> {
    typealias Node = RedBlackTreeNode<NodeID, NodeValue, Data>

    let location: NodeValue
    let value: NodeValue
    let node: Node

    init(location: NodeValue, value: NodeValue, node: Node) {
        self.location = location
        self.value = value
        self.node = node
    }
}
