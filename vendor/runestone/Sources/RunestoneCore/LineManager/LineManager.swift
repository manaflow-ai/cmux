import CoreGraphics
import Foundation

struct DocumentLineNodeID: RedBlackTreeNodeID, Hashable {
    let id = UUID()
    var rawValue: String {
        id.uuidString
    }
}

extension DocumentLineNodeID: CustomDebugStringConvertible {
    var debugDescription: String {
        rawValue
    }
}

typealias DocumentLineTree = RedBlackTree<DocumentLineNodeID, Int, DocumentLineNodeData>
typealias DocumentLineNode = RedBlackTreeNode<DocumentLineNodeID, Int, DocumentLineNodeData>

final class LineManager {
    var stringView: StringView
    var lineCount: Int {
        documentLineTree.nodeTotalCount
    }
    var contentHeight: CGFloat {
        let rightMost = documentLineTree.root.rightMost
        return rightMost.yPosition + rightMost.data.lineHeight
    }
    var estimatedLineHeight: CGFloat = 12
    var firstLine: DocumentLineNode {
        documentLineTree.root.leftMost
    }
    var lastLine: DocumentLineNode {
        documentLineTree.root.rightMost
    }
    // When rebuilding, and only when rebuilding, the tree we keep track of the longest line.
    // This helps the text editor to determine the width of the content. The "initial" in the name implies
    // that the reference does not necessarily point to the longest line as the document is edited.
    private(set) weak var initialLongestLine: DocumentLineNode?

    private let documentLineTree: DocumentLineTree

    init(stringView: StringView) {
        self.stringView = stringView
        let rootData = DocumentLineNodeData(lineHeight: estimatedLineHeight)
        documentLineTree = DocumentLineTree(minimumValue: 0, rootValue: 0, rootData: rootData)
        documentLineTree.childrenUpdater = DocumentLineChildrenUpdater()
        rootData.node = documentLineTree.root
    }

    func rebuild() {
        // Reset the tree so we only have a single line.
        let rootData = DocumentLineNodeData(lineHeight: estimatedLineHeight)
        documentLineTree.reset(rootValue: 0, rootData: rootData)
        rootData.node = documentLineTree.root
        initialLongestLine = nil
        // Iterate over lines in the string.
        var line = documentLineTree.node(atIndex: 0)
        var workingNewLineRange = NewLineFinder.rangeOfNextNewLine(in: stringView.string, startingAt: 0)
        var lines: [DocumentLineNode] = []
        var lastDelimiterEnd = 0
        var totalLineHeight: CGFloat = 0
        var longestLineLength: Int = 0
        while let newLineRange = workingNewLineRange {
            let totalLength = newLineRange.location + newLineRange.length - lastDelimiterEnd
            let substringRange = NSRange(location: lastDelimiterEnd, length: totalLength)
            let substring = stringView.string.substring(with: substringRange)
            line.value = totalLength
            line.data.totalLength = totalLength
            line.data.delimiterLength = newLineRange.length
            line.data.lineHeight = estimatedLineHeight
            line.data.totalLineHeight = totalLineHeight
            line.data.byteCount = substring.byteCount
            lastDelimiterEnd = newLineRange.location + newLineRange.length
            lines.append(line)
            if totalLength > longestLineLength {
                longestLineLength = totalLength
                initialLongestLine = line
            }
            let data = DocumentLineNodeData(lineHeight: estimatedLineHeight)
            line = DocumentLineNode(tree: documentLineTree, value: 0, data: data)
            data.node = line
            workingNewLineRange = NewLineFinder.rangeOfNextNewLine(in: stringView.string, startingAt: lastDelimiterEnd)
            totalLineHeight += estimatedLineHeight
        }
        let totalLength = stringView.string.length - lastDelimiterEnd
        let substringRange = NSRange(location: lastDelimiterEnd, length: totalLength)
        let substring = stringView.string.substring(with: substringRange)
        line.value = totalLength
        line.data.totalLength = totalLength
        line.data.byteCount = substring.byteCount
        lines.append(line)
        if totalLength > longestLineLength {
            longestLineLength = totalLength
            initialLongestLine = line
        }
        documentLineTree.rebuild(from: lines)
    }

