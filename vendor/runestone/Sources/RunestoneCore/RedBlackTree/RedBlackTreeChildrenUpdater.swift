import Foundation

class RedBlackTreeChildrenUpdater<NodeID: RedBlackTreeNodeID, NodeValue: RedBlackTreeNodeValue, NodeData> {
    typealias Node = RedBlackTreeNode<NodeID, NodeValue, NodeData>

    func updateAfterChangingChildren(of node: Node) -> Bool {
        false
    }
}
