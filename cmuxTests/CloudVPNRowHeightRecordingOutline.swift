import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records the native row lookups and invalidations performed by the resize delegate.
@MainActor
final class CloudVPNRowHeightRecordingOutline: NSOutlineView {
    var visibleNodes: [CloudTreeNode] = []
    var itemQueries = 0
    var rowQueries: [CloudTreeNode] = []
    var invalidatedRows = IndexSet()

    override var numberOfRows: Int { visibleNodes.count }

    override func item(atRow row: Int) -> Any? {
        itemQueries += 1
        return visibleNodes[row]
    }

    override func row(forItem item: Any) -> Int {
        guard let node = item as? CloudTreeNode else { return -1 }
        rowQueries.append(node)
        return visibleNodes.firstIndex { $0 === node } ?? -1
    }

    override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
        invalidatedRows.formUnion(indexSet)
    }

    func resetRecording() {
        itemQueries = 0
        rowQueries = []
        invalidatedRows = []
    }
}
