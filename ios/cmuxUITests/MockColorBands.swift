import CMUXMobileCore
import Network
import UIKit
import XCTest


/// Shared definition of the deterministic color-band test pattern, used by
/// both the mock host (to emit it) and the render test (to verify it).
enum MockColorBands {
    /// Strong, easily separated colors: red, green, blue.
    static let colors: [(r: Int, g: Int, b: Int)] = [(210, 40, 40), (40, 180, 70), (50, 90, 220)]

    /// Rows of solid color in THICK bands (``bandHeight`` rows per color)
    /// cycling through ``colors``. Each row is a run of full-block glyphs
    /// (`█`, U+2588) in a 24-bit FOREGROUND color, so every cell is filled by a
    /// real character. Foreground glyphs (unlike a background `ESC[K` fill)
    /// survive a terminal resize/reflow, so the bands stay visible as the font
    /// is zoomed (which resizes the grid). Thick bands (not 1-row stripes)
    /// stay clearly distinguishable at any cell size, and the repeating cycle
    /// means any viewport height / scroll position shows several clean bands.
    static let bandHeight = 6
    static func lines(count: Int = 96) -> [String] {
        // Wider than any phone terminal grid so the block run fills each row.
        let block = String(repeating: "\u{2588}", count: 220)
        var out: [String] = []
        out.reserveCapacity(count + 1)
        for i in 0..<count {
            let c = colors[(i / bandHeight) % colors.count]
            out.append("\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m\(block)")
        }
        out.append("\u{1B}[0m")
        return out
    }
}

