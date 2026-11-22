// Where a third-party viewer (Moonlight, Screen Sharing.app, Windows App) shows the host's latency
// marker on this Mac's main display, in the pixels `cmux-rd observe` captures (the display fitted into
// 3840x2160, as cmux-rd-host/src/mac/capture.rs `fit` does), so observe can time the marker through a
// viewer cmux did not write.
//
//   swiftc -O -o screen-eval-marker-locate marker-locate.swift
//   screen-eval-marker-locate SCREENSHOT.png    (a `screencapture -x -D 1` of the viewer's display)
//
// Prints `origin X,Y cell C at X,Y`: the marker's top-left, its cell size and the middle of its gray
// click pad (cells 20 to 23, never read), all in observe's pixels. Exit 1 when no marker is visible.
// The marker (cmux-rd-host/scripts/mac-marker): 20 square cells in a row, cells 0..15 dark or light
// for the counter's bits, cells 16..19 the guard light, dark, light, dark. observe reads each cell's
// centre. A coarse search finds one position from which all 20 centres read; the origin and cell size
// then come from the guard cells' own edges, measured in the pixels.

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("screen-eval-marker-locate: \(message)\n".utf8))
    exit(code)
}

guard CommandLine.arguments.count == 2 else { fail("usage: screen-eval-marker-locate SCREENSHOT.png") }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("cannot read \(CommandLine.arguments[1])") }

// observe's capture size: the display fitted into 3840x2160, keeping its aspect, never enlarged, even.
let scale = min(3840 / Double(image.width), 2160 / Double(image.height), 1)
let even = { (v: Double) in Int(v.rounded()) & ~1 }
let width = even(Double(image.width) * scale), height = even(Double(image.height) * scale)
var luma = [UInt8](repeating: 0, count: width * height)
// The context draws into luma only inside this closure, where its storage is pinned.
let drawn = luma.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return false }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drawn else { fail("no grayscale context") }

// The same thresholds as observe::read_marker: <= 60 dark, >= 190 light, anything else unreadable.
func bit(_ x: Int, _ y: Int) -> Bool? {
    guard x >= 0, y >= 0, x < width, y < height else { return nil }
    let v = luma[y * width + x]
    return v <= 60 ? false : v >= 190 ? true : nil
}

func reads(_ x: Int, _ y: Int, _ cell: Int) -> Bool {
    let row = y + cell / 2
    let guardBits: [Bool] = [true, false, true, false]
    for (i, want) in guardBits.enumerated() where bit(x + (16 + i) * cell + cell / 2, row) != want { return false }
    for i in 0 ..< 16 where bit(x + i * cell + cell / 2, row) == nil { return false }
    return true
}

// The marker sits at the top of the host's display, so it shows in the top part of the viewer's, below
// at most a letterbox band: scanning the top third keeps a locate well under a second.
let scanHeight = height / 3
// Every cell size from 4 px (a 32 px host cell shown at an eighth) to 128 px. This only finds a hit inside
// the marker: the size with the most clean positions is not always the true one. When the marker touches
// the image's left edge (a viewer showing the host's display from x 0), the true size's clean positions
// are clipped to half a cell, and a size one pixel smaller, whose centres stay inside their cells for
// most of a cell, gets more (seen: cell 31 at x 18 for a marker at 0 with cell 32).
var best: (count: Int, cell: Int, xs: [Int], ys: [Int]) = (0, 0, [], [])
for cell in 4 ... 128 {
    let span = 20 * cell
    guard span < width else { break }
    var xs: [Int] = [], ys: [Int] = []
    var y = 0
    while y + cell <= scanHeight {
        var x = 0
        while x + span <= width {
            if reads(x, y, cell) {
                xs.append(x)
                ys.append(y)
            }
            x += 1
        }
        y += 1
    }
    if xs.count > best.count { best = (xs.count, cell, xs, ys) }
}
guard best.count > 0 else { fail("no marker visible on the display", 1) }

// The topmost, then leftmost, hit: every centre reads from it, so the row through its centres crosses
// the marker and its guard cell 18's centre lies in cell 18, light between the dark cells 17 and 19.
let hitY = best.ys.min()!
let hitX = zip(best.xs, best.ys).filter { $0.1 == hitY }.map { $0.0 }.min()!
let row = hitY + best.cell / 2

// Luma below `threshold` is the dark side of an edge, at or above it the light side. 125 is midway
// between the marker's black and white, so a scaled, smoothed edge crosses it where the edge was.
let mid = 125
func light(_ x: Int, _ y: Int, _ threshold: Int) -> Bool { Int(luma[y * width + x]) >= threshold }

