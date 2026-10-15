/// Hides the cursor in a still of the terminal and keeps the character under
/// it (VERIFY-round8 claim 8: the saved frame filled the cursor's cell with
/// the background, so `› Ask Codex` read `› sk Codex`).
///
/// Works on the cell's pixels (RGBA8, opaque), whatever cursor Ghostty drew:
///
/// - A block (most of the cell far from the background): Ghostty draws the
///   glyph in the background colour over the cursor's colour. Each pixel's
///   mix between the two is read back and drawn reversed, the glyph in the
///   cursor's colour (the text colour) over the background, antialiasing kept.
/// - A hollow box (unfocused), a bar or an underline: lines at the cell's
///   edges that are almost all cursor are set to the background; the glyph
///   inside is left as drawn.
/// - Nothing drawn (the blink's off phase): the cell is left alone.
public enum TerminalCursorErase {
    public struct Rect: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Sum of the channel differences above which a pixel is not background.
    static let farThreshold = 60

    public static func erase(pixels: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, rect: Rect,
                             background: (UInt8, UInt8, UInt8)) {
        guard rect.width > 0, rect.height > 0 else { return }
        let b = (Int(background.0), Int(background.1), Int(background.2))
        func pixel(_ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt8> {
            pixels + (rect.y + y) * bytesPerRow + (rect.x + x) * 4
        }
        func far(_ p: UnsafeMutablePointer<UInt8>) -> Bool {
            abs(Int(p[0]) - b.0) + abs(Int(p[1]) - b.1) + abs(Int(p[2]) - b.2) > farThreshold
        }
        var farCount = 0
        var counts: [UInt32: Int] = [:]
        for y in 0..<rect.height {
            for x in 0..<rect.width {
                let p = pixel(x, y)
                guard far(p) else { continue }
                farCount += 1
                counts[UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]), default: 0] += 1
            }
        }
        if farCount * 2 >= rect.width * rect.height, let key = counts.max(by: { $0.value < $1.value })?.key {
            // A block: p = C + a (B - C), a = the glyph's coverage; drawn as B + a (C - B).
            let c = (Int(key >> 16 & 0xFF), Int(key >> 8 & 0xFF), Int(key & 0xFF))
            let d = (b.0 - c.0, b.1 - c.1, b.2 - c.2)
            let dd = Double(d.0 * d.0 + d.1 * d.1 + d.2 * d.2)
            guard dd > 0 else { return }
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let p = pixel(x, y)
                    let dot = Double((Int(p[0]) - c.0) * d.0 + (Int(p[1]) - c.1) * d.1 + (Int(p[2]) - c.2) * d.2)
                    let a = min(1, max(0, dot / dd))
                    p[0] = UInt8((Double(b.0) - a * Double(d.0)).rounded())
                    p[1] = UInt8((Double(b.1) - a * Double(d.1)).rounded())
                    p[2] = UInt8((Double(b.2) - a * Double(d.2)).rounded())
                }
            }
            return
        }
        // Edge lines (an outline, a bar, an underline), decided on the cell
        // as drawn, then cleared.
        func lineIsCursor(_ points: [(Int, Int)]) -> Bool {
            !points.isEmpty && points.filter { far(pixel($0.0, $0.1)) }.count * 5 >= points.count * 4
        }
        var cleared: [(Int, Int)] = []
        let rows = (0..<rect.height).map { y in (0..<rect.width).map { ($0, y) } }
        let columns = (0..<rect.width).map { x in (0..<rect.height).map { (x, $0) } }
        for edge in [Array(rows), Array(rows.reversed()), Array(columns), Array(columns.reversed())] {
            let depth = max(1, min(3, edge.count / 4))
            for line in edge.prefix(depth) {
                guard lineIsCursor(line) else { break }
                cleared += line
            }
        }
        for (x, y) in cleared {
            let p = pixel(x, y)
            p[0] = background.0
            p[1] = background.1
            p[2] = background.2
        }
    }
}
