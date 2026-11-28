import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Synthetic screen content drawn straight into a full-range NV12 (420f) buffer,
/// mirroring the host workloads in PROTOCOL.md. The marker is drawn on top by the caller.
protocol SyntheticWorkload {
    var name: String { get }
    /// Fills the Y and interleaved UV planes for frame `t` (60 fps cadence).
    func draw(frame t: Int, y: UnsafeMutablePointer<UInt8>, yStride: Int,
              uv: UnsafeMutablePointer<UInt8>, uvStride: Int, width: Int, height: Int)
}

/// Flat mid-gray. Only the marker changes between frames.
struct FlatGrayWorkload: SyntheticWorkload {
    let name = "marker"
    func draw(frame t: Int, y: UnsafeMutablePointer<UInt8>, yStride: Int,
              uv: UnsafeMutablePointer<UInt8>, uvStride: Int, width: Int, height: Int) {
        for row in 0..<height { (y + row * yStride).update(repeating: 128, count: width) }
        for row in 0..<(height / 2) { (uv + row * uvStride).update(repeating: 128, count: width) }
    }
}

/// Terminal-like black-on-white monospace text scrolling one line every two frames (~30 lines/s).
final class ScrollingTextWorkload: SyntheticWorkload {
    let name = "text"
    private let canvas: [UInt8]
    private let canvasWidth: Int
    private let canvasRows: Int
    let lineHeight: Int

    init(width: Int, height: Int, frames: Int) {
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let lh = 16
        lineHeight = lh
        let screenLines = height / lh + 1
        let lines = screenLines + frames / 2 + 2
        canvasWidth = width
        canvasRows = lines * lh
        var buf = [UInt8](repeating: 255, count: width * canvasRows)
        let words = ["let", "var", "func", "return", "cargo", "build", "error:", "warning:", "src/main.rs", "ok",
                     "test", "passed", "0x7f3a", "--release", "git", "commit", "->", "{", "}", "self", "match",
                     "Some(x)", "None", "async", "await", "123.45ms", "[INFO]", "[DEBUG]", "panic!", "Vec<u8>"]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: seed >> 33)
        }
        let rows = canvasRows
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(false)
            let black = CGColor(gray: 0, alpha: 1)
            for i in 0..<lines {
                var s = String(repeating: " ", count: next() % 6)
                while s.count < 60 + next() % 160 { s += words[next() % words.count] + " " }
                let attr = NSAttributedString(string: s, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
                ])
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: 4, y: rows - (i + 1) * lh + 4)
                CTLineDraw(line, ctx)
            }
        }
        canvas = buf
    }

    func draw(frame t: Int, y: UnsafeMutablePointer<UInt8>, yStride: Int,
              uv: UnsafeMutablePointer<UInt8>, uvStride: Int, width: Int, height: Int) {
        let top = min((t / 2) * lineHeight, canvasRows - height)
        canvas.withUnsafeBufferPointer { c in
            guard let base = c.baseAddress else { return }
            for row in 0..<height {
                (y + row * yStride).update(from: base + (top + row) * canvasWidth, count: min(width, canvasWidth))
            }
        }
        for row in 0..<(height / 2) { (uv + row * uvStride).update(repeating: 128, count: width) }
    }
}

/// Full-screen moving color gradient with a moving pseudo-random texture. Worst case.
final class MotionWorkload: SyntheticWorkload {
    let name = "motion"
    private let noise: [UInt8]

    init() {
        var seed: UInt32 = 12345
        noise = (0..<(256 * 256)).map { _ in
            seed = seed &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
    }

    func draw(frame t: Int, y: UnsafeMutablePointer<UInt8>, yStride: Int,
              uv: UnsafeMutablePointer<UInt8>, uvStride: Int, width: Int, height: Int) {
        noise.withUnsafeBufferPointer { nz in
            for row in 0..<height {
                let p = y + row * yStride
                let nrow = ((row + t * 3) & 255) * 256
                for x in 0..<width {
                    let g = (x * 192 / width + row * 64 / height + t * 4) & 255
                    p[x] = UInt8(truncatingIfNeeded: (g * 3 / 4) + Int(nz[nrow + ((x + t * 5) & 255)]) / 4)
                }
            }
        }
        for row in 0..<(height / 2) {
            let p = uv + row * uvStride
            let v = UInt8(truncatingIfNeeded: (row * 255 / (height / 2) + t * 3) & 255)
            for cx in 0..<(width / 2) {
                p[2 * cx] = UInt8(truncatingIfNeeded: (cx * 255 / (width / 2) + t * 2) & 255)
                p[2 * cx + 1] = v
            }
        }
    }
}
