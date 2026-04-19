import Foundation

struct TextEditResult {
    let textChange: TextChange
    let lineChangeSet: LineChangeSet
    var didAddOrRemoveLines: Bool {
        let didAddLines = !lineChangeSet.insertedLines.isEmpty
        let didRemoveLines = !lineChangeSet.removedLines.isEmpty
        return didAddLines || didRemoveLines
    }
}

final class TextEditHelper {
    private let stringView: StringView
    private let lineManager: LineManager
    private let lineEndings: LineEnding

    init(stringView: StringView, lineManager: LineManager, lineEndings: LineEnding) {
        self.stringView = stringView
        self.lineManager = lineManager
        self.lineEndings = lineEndings
    }

    func replaceText(in range: NSRange, with newString: String) -> TextEditResult {
        let nsNewString = newString as NSString
        let byteRange = ByteRange(utf16Range: range)
        let oldEndLinePosition = lineManager.linePosition(at: range.location + range.length)!
        stringView.replaceText(in: range, with: newString)
        let lineChangeSet = LineChangeSet()
        let lineChangeSetFromRemovingCharacters = lineManager.removeCharacters(in: range)
        lineChangeSet.union(with: lineChangeSetFromRemovingCharacters)
        let lineChangeSetFromInsertingCharacters = lineManager.insert(nsNewString, at: range.location)
        lineChangeSet.union(with: lineChangeSetFromInsertingCharacters)
        let startLinePosition = lineManager.linePosition(at: range.location)!
        let newEndLinePosition = lineManager.linePosition(at: range.location + nsNewString.length)!
        let textChange = TextChange(byteRange: byteRange,
                                    bytesAdded: newString.byteCount,
                                    oldEndLinePosition: oldEndLinePosition,
                                    startLinePosition: startLinePosition,
                                    newEndLinePosition: newEndLinePosition)
        return TextEditResult(textChange: textChange, lineChangeSet: lineChangeSet)
    }

    func string(byApplying batchReplaceSet: BatchReplaceSet) -> NSString {
        let sortedReplacements = batchReplaceSet.replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
        // swiftlint:disable:next force_cast
        let mutableSubstring = stringView.string.mutableCopy() as! NSMutableString
        var totalChangeInLength = 0
        var replacedRanges: [NSRange] = []
        for replacement in sortedReplacements where !replacedRanges.contains(where: { $0.overlaps(replacement.range) }) {
            let range = replacement.range
            let adjustedRange = NSRange(location: range.location + totalChangeInLength, length: range.length)
            mutableSubstring.replaceCharacters(in: adjustedRange, with: replacement.text)
            replacedRanges.append(replacement.range)
            totalChangeInLength += replacement.text.utf16.count - adjustedRange.length
        }
        return mutableSubstring
    }
}