    @discardableResult
    func removeCharacters(in range: NSRange) -> LineChangeSet {
        guard range.length > 0 else {
            return LineChangeSet()
        }
        guard let startLine = documentLineTree.node(containingLocation: range.location) else {
            return LineChangeSet()
        }
        if range.location > Int(startLine.location) + startLine.data.length {
            // Deleting starting in the middle of a delimiter.
            let changeSet = LineChangeSet()
            let otherChangeSetA = setLength(of: startLine, to: startLine.value - 1)
            changeSet.union(with: otherChangeSetA)
            let otherChangeSetB = removeCharacters(in: NSRange(location: range.location, length: range.length - 1))
            changeSet.union(with: otherChangeSetB)
            return changeSet
        } else if range.location + range.length < Int(startLine.location) + startLine.value {
            // Removing a part of the start line.
            return setLength(of: startLine, to: startLine.value - range.length)
        } else {
            // Merge startLine with another line because the startLine's delimeter was deleted,
            // possibly removing lines in between if multiple delimeters were deleted.
            let charactersRemovedInStartLine = Int(startLine.location) + startLine.value - range.location
            assert(charactersRemovedInStartLine > 0)
            guard let endLine = documentLineTree.node(containingLocation: range.location + range.length) else {
                return LineChangeSet()
            }
            if endLine === startLine {
                // Removing characters in the last line.
                return setLength(of: startLine, to: startLine.value - range.length)
            } else {
                let changeSet = LineChangeSet()
                let charactersLeftInEndLine = Int(endLine.location) + endLine.value - (range.location + range.length)
                // Remove all lines between startLine and endLine, excluding startLine but including endLine.
                var tmp = startLine.next
                var lineToRemove = tmp
                repeat {
                    lineToRemove = tmp
                    tmp = tmp.next
                    changeSet.markLineRemoved(lineToRemove)
                    documentLineTree.remove(lineToRemove)
                } while lineToRemove !== endLine
                let newLength = startLine.value - charactersRemovedInStartLine + charactersLeftInEndLine
                let otherChangeSet = setLength(of: startLine, to: newLength)
                changeSet.union(with: otherChangeSet)
                return changeSet
            }
        }
    }

    @discardableResult
    func insert(_ string: NSString, at location: Int) -> LineChangeSet {
        let changeSet = LineChangeSet()
        guard var line = documentLineTree.node(containingLocation: location) else {
            return LineChangeSet()
        }
        var lineLocation = Int(line.location)
        assert(location <= lineLocation + line.value)
        if location > lineLocation + line.data.length {
            // Inserting in the middle of a delimiter.
            let otherChangeSetA = setLength(of: line, to: line.value - 1)
            changeSet.union(with: otherChangeSetA)
            // Add new line.
            line = insertLine(ofLength: 1, after: line)
            changeSet.markLineInserted(line)
            let otherChangeSetB = setLength(of: line, to: 1, newLine: &line)
            changeSet.union(with: otherChangeSetB)
        }
        if let rangeOfFirstNewLine = NewLineFinder.rangeOfNextNewLine(in: string, startingAt: 0) {
            var lastDelimiterEnd = 0
            var rangeOfNewLine = rangeOfFirstNewLine
            var hasReachedEnd = false
            while !hasReachedEnd {
                let lineBreakLocation = location + rangeOfNewLine.location + rangeOfNewLine.length
                lineLocation = Int(line.location)
                let lengthAfterInsertionPos = lineLocation + line.value - (location + lastDelimiterEnd)
                let otherChangeSetA = setLength(of: line, to: lineBreakLocation - lineLocation, newLine: &line)
                changeSet.union(with: otherChangeSetA)
                var newLine = insertLine(ofLength: lengthAfterInsertionPos, after: line)
                changeSet.markLineInserted(newLine)
                let otherChangeSetB = setLength(of: newLine, to: lengthAfterInsertionPos, newLine: &newLine)
                changeSet.union(with: otherChangeSetB)
                line = newLine
                lastDelimiterEnd = rangeOfNewLine.location + rangeOfNewLine.length
                if let rangeOfNextNewLine = NewLineFinder.rangeOfNextNewLine(in: string, startingAt: lastDelimiterEnd) {
                    rangeOfNewLine = rangeOfNextNewLine
                } else {
                    hasReachedEnd = true
                }
            }
            // Insert rest of last delimiter.
            if lastDelimiterEnd != string.length {
                let otherChangeSet = setLength(of: line, to: line.value + string.length - lastDelimiterEnd)
                changeSet.union(with: otherChangeSet)
            }
        } else {
            // No newline is being inserted. All the text is in a single line.
            let otherChangeSet = setLength(of: line, to: line.value + string.length)
            changeSet.union(with: otherChangeSet)
        }
        return changeSet
    }