/// From (x, y), steps by (dx, dy) while the pixels stay on the start pixel's side of `threshold`. The
/// last pixel of that run, and whether the run reached the image's edge (the boundary is not visible).
func runEnd(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int, _ threshold: Int = mid) -> (x: Int, y: Int, clipped: Bool) {
    let side = light(x, y, threshold)
    var (x, y) = (x, y)
    while true {
        let (nx, ny) = (x + dx, y + dy)
        guard nx >= 0, ny >= 0, nx < width, ny < height else { return (x, y, true) }
        if light(nx, ny, threshold) != side { return (x, y, false) }
        (x, y) = (nx, ny)
    }
}

// The left edges (first pixel) of guard cells 17, 18 and 19 are always visible: light 16, dark 17, light
// 18, dark 19 alternate. Cell 16's left edge shows when bit 15 is dark and cell 20's (cell 19's right
// edge) when the gray click pad or the background differs from dark; each counts only when it sits
// about a cell from its neighbour, so a bit or background that continues a guard cell's colour is
// never taken for its edge. Edges only: the left of the marker may be clipped by the image.
let centre18 = hitX + 18 * best.cell + best.cell / 2
let run18 = (left: runEnd(centre18, row, -1, 0), right: runEnd(centre18, row, 1, 0))
guard !run18.left.clipped, !run18.right.clipped else { fail("marker guard cell 18 has no edges", 1) }
let left18 = run18.left.x, left19 = run18.right.x + 1
let run17 = runEnd(left18 - 1, row, -1, 0)
guard !run17.clipped else { fail("marker guard cell 17 has no left edge", 1) }
let left17 = run17.x
var edges: [(cell: Int, x: Int)] = [(17, left17), (18, left18), (19, left19)]
let estimate = Double(left19 - left17) / 2
let close = { (span: Int) in abs(Double(span) - estimate) <= estimate / 4 }
let run16 = runEnd(left17 - 1, row, -1, 0)
if !run16.clipped, close(left17 - run16.x) { edges.append((16, run16.x)) }
// Right of cell 19 the pad is gray, not light: the edge is midway between cell 19's dark and the level
// just past it, read half a cell beyond the edge.
let dark19 = Int(luma[row * width + min(width - 1, left19 + Int(estimate / 2))])
let beyond = Int(luma[row * width + min(width - 1, left19 + Int(estimate * 1.5))])
if beyond - dark19 >= 40 {
    let run19 = runEnd(left19, row, 1, 0, (dark19 + beyond + 1) / 2)
    if !run19.clipped, close(run19.x + 1 - left19) { edges.append((20, run19.x + 1)) }
}
// Edge k sits at origin + k * cell: a least-squares line through the edges gives both.
let n = Double(edges.count)
let meanK = edges.map { Double($0.cell) }.reduce(0, +) / n
let meanX = edges.map { Double($0.x) }.reduce(0, +) / n
let slope = edges.map { (Double($0.cell) - meanK) * (Double($0.x) - meanX) }.reduce(0, +)
    / edges.map { (Double($0.cell) - meanK) * (Double($0.cell) - meanK) }.reduce(0, +)
let cell = Int(slope.rounded())
guard cell >= 4 else { fail("marker guard cells measure \(slope) px", 1) }
// observe steps a whole number of pixels per cell; when the true cell is fractional (a scaled viewer),
// shifting the origin by 10 cells' worth of the difference splits the drift between cells 0 and 19.
let originX = Int((meanX - meanK * slope + 10 * (slope - Double(cell))).rounded())

// Vertically, down the column through each guard cell's centre: a light cell's run stops where the
// background above or below is dark, a dark cell's where it is light, so the tightest top and bottom
// over the four columns are the marker's. The top is clipped at the image's top edge: then the bottom
// one cell up.
var top = 0, topSeen = false, bottom = height, bottomSeen = false
for i in 16 ..< 20 {
    let x = min(width - 1, max(0, originX + i * cell + cell / 2))
    let up = runEnd(x, row, 0, -1), down = runEnd(x, row, 0, 1)
    if !up.clipped, up.y >= top { top = up.y; topSeen = true }
    if !down.clipped, down.y + 1 <= bottom { bottom = down.y + 1; bottomSeen = true }
}
let originY = topSeen ? top : bottomSeen ? bottom - cell : 0
guard reads(originX, originY, cell) else {
    fail("marker edges give origin \(originX),\(originY) cell \(cell), whose centres do not read", 1)
}
print("origin \(originX),\(originY) cell \(cell) at \(originX + 22 * cell),\(originY + cell / 2)")
