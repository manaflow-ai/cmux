import AppKit
import CoreGraphics
import ImageIO
import XCTest

/// Splitting a text-filled pane must never paint the source pane's glyphs
/// inside the new pane (https://github.com/manaflow-ai/cmux/issues/13387).
///
/// The test types a command into the launch terminal that fills it with
/// magenta text, presses Cmd+Shift+D through the real key path, and captures
/// the window as fast as XCTest allows for the next few seconds. A frame is
/// acceptable while it still shows the pre-split layout (the split has not
/// committed yet) and once the region the new pane occupies is free of
/// magenta. A frame that shows the new pane's chrome at the pre-split midline
/// together with the source text below it is the reported glitch. The first
/// frames of the transition are attached to the result bundle as evidence.
///
/// Everything goes through the keyboard and screenshots, like the report; the
/// control socket is not involved (hosted runners do not always answer it
/// from the test process).
final class SplitPaneBackgroundUITests: SettingsUITestCase {
    func testSplitDownNeverPaintsSourceTextInsideNewPane() throws {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-split-bg-\(UUID().uuidString.prefix(8))"
        launchAndActivate(app)
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Expected the main window")
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "Expected the launch terminal")
        XCTAssertTrue(poll(timeout: 10) { terminal.frame.height > 200 }, "Expected a tall terminal: \(terminal.frame)")
        let windowFrame = window.frame
        let terminalFrame = terminal.frame
        // Give the pane keyboard focus the way a user would, then let the
        // shell reach its prompt before typing.
        terminal.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        let probeShot = window.screenshot()
        let probe = try XCTUnwrap(ScreenshotImage(screenshot: probeShot), "Could not decode the launch frame")
        let scale = CGFloat(probe.width) / max(windowFrame.width, 1)
        let regions = Regions(terminalFrame: terminalFrame, windowFrame: windowFrame, scale: scale)

        // Dense magenta text: the only magenta pixels in the window come from
        // the source terminal, so its glyphs can be located in any frame.
        let fill = "clear; i=1; while [ $i -le 400 ]; do printf '\\033[38;2;255;0;255mSOURCE-13387 %03d " +
            "################################################################\\033[0m\\n' \"$i\"; " +
            "i=$((i + 1)); done\n"
        app.typeText(fill)
        var beforeShot = window.screenshot()
        var before = try XCTUnwrap(ScreenshotImage(screenshot: beforeShot), "Could not decode the pre-split frame")
        XCTAssertTrue(
            poll(timeout: 30, interval: 0.5) {
                beforeShot = window.screenshot()
                guard let image = ScreenshotImage(screenshot: beforeShot) else { return false }
                before = image
                return image.magentaCount(in: regions.newPane) > 1_000
            },
            "Expected dense source text in the region the new pane takes; " +
                "magenta=\(before.magentaCount(in: regions.newPane)) terminal=\(terminalFrame) window=\(windowFrame)"
        )
        // Let the fill finish scrolling and the cursor settle so the pre-split
        // reference frame is the steady state.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        beforeShot = window.screenshot()
        before = try XCTUnwrap(ScreenshotImage(screenshot: beforeShot), "Could not decode the pre-split frame")
        let baselineMagenta = before.magentaCount(in: regions.newPane)
        attach(beforeShot, name: "00 before split (magenta below midline: \(baselineMagenta))")
        XCTAssertGreaterThan(baselineMagenta, 1_000)

        let splitAt = Date()
        app.typeKey("d", modifierFlags: [.command, .shift])
        var frames: [(offset: TimeInterval, screenshot: XCUIScreenshot)] = []
        let deadline = splitAt.addingTimeInterval(3.0)
        while Date() < deadline, frames.count < 80 {
            let screenshot = window.screenshot()
            frames.append((Date().timeIntervalSince(splitAt), screenshot))
        }
        XCTAssertTrue(poll(timeout: 15) { app.textViews.count >= 2 }, "Expected the split to create a second terminal")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let settledShot = window.screenshot()
        let settled = try XCTUnwrap(ScreenshotImage(screenshot: settledShot), "Could not decode the settled frame")
        attach(settledShot, name: "99 settled (magenta below midline: \(settled.magentaCount(in: regions.newPane)))")
        XCTAssertLessThan(
            settled.magentaCount(in: regions.newPane), baselineMagenta / 10,
            "Expected the new pane to be free of source text once the split settled"
        )