    func linePosition(at location: Int) -> LinePosition? {
        if let line = line(containingCharacterAt: location) {
            let column = location - line.location
            return LinePosition(row: line.index, column: column)
        } else {
            return nil
        }
    }

    func line(containingCharacterAt location: Int) -> DocumentLineNode? {
        if location >= 0 && location <= Int(documentLineTree.nodeTotalValue) {
            return documentLineTree.node(containingLocation: location)
        } else {
            return nil
        }
    }

    func line(containingYOffset yOffset: CGFloat) -> DocumentLineNode? {
        documentLineTree.node(containingLocation: yOffset,
                              minimumValue: 0,
                              valueKeyPath: \.data.lineHeight,
                              totalValueKeyPath: \.data.totalLineHeight)
    }

    func line(containingByteAt byteIndex: ByteCount) -> DocumentLineNode? {
        documentLineTree.node(containingLocation: byteIndex,
                              minimumValue: ByteCount(0),
                              valueKeyPath: \.data.byteCount,
                              totalValueKeyPath: \.data.nodeTotalByteCount)
    }

    func line(atRow row: Int) -> DocumentLineNode {
        documentLineTree.node(atIndex: row)
    }

    @discardableResult
    func setHeight(of line: DocumentLineNode, to newHeight: CGFloat) -> Bool {
        if abs(newHeight - line.data.lineHeight) < CGFloat.ulpOfOne {
            return false
        } else {
            line.data.lineHeight = newHeight
            documentLineTree.updateAfterChangingChildren(of: line)
            return true
        }
    }

    func lines(in range: NSRange) -> [DocumentLineNode] {
        guard let firstLine = line(containingCharacterAt: range.location) else {
            return []
        }
        var lines: [DocumentLineNode] = [firstLine]
        if range.length > 0, let lastLine = line(containingCharacterAt: range.location + range.length), lastLine != firstLine {
            let startLineIndex = firstLine.index + 1 // Skip the first line since we already have it
            let endLineIndex = lastLine.index - 1 // Skip the last line since we already have it
            if startLineIndex <= endLineIndex {
                lines += (startLineIndex ... endLineIndex).map(line(atRow:))
            }
            lines.append(lastLine)
        }
        return lines
    }

    func startAndEndLine(in range: NSRange) -> (startLine: DocumentLineNode, endLine: DocumentLineNode)? {
        if range.length == 0 {
            if let line = line(containingCharacterAt: range.lowerBound) {
                return (line, line)
            } else {
                return nil
            }
        } else if let startLine = line(containingCharacterAt: range.lowerBound), let endLine = line(containingCharacterAt: range.upperBound) {
            return (startLine, endLine)
        } else {
            return nil
        }
    }

