import Foundation

final class LineEndingDetector {
    private let lineManager: LineManager
    private let stringView: StringView

    init(lineManager: LineManager, stringView: StringView) {
        self.lineManager = lineManager
        self.stringView = stringView
    }

    func detect() -> LineEnding? {
        var shouldScan = true
        let iterator = lineManager.createLineIterator()
        let lineCount = lineManager.lineCount
        var scannedLineCount = 0
        var lineEndingCountMap: [LineEnding: Int] = [:]
        while let line = iterator.next(), shouldScan {
            let lineLocation = line.location
            let lineLength = line.data.totalLength
            let delimiterLength = line.data.delimiterLength
            let delimiterRange = NSRange(location: lineLocation + lineLength - delimiterLength, length: delimiterLength)
            if let character = stringView.substring(in: delimiterRange), let lineEnding = LineEnding(symbol: character) {
                scannedLineCount += 1
                let count = lineEndingCountMap[lineEnding] ?? 0
                lineEndingCountMap[lineEnding] = count + 1
            }
            let hasScannedEnoughLines = scannedLineCount >= min(lineCount, 20)
            if hasScannedEnoughLines {
                shouldScan = false
            }
        }
        let fallbackOrder = LineEnding.allCases
        let maxCountLineEnding = lineEndingCountMap.max { lhsPair, rhsPair in
            if lhsPair.value < rhsPair.value {
                return true
            } else if lhsPair.value > rhsPair.value {
                return false
            } else {
                let lhsIndex = fallbackOrder.firstIndex(of: lhsPair.key)!
                let rhsIndex = fallbackOrder.firstIndex(of: rhsPair.key)!
                return lhsIndex > rhsIndex
            }
        }
        return maxCountLineEnding?.key
    }
}
