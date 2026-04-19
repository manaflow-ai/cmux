import CoreGraphics
import Foundation

final class DocumentLineChildrenUpdater: RedBlackTreeChildrenUpdater<DocumentLineNodeID, Int, DocumentLineNodeData> {
    override func updateAfterChangingChildren(of node: Node) -> Bool {
        var totalLineHeight = node.data.lineHeight
        var totalByteCount = node.data.byteCount
        if let leftNode = node.left {
            totalLineHeight += leftNode.data.totalLineHeight
            totalByteCount += leftNode.data.nodeTotalByteCount
        }
        if let rightNode = node.right {
            totalLineHeight += rightNode.data.totalLineHeight
            totalByteCount += rightNode.data.nodeTotalByteCount
        }
        if totalLineHeight != node.data.totalLineHeight || totalByteCount != node.data.nodeTotalByteCount {
            node.data.totalLineHeight = totalLineHeight
            node.data.nodeTotalByteCount = totalByteCount
            return true
        } else {
            return false
        }
    }
}