    func createLineIterator() -> RedBlackTreeIterator<DocumentLineNodeID, Int, DocumentLineNodeData> {
        RedBlackTreeIterator(tree: documentLineTree)
    }
}

private extension LineManager {
    private func setLength(of line: DocumentLineNode, to newTotalLength: Int) -> LineChangeSet {
        var newLine: DocumentLineNode = line
        return setLength(of: line, to: newTotalLength, newLine: &newLine)
    }

    private func setLength(of line: DocumentLineNode, to newTotalLength: Int, newLine: inout DocumentLineNode) -> LineChangeSet {
        let changeSet = LineChangeSet()
        changeSet.markLineEdited(line)
        let range = NSRange(location: line.location, length: newTotalLength)
        let substring = stringView.substring(in: range)
        let newByteCount = substring?.byteCount ?? 0
        if newTotalLength != line.value || newTotalLength != line.data.totalLength || newByteCount != line.data.byteCount {
            line.value = newTotalLength
            line.data.totalLength = newTotalLength
            line.data.byteCount = newByteCount
            documentLineTree.updateAfterChangingChildren(of: line)
        }
        // Determine new delimiter length.
        if newTotalLength == 0 {
            line.data.delimiterLength = 0
        } else {
            let lastChar = getCharacter(at: Int(line.location) + newTotalLength - 1)
            if lastChar == Symbol.carriageReturn {
                line.data.delimiterLength = 1
            } else if lastChar == Symbol.lineFeed {
                if newTotalLength >= 2 && getCharacter(at: Int(line.location) + newTotalLength - 2) == Symbol.carriageReturn {
                    line.data.delimiterLength = 2
                } else if newTotalLength == 1 && line.location > 0 && getCharacter(at: Int(line.location) - 1) == Symbol.carriageReturn {
                    // We need to join this line with the previous line.
                    let previousLine = line.previous
                    changeSet.markLineRemoved(line)
                    documentLineTree.remove(line)
                    let otherChangeSet = setLength(of: previousLine, to: previousLine.value + 1, newLine: &newLine)
                    changeSet.union(with: otherChangeSet)
                } else {
                    line.data.delimiterLength = 1
                }
            } else {
                line.data.delimiterLength = 0
            }
        }
        newLine = line
        return changeSet
    }

    @discardableResult
    private func insertLine(ofLength length: Int, after otherLine: DocumentLineNode) -> DocumentLineNode {
        let data = DocumentLineNodeData(lineHeight: estimatedLineHeight)
        let insertedLine = documentLineTree.insertNode(value: length, data: data, after: otherLine)
        let range = NSRange(location: insertedLine.location, length: length)
        let substring = stringView.substring(in: range)
        let byteCount = substring?.byteCount ?? 0
        insertedLine.data.totalLength = length
        insertedLine.data.byteCount = byteCount
        insertedLine.data.nodeTotalByteCount = byteCount
        insertedLine.data.node = insertedLine
        // Call updateAfterChangingChildren(of:) to update the values of nodeTotalByteCount.
        documentLineTree.updateAfterChangingChildren(of: insertedLine)
        return insertedLine
    }

    private func getCharacter(at location: Int) -> String? {
        let range = NSRange(location: location, length: 1)
        return stringView.substring(in: range)
    }
}

extension DocumentLineTree {
    func yPosition(of node: DocumentLineNode) -> CGFloat {
        var yPosition = node.left?.data.totalLineHeight ?? 0
        var workingNode = node
        while let parentNode = workingNode.parent {
            if workingNode === workingNode.parent?.right {
                if let leftNode = workingNode.parent?.left {
                    yPosition += leftNode.data.totalLineHeight
                }
                yPosition += parentNode.data.lineHeight
            }
            workingNode = parentNode
        }
        return yPosition
    }
}

extension DocumentLineNode {
    var yPosition: CGFloat {
        tree.yPosition(of: self)
    }

    var range: ClosedRange<Int> {
        let _location = location
        return _location ... _location + data.totalLength
    }
}