        var violations: [String] = []
        var attachedAfterChrome = 0
        var lastPreSplit: (label: String, screenshot: XCUIScreenshot)?
        for (index, frame) in frames.enumerated() {
            guard let image = ScreenshotImage(screenshot: frame.screenshot) else { continue }
            let magenta = image.magentaCount(in: regions.newPane)
            let chromeChanged = image.changedCount(in: regions.midlineBand, against: before) >= Regions.chromeChangeThreshold
            let label = String(
                format: "%02d t+%.0fms magentaBelowMidline=%d chrome=%@",
                index + 1, frame.offset * 1000, magenta, chromeChanged ? "split" : "pre-split"
            )
            let isViolation = chromeChanged && magenta > baselineMagenta / 10
            if isViolation { violations.append(label) }
            // Keep the transition itself as evidence: the last pre-split
            // frame, the first frames after the chrome changed, and every
            // violation.
            guard chromeChanged else {
                lastPreSplit = (label, frame.screenshot)
                continue
            }
            if let pending = lastPreSplit {
                attach(pending.screenshot, name: pending.label)
                lastPreSplit = nil
            }
            if isViolation || attachedAfterChrome < 6 {
                attach(frame.screenshot, name: (isViolation ? "VIOLATION " : "") + label)
                attachedAfterChrome += 1
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Frames showed the source pane's text inside the new pane after its chrome appeared:\n" +
                violations.joined(separator: "\n")
        )
    }

    // MARK: - Geometry

    /// Regions in window-screenshot pixels derived from the pre-split terminal frame.
    private struct Regions {
        /// Changed non-magenta pixels in the midline band that mark the new
        /// pane's chrome: its tab bar and focus ring span the pane width.
        static let chromeChangeThreshold = 150
        let newPane: CGRect
        let midlineBand: CGRect

        init(terminalFrame: CGRect, windowFrame: CGRect, scale: CGFloat) {
            // Screen and screenshot coordinates share a top-left origin.
            let local = CGRect(
                x: (terminalFrame.minX - windowFrame.minX) * scale,
                y: (terminalFrame.minY - windowFrame.minY) * scale,
                width: terminalFrame.width * scale,
                height: terminalFrame.height * scale
            )
            // Leave the scroller column and a tab bar plus prompt of slack
            // below the midline out of both regions.
            let inset = 4 * scale
            let scroller = 24 * scale
            let slack = 40 * scale
            let x = local.minX + inset
            let width = max(1, local.width - inset - scroller)
            newPane = CGRect(
                x: x,
                y: local.midY + slack,
                width: width,
                height: max(1, local.maxY - (local.midY + slack))
            )
            midlineBand = CGRect(x: x, y: local.midY - slack, width: width, height: 2 * slack)
        }
    }

    // MARK: - Pixels

    private struct ScreenshotImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(screenshot: XCUIScreenshot) {
            guard let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let width = cgImage.width
            let height = cgImage.height
            guard width > 0, height > 0 else { return nil }
            let bytesPerRow = width * 4
            var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
            let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                guard let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
                ) else { return false }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
                return true
            }
            guard ok else { return nil }
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        private func clamp(_ rect: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            (
                max(0, Int(rect.minX)), max(0, Int(rect.minY)),
                min(width, Int(rect.maxX)), min(height, Int(rect.maxY))
            )
        }

        private static func isMagenta(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
            r >= 150 && b >= 150 && g <= 110 && Int(r) - Int(g) >= 60
        }

        /// Magenta glyph pixels inside `rect`, sampled every other pixel.
        func magentaCount(in rect: CGRect) -> Int {
            let (x0, y0, x1, y1) = clamp(rect)
            var count = 0
            var y = y0
            while y < y1 {
                var x = x0
                while x < x1 {
                    let i = (y * width + x) * 4
                    if Self.isMagenta(pixels[i], pixels[i + 1], pixels[i + 2]) { count += 1 }
                    x += 2
                }
                y += 2
            }
            return count
        }

        /// Pixels inside `rect` that differ clearly from `other` and are not
        /// source glyphs in either frame, sampled every other pixel.
        func changedCount(in rect: CGRect, against other: ScreenshotImage) -> Int {
            guard other.width == width, other.height == height else { return Int.max }
            let (x0, y0, x1, y1) = clamp(rect)
            var count = 0
            var y = y0
            while y < y1 {
                var x = x0
                while x < x1 {
                    let i = (y * width + x) * 4
                    let mine = (pixels[i], pixels[i + 1], pixels[i + 2])
                    let theirs = (other.pixels[i], other.pixels[i + 1], other.pixels[i + 2])
                    if !Self.isMagenta(mine.0, mine.1, mine.2), !Self.isMagenta(theirs.0, theirs.1, theirs.2) {
                        let delta = max(
                            abs(Int(mine.0) - Int(theirs.0)),
                            abs(Int(mine.1) - Int(theirs.1)),
                            abs(Int(mine.2) - Int(theirs.2))
                        )
                        if delta > 48 { count += 1 }
                    }
                    x += 2
                }
                y += 2
            }
            return count
        }
    }

    // MARK: - Harness

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
