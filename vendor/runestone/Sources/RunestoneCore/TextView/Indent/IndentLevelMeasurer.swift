import Foundation

final class IndentLevelMeasurer {
    private let stringView: StringView

    init(stringView: StringView) {
        self.stringView = stringView
    }

    func indentLevel(lineStartLocation: Int, lineTotalLength: Int, tabLength: Int) -> Int {
        var indentLength = 0
        for i in 0 ..< lineTotalLength {
            let range = NSRange(location: lineStartLocation + i, length: 1)
            if let str = stringView.substring(in: range)?.first {
                if str == Symbol.Character.tab {
                    indentLength += tabLength - (indentLength % tabLength)
                } else if str == Symbol.Character.space {
                    indentLength += 1
                } else {
                    break
                }
            }
        }
        return indentLength / tabLength
    }
}
