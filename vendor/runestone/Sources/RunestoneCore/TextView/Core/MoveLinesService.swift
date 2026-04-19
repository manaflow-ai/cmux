import Foundation

struct MoveLinesOperation {
    let removeRange: NSRange
    let replacementRange: NSRange
    let replacementString: String
    let selectedRange: NSRange
}

final class MoveLinesService {
    private let stringView: StringView
    private let lineManager: LineManager
    private let lineEndingSymbol: String

    init(stringView: StringView, lineManager: LineManager, lineEndingSymbol: String) {
        self.stringView = stringView
        self.lineManager = lineManager
        self.lineEndingSymbol = lineEndingSymbol
    }

    func operationForMovingLines(in selectedRange: NSRange, byOffset lineOffset: Int) -> MoveLinesOperation? {
        // This implementation of moving lines is naive, as it first removes the selected lines and then inserts the text at the target line.
        // That requires two parses of the syntax tree and two operations on our line manager. Ideally we would do this in one operation.
        let isMovingDown = lineOffset > 0
        let selectedLines = lineManager.lines(in: selectedRange)
        guard !selectedLines.isEmpty else {
            return nil
        }
        let firstLine = selectedLines[0]
        let lastLine = selectedLines[selectedLines.count - 1]
        let firstLineIndex = firstLine.index
        var targetLineIndex = firstLineIndex + lineOffset
        if isMovingDown {
            targetLineIndex += selectedLines.count - 1
        }
        guard targetLineIndex >= 0 && targetLineIndex < lineManager.lineCount else {
            return nil
        }
        // Find the line to move the selected text to.
        let targetLine = lineManager.line(atRow: targetLineIndex)
        // Find the range of text to remove. That's the range encapsulating selected lines.
        let removeLocation = firstLine.location
        let removeLength = lastLine.location + lastLine.data.totalLength - removeLocation
        // Find the location to insert the text at.
        var insertLocation = targetLine.location
        if isMovingDown {
            insertLocation += targetLine.data.totalLength - removeLength
        }
        // Update the selected range to match the old one but at the new lines.
        var locationOffset = insertLocation - removeLocation
        // Perform the remove and insert operations.
        var removeRange = NSRange(location: removeLocation, length: removeLength)
        let insertRange = NSRange(location: insertLocation, length: 0)
        var text = stringView.substring(in: removeRange) ?? ""
        if isMovingDown && targetLine.data.delimiterLength == 0 {
            if lastLine.data.delimiterLength > 0 {
                // We're moving to a line with no line break so we'll remove the last line break from the text we're moving.
                // This behavior matches the one of Nova.
                text.removeLast(lastLine.data.delimiterLength)
            }
            // Since the line we're moving to has no line break, we should add one in the beginning of the text.
            text = lineEndingSymbol + text
            locationOffset += lineEndingSymbol.count
        } else if !isMovingDown && lastLine.data.delimiterLength == 0 {
            // The last line we're moving has no line break, so we'll add one.
            text += lineEndingSymbol
            // Adjust the removal range to remove the line break of the line we're moving to.
            if targetLine.data.delimiterLength > 0 {
                removeRange.location -= targetLine.data.delimiterLength
                removeRange.length += targetLine.data.delimiterLength
            }
        }
        let newSelectedRange = NSRange(location: selectedRange.location + locationOffset, length: selectedRange.length)
        return MoveLinesOperation(removeRange: removeRange, replacementRange: insertRange, replacementString: text, selectedRange: newSelectedRange)
    }
}
