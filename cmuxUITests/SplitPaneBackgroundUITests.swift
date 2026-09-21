import AppKit
import CoreGraphics
import ImageIO
import XCTest

/// Splitting a text-filled pane must never paint the source pane's glyphs
/// inside the new pane (https://github.com/manaflow-ai/cmux/issues/13387).
///
/// The test fills the focused terminal with magenta text, presses
/// Cmd+Shift+D through the real key path, and captures the window as fast as
/// XCTest allows for the next few seconds. A frame is acceptable while it still
/// shows the pre-split layout (the split has not committed yet) and once the
/// region the new pane occupies is free of magenta. A frame that shows the new
/// pane's chrome at the pre-split midline together with the source text below
/// it is the reported glitch. The first frames of the transition are attached
/// to the result bundle as evidence.
final class SplitPaneBackgroundUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let run = UUID().uuidString
        socketPath = "/tmp/cmux-ui-test-socket-\(run).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-split-bg-\(run).diagnostics.json"
        launchTag = "ui-split-bg-\(run.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        addTeardownBlock { [socketPath, diagnosticsPath] in
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
            try? FileManager.default.removeItem(atPath: diagnosticsPath)
        }
    }

    func testSplitDownNeverPaintsSourceTextInsideNewPane() throws {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAndEnsureForeground(app)
        defer { app.terminate() }

        XCTAssertTrue(
            waitForControlSocketReady(socketPath: socketPath, pingTimeout: 30) {
                self.socketLine("ping") == "PONG" ||
                    self.controlSocketDiagnosticsReportReady(self.loadDiagnostics())
            },
            "Expected control socket at \(socketPath); diagnostics=\(loadDiagnostics())"
        )
        var target: (workspaceID: String, surfaceID: String)?
        XCTAssertTrue(waitForCondition(timeout: 20) {
            target = self.terminalSurface()
            return target != nil
        }, "Expected a terminal surface in the selected workspace")
        let source = try XCTUnwrap(target)
        let sourceSurfaceID = source.surfaceID
        // Cmd+Shift+D splits the focused panel, so make the source terminal
        // the focused one explicitly instead of relying on launch focus.
        XCTAssertTrue(
            socketJSON(
                method: "surface.focus",
                params: ["workspace_id": source.workspaceID, "surface_id": sourceSurfaceID]
            )?["ok"] as? Bool == true,
            "Expected surface.focus to succeed"
        )

        // Dense magenta text: the only magenta pixels in the window come from
        // the source terminal, so its glyphs can be located in any frame.
        let fill = "clear; i=1; while [ $i -le 400 ]; do printf '\\033[38;2;255;0;255mSOURCE-13387 %03d " +
            "################################################################\\033[0m\\n' \"$i\"; " +
            "i=$((i + 1)); done\r"
        XCTAssertTrue(sendText(fill, surfaceID: sourceSurfaceID), "Expected surface.send_text to succeed")
        XCTAssertTrue(waitForCondition(timeout: 30) {
            (self.readText(surfaceID: sourceSurfaceID) ?? "").contains("SOURCE-13387 400")
        }, "Expected the fill command to finish")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Expected the main window")
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Expected the source terminal")
        let windowFrame = window.frame
        let terminalFrame = terminal.frame
        XCTAssertGreaterThan(terminalFrame.height, 200, "Expected a tall source terminal: \(terminalFrame)")

        let beforeShot = window.screenshot()
        let before = try XCTUnwrap(ScreenshotImage(screenshot: beforeShot), "Could not decode the pre-split frame")
        let scale = CGFloat(before.width) / max(windowFrame.width, 1)
        let regions = Regions(terminalFrame: terminalFrame, windowFrame: windowFrame, scale: scale)
        let baselineMagenta = before.magentaCount(in: regions.newPane)
        attach(beforeShot, name: "00 before split (magenta below midline: \(baselineMagenta))")
        XCTAssertGreaterThan(
            baselineMagenta, 1_000,
            "Expected dense source text in the region the new pane takes; terminal=\(terminalFrame) window=\(windowFrame)"
        )

        let splitAt = Date()
        app.typeKey("d", modifierFlags: [.command, .shift])
        var frames: [(offset: TimeInterval, screenshot: XCUIScreenshot)] = []
        let deadline = splitAt.addingTimeInterval(3.0)
        while Date() < deadline, frames.count < 80 {
            let screenshot = window.screenshot()
            frames.append((Date().timeIntervalSince(splitAt), screenshot))
        }
        XCTAssertTrue(waitForCondition(timeout: 15) { app.textViews.count >= 2 }, "Expected the split to create a second terminal")
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

    // MARK: - Socket

    /// In-process client first; `nc -U` is the fallback for hosted runners
    /// where the Darwin client occasionally fails to connect.
    private func socketLine(_ line: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 3.0).sendLine(line)
            ?? controlSocketCommandViaNetcat(line, socketPath: socketPath, responseTimeout: 3.0)
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        return ControlSocketClient(path: socketPath, responseTimeout: 5.0).sendJSON(request)
            ?? controlSocketJSONViaNetcat(request, socketPath: socketPath, responseTimeout: 5.0)
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: diagnosticsPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = "\(entry.value)"
        }
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        deinit {}

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var timeout = timeval(
                tv_sec: Int(responseTimeout),
                tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
            )
            withUnsafePointer(to: &timeout) { ptr in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8CString)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            guard pathBytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                for index in 0..<pathBytes.count {
                    raw[index] = pathBytes[index]
                }
            }
            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + pathBytes.count)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = Array((line + "\n").utf8)
            let wrote = payload.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return true }
                return Darwin.write(fd, baseAddress, rawBuffer.count) == rawBuffer.count
            }
            guard wrote else { return nil }

            var buffer = [UInt8](repeating: 0, count: 65536)
            var accumulator = ""
            let deadline = Date().addingTimeInterval(responseTimeout)
            while Date() < deadline {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                }
            }
            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The selected workspace and its focused (else first) terminal.
    /// `surface.current` reports no surface while the app has no key window,
    /// which is the normal state on a headless runner, so the lookup goes
    /// through the workspace and surface lists instead.
    private func terminalSurface() -> (workspaceID: String, surfaceID: String)? {
        guard let workspaceID = selectedWorkspaceID(),
              let envelope = socketJSON(method: "surface.list", params: ["workspace_id": workspaceID]),
              envelope["ok"] as? Bool == true,
              let result = envelope["result"] as? [String: Any],
              let surfaces = result["surfaces"] as? [[String: Any]] else { return nil }
        let terminals = surfaces.filter { ($0["type"] as? String) == "terminal" }
        let preferred = terminals.first(where: { ($0["focused"] as? Bool) == true }) ?? terminals.first
        guard let surfaceID = preferred?["id"] as? String else { return nil }
        return (workspaceID, surfaceID)
    }

    private func selectedWorkspaceID() -> String? {
        if let envelope = socketJSON(method: "workspace.current", params: [:]),
           envelope["ok"] as? Bool == true,
           let result = envelope["result"] as? [String: Any],
           let workspaceID = result["workspace_id"] as? String {
            return workspaceID
        }
        guard let envelope = socketJSON(method: "workspace.list", params: [:]),
              envelope["ok"] as? Bool == true,
              let result = envelope["result"] as? [String: Any],
              let workspaces = result["workspaces"] as? [[String: Any]] else { return nil }
        let preferred = workspaces.first(where: { ($0["selected"] as? Bool) == true }) ?? workspaces.first
        return preferred?["id"] as? String
    }

    private func sendText(_ text: String, surfaceID: String) -> Bool {
        let envelope = socketJSON(method: "surface.send_text", params: ["surface_id": surfaceID, "text": text])
        return envelope?["ok"] as? Bool == true
    }

    private func readText(surfaceID: String) -> String? {
        guard let envelope = socketJSON(method: "surface.read_text", params: ["surface_id": surfaceID]),
              envelope["ok"] as? Bool == true,
              let result = envelope["result"] as? [String: Any] else { return nil }
        return result["text"] as? String
    }

    // MARK: - Harness

    private func launchAndEnsureForeground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        if app.state == .runningForeground || app.state == .runningBackground { return }
        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
