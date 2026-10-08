import Foundation

/// A read-only tmux `window_layout` tree. Cells use the host's character
/// grid, including one border cell between siblings; pane ids are host ids.
/// Parsing this value does not resize, select, or create anything remotely.
public struct SSHTmuxLayout: Hashable, Sendable {
    public enum Axis: Hashable, Sendable {
        case leftRight
        case topBottom
    }

    public struct Frame: Hashable, Sendable {
        public let column: Int
        public let row: Int
        public let columns: Int
        public let rows: Int
    }

    public struct Pane: Hashable, Sendable, Identifiable {
        public let id: String
        public let frame: Frame
    }

    public indirect enum Node: Hashable, Sendable {
        case pane(Pane)
        case split(frame: Frame, axis: Axis, children: [Node])

        public var frame: Frame {
            switch self {
            case .pane(let pane): pane.frame
            case .split(let frame, _, _): frame
            }
        }
    }

    public static let maximumBytes = 16 * 1024
    public static let maximumPanes = 256
    public static let maximumDepth = 32
    public static let maximumDimension = 65_535
    public let root: Node
    /// Leaves in deterministic host layout order, without repeated scans.
    public let panes: [Pane]

    /// Accepts the checksum-prefixed format from tmux, never arbitrary shell
    /// text. Truncation, duplicate ids, and overlapping/gapped cells fail.
    public init?(validating text: String) {
        guard (6...Self.maximumBytes).contains(text.utf8.count) else { return nil }
        let bytes = Array(text.utf8)
        guard bytes[4] == 44,
              bytes.prefix(4).allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let expected = UInt16(String(decoding: bytes.prefix(4), as: UTF8.self), radix: 16) else { return nil }
        var checksum: UInt16 = 0
        for byte in bytes.dropFirst(5) {
            checksum = (checksum >> 1) | ((checksum & 1) << 15)
            checksum &+= UInt16(byte)
        }
        guard checksum == expected else { return nil }
        var parser = Parser(bytes: bytes, offset: 5)
        guard let root = try? parser.node(depth: 1), parser.offset == bytes.count,
              root.frame.column == 0, root.frame.row == 0 else { return nil }
        self.root = root
        panes = parser.panes
    }

    private struct InvalidLayout: Error {}

    private struct Parser {
        let bytes: [UInt8]
        var offset: Int
        var panes: [Pane] = []
        var paneIDs = Set<String>()
        var cells = 0

        mutating func node(depth: Int) throws -> Node {
            guard depth <= SSHTmuxLayout.maximumDepth, cells < SSHTmuxLayout.maximumPanes * 2 - 1 else {
                throw InvalidLayout()
            }
            cells += 1
            let columns = try number(maximum: SSHTmuxLayout.maximumDimension)
            try take(120) // x
            let rows = try number(maximum: SSHTmuxLayout.maximumDimension)
            try take(44)
            let column = try number(maximum: SSHTmuxLayout.maximumDimension)
            try take(44)
            let row = try number(maximum: SSHTmuxLayout.maximumDimension)
            guard columns > 0, rows > 0,
                  column + columns <= SSHTmuxLayout.maximumDimension,
                  row + rows <= SSHTmuxLayout.maximumDimension else { throw InvalidLayout() }
            let frame = Frame(column: column, row: row, columns: columns, rows: rows)
            guard offset < bytes.count else { throw InvalidLayout() }
            if bytes[offset] == 44 {
                offset += 1
                let id = "%\(try number(maximum: Int(UInt32.max)))"
                guard panes.count < SSHTmuxLayout.maximumPanes, paneIDs.insert(id).inserted else { throw InvalidLayout() }
                let pane = Pane(id: id, frame: frame)
                panes.append(pane)
                return .pane(pane)
            }
            let axis: Axis
            let close: UInt8
            switch bytes[offset] {
            case 123: axis = .leftRight; close = 125 // { }
            case 91: axis = .topBottom; close = 93 // [ ]
            default: throw InvalidLayout()
            }
            offset += 1
            var children: [Node] = []
            while true {
                children.append(try node(depth: depth + 1))
                guard offset < bytes.count else { throw InvalidLayout() }
                if bytes[offset] == close { offset += 1; break }
                try take(44)
            }
            guard children.count >= 2, Self.fits(children, frame: frame, axis: axis) else { throw InvalidLayout() }
            return .split(frame: frame, axis: axis, children: children)
        }

        private static func fits(_ children: [Node], frame: Frame, axis: Axis) -> Bool {
            var next = axis == .leftRight ? frame.column : frame.row
            for child in children {
                let cell = child.frame
                switch axis {
                case .leftRight:
                    guard cell.column == next, cell.row == frame.row, cell.rows == frame.rows else { return false }
                    next += cell.columns + 1
                case .topBottom:
                    guard cell.row == next, cell.column == frame.column, cell.columns == frame.columns else { return false }
                    next += cell.rows + 1
                }
            }
            return next - 1 == (axis == .leftRight ? frame.column + frame.columns : frame.row + frame.rows)
        }

        private mutating func number(maximum: Int) throws -> Int {
            var value = 0
            var count = 0
            while offset < bytes.count, (48...57).contains(bytes[offset]) {
                let digit = Int(bytes[offset] - 48)
                guard count < 10, value <= (maximum - digit) / 10 else { throw InvalidLayout() }
                value = value * 10 + digit
                count += 1
                offset += 1
            }
            guard count > 0 else { throw InvalidLayout() }
            return value
        }

        private mutating func take(_ byte: UInt8) throws {
            guard offset < bytes.count, bytes[offset] == byte else { throw InvalidLayout() }
            offset += 1
        }
    }
}
