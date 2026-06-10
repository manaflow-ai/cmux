import CMUXMobileCore
import Network
import UIKit
import XCTest


// MARK: - Color Band Rendering Tests
extension cmuxUITests {
    /// Pixel-level regression for the blank / garbled terminal class. Buffer
    /// checks (``assertTerminalRow``) false-passed while the screen was blank,
    /// so this gates on the actual on-screen composited pixels via
    /// `XCUIScreenshot`. The mock host streams repeating red/green/blue
    /// full-row color bands; at every discrete zoom level the rendered surface
    /// must show those bands (>=3 distinct strong colors) and each band row
    /// must be horizontally uniform (no torn / mis-scaled / garbled frame).
    @MainActor
    func testTerminalRendersColorBandsAcrossZoomLevels() async throws {
        // The selected terminal streams the repeating R/G/B color bands on
        // attach, so the bands render without a flaky dropdown switch.
        let server = try MobileSyncMockHostServer(defaultTerminalLines: MockColorBands.lines())
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port, assertStatusRows: false)

        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // Verify clean bands at the attached size first (no zoom interaction).
        assertCleanColorBands(of: surface, level: 0)

        // Then sweep zoom sizes via the keyboard-accessory buttons, checking
        // the render stays clean (not blank / garbled) at each settled level.
        surface.tap()
        let zoomOut = app.buttons["terminal.inputAccessory.zoomOut"]
        let zoomIn = app.buttons["terminal.inputAccessory.zoomIn"]
        XCTAssertTrue(zoomOut.waitForExistence(timeout: 6), "zoom controls should appear")

        for _ in 0..<10 where zoomOut.isEnabled { zoomOut.tap() }
        var level = 1
        while level < 8 {
            assertCleanColorBands(of: surface, level: level)
            level += 1
            guard zoomIn.isEnabled else { break }
            zoomIn.tap()
            zoomIn.tap()
        }
    }

    @MainActor
    private func assertCleanColorBands(
        of surface: XCUIElement,
        level: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        // The off-main renderer presents a frame behind, so right after a
        // keyboard transition or rapid zoom the surface can be momentarily
        // blank/stale. Poll until the bands settle into a clean state rather
        // than judging a single frame (sleeps are acceptable in tests).
        var lastDetail = "no frames sampled"
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.4)
            guard let cg = surface.screenshot().image.cgImage else {
                lastDetail = "no screenshot image"
                continue
            }
            let pixels = BitmapPixels(cg)

            // Vertical strip down the horizontal center, in the upper 55%
            // (clear of the keyboard). Clean bands produce many distinct,
            // strongly-colored samples; a blank screen produces near-zero.
            let strip = (0..<24).map { i -> RGB in
                let y = 0.03 + 0.52 * Double(i) / 23.0
                return pixels.color(xUnit: 0.5, yUnit: y)
            }
            let strong = strip.filter { $0.isStrong }
            let distinct = RGB.distinctCount(strong, tolerance: 60)

            // A torn / mis-scaled frame breaks horizontal uniformity within a
            // band row. Sample left/center/right of a few rows; where all three
            // are strongly colored they must match.
            var uniform = true
            for yUnit in [0.12, 0.30, 0.48] {
                let l = pixels.color(xUnit: 0.22, yUnit: yUnit)
                let c = pixels.color(xUnit: 0.50, yUnit: yUnit)
                let r = pixels.color(xUnit: 0.78, yUnit: yUnit)
                guard l.isStrong, c.isStrong, r.isStrong else { continue }
                if !(l.isClose(to: c, tolerance: 70) && c.isClose(to: r, tolerance: 70)) {
                    uniform = false
                }
            }

            lastDetail = "strong=\(strong.count)/24 distinct=\(distinct) uniform=\(uniform) strip=\(strip)"
            // Clean banded rendering: horizontally uniform (not garbled/torn)
            // AND either several distinct bands (lower zoom) or one band that
            // solidly fills the keyboard-clear strip (higher zoom, where a
            // single thick band can span the whole window). Blank => no strong
            // pixels; garbled => not uniform.
            let enoughBands = (distinct >= 2 && strong.count >= 6)
                || (distinct == 1 && strong.count >= 16)
            if uniform, enoughBands {
                return
            }
        }
        XCTFail(
            "zoom level \(level): never rendered clean color bands. last: \(lastDetail)",
            file: file, line: line
        )
    }

    /// A sampled pixel.
    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        /// A clearly-colored pixel: a bright, saturated channel mix, ignoring
        /// the near-black terminal background.
        var isStrong: Bool {
            let mx = max(r, g, b), mn = min(r, g, b)
            return mx >= 110 && (mx - mn) >= 50
        }
        func isClose(to o: RGB, tolerance: Int) -> Bool {
            abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
        }
        var description: String { "(\(r),\(g),\(b))" }
        static func distinctCount(_ xs: [RGB], tolerance: Int) -> Int {
            var reps: [RGB] = []
            for x in xs where !reps.contains(where: { $0.isClose(to: x, tolerance: tolerance) }) {
                reps.append(x)
            }
            return reps.count
        }
    }

    /// Reads RGB pixels out of a `CGImage` (an `XCUIScreenshot`'s image) by
    /// unit coordinates.
    private struct BitmapPixels {
        let width: Int
        let height: Int
        private let data: [UInt8]
        private let bytesPerRow: Int

        init(_ cg: CGImage) {
            let w = cg.width
            let h = cg.height
            let bpr = w * 4
            var buf = [UInt8](repeating: 0, count: max(1, h * bpr))
            let cs = CGColorSpaceCreateDeviceRGB()
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bpr,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            bytesPerRow = bpr
            data = buf
        }

        func color(xUnit: Double, yUnit: Double) -> RGB {
            guard width > 0, height > 0 else { return RGB(r: 0, g: 0, b: 0) }
            let x = min(width - 1, max(0, Int(xUnit * Double(width))))
            let y = min(height - 1, max(0, Int(yUnit * Double(height))))
            let o = y * bytesPerRow + x * 4
            return RGB(r: Int(data[o]), g: Int(data[o + 1]), b: Int(data[o + 2]))
        }
    }

}
