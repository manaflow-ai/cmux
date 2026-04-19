import Foundation

protocol RedBlackTreeSearchQuery {
    associatedtype NodeID: RedBlackTreeNodeID
    associatedtype NodeValue: RedBlackTreeNodeValue
    associatedtype NodeData
    func shouldTraverseLeftChildren(of node: RedBlackTreeNode<NodeID, NodeValue, NodeData>) -> Bool
    func shouldTraverseRightChildren(of node: RedBlackTreeNode<NodeID, NodeValue, NodeData>) -> Bool
    func shouldInclude(_ node: RedBlackTreeNode<NodeID, NodeValue, NodeData>) -> Bool
}
