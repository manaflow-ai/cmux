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
// centre, so the origin is the middle of every position from which all 20 centres read cleanly.

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

// Every cell size from 4 px (a 32 px host cell shown at an eighth) to 128 px; the size with the most
// clean positions is the true one, since a wrong size drifts off the cells within 20 of them.
var best: (count: Int, cell: Int, xs: [Int], ys: [Int]) = (0, 0, [], [])
for cell in 4 ... 128 {
    let span = 20 * cell
    guard span < width else { break }
    var xs: [Int] = [], ys: [Int] = []
    var y = 0
    while y + cell <= height {
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
// One marker: the positions that read it form one block about a cell wide and high (every x from
// half a cell left of the first cell's edge to half a cell right of it). Its middle is that edge,
// the origin observe takes.
let minY = best.ys.min()!
let block = zip(best.xs, best.ys).filter { $0.1 < minY + best.cell }
let originX = (block.map { $0.0 }.min()! + block.map { $0.0 }.max()!) / 2
let originY = (block.map { $0.1 }.min()! + block.map { $0.1 }.max()!) / 2
let cell = best.cell
print("origin \(originX),\(originY) cell \(cell) at \(originX + 22 * cell),\(originY + cell / 2)")
