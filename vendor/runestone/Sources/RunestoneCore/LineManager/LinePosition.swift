import Foundation

final class LinePosition: Hashable, Equatable {
    let row: Int
    let column: Int

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    convenience init(_ point: TreeSitterTextPoint) {
        let row = Int(point.row)
        let column = Int(point.column / 2)
        self.init(row: row, column: column)
    }

    static func == (lhs: LinePosition, rhs: LinePosition) -> Bool {
        lhs.row == rhs.row && lhs.column == rhs.column
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(row)
        hasher.combine(column)
    }
}

extension LinePosition: CustomDebugStringConvertible {
    var debugDescription: String {
        "[LinePosition row=\(row) column=\(column)]"
    }
}
