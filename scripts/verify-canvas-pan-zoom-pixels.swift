#!/usr/bin/env swift

import AppKit
import Foundation

struct CommandError: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let output: String

    var description: String {
        "\(command) exited \(status)\n\(output)"
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

struct PixelBounds: Codable, Equatable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var count: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

struct PixelRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct PixelSize {
    var width: Int
    var height: Int
}

struct MarkerResult: Codable {
    var before: PixelBounds
    var afterPan: PixelBounds
    var afterZoom: PixelBounds
    var panDX: Double
    var panDY: Double
    var zoomWidthRatio: Double
    var zoomHeightRatio: Double
}

struct SurfaceResult: Codable {
    var surface: String
    var beforeScreenshot: String
    var afterPanScreenshot: String
    var afterZoomScreenshot: String
    var nativeViewFrame: PixelRect
    var expectedPanDX: Double
    var expectedPanDY: Double
    var viewportScale: Double
    var markers: [String: MarkerResult]
}

struct VerificationResult: Codable {
    var tag: String
    var artifactDirectory: String
    var terminal: SurfaceResult
    var browser: SurfaceResult
}

struct ProbeColor {
    var name: String
    var minimumPixels: Int
    var minimumInset: Int
    var threshold: (CGFloat, CGFloat, CGFloat, CGFloat) -> Bool
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let tagIndex = arguments.firstIndex(of: "--tag"),
      tagIndex + 1 < arguments.count else {
    fputs("Usage: verify-canvas-pan-zoom-pixels.swift --tag <tag> [--out-dir <path>] [--stress <count>]\n", stderr)
    exit(2)
}

let tag = arguments[tagIndex + 1]
let stressCount: Int = {
    guard let index = arguments.firstIndex(of: "--stress"),
          index + 1 < arguments.count,
          let value = Int(arguments[index + 1]) else { return 1 }
    return max(1, value)
}()
let outDirectory: URL = {
    if let outIndex = arguments.firstIndex(of: "--out-dir"), outIndex + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[outIndex + 1], isDirectory: true)
    }
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    return URL(fileURLWithPath: "/tmp/cmux-canvas-pan-zoom-pixels-\(tag)-\(stamp)", isDirectory: true)
}()

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let cliURL = rootURL.appendingPathComponent("scripts/cmux-debug-cli.sh")
let terminalProbeBinaryURL = outDirectory.appendingPathComponent("cmux-size-tui-probe")
let fileManager = FileManager.default

let terminalProbes = [
    ProbeColor(name: "border", minimumPixels: 1_000, minimumInset: 12) { red, green, blue, _ in
        blue > 0.64 && green > 0.44 && red < 0.36
    },
    ProbeColor(name: "red", minimumPixels: 120, minimumInset: 12) { red, green, blue, _ in
        red > 0.70 && green < 0.42 && blue < 0.36
    },
    ProbeColor(name: "green", minimumPixels: 120, minimumInset: 12) { red, green, blue, _ in
        green > 0.70 && red < 0.35 && blue < 0.46
    },
    ProbeColor(name: "blue", minimumPixels: 120, minimumInset: 12) { red, green, blue, _ in
        blue > 0.62 && red < 0.36 && green < 0.48
    }
]

let browserProbes = [
    ProbeColor(name: "border", minimumPixels: 1_000, minimumInset: 12) { red, green, blue, _ in
        blue > 0.64 && green > 0.44 && red < 0.36
    },
    ProbeColor(name: "red", minimumPixels: 300, minimumInset: 12) { red, green, blue, _ in
        red > 0.78 && green < 0.42 && blue < 0.34
    },
    ProbeColor(name: "green", minimumPixels: 300, minimumInset: 12) { red, green, blue, _ in
        green > 0.78 && red < 0.34 && blue < 0.46
    },
    ProbeColor(name: "blue", minimumPixels: 300, minimumInset: 12) { red, green, blue, _ in
        blue > 0.78 && red < 0.40 && green < 0.48
    }
]

func run(_ executable: String, _ args: [String], environment: [String: String] = [:]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = rootURL
    var env = ProcessInfo.processInfo.environment
    for (key, value) in environment {
        env[key] = value
    }
    process.environment = env

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw CommandError(
            command: ([executable] + args).joined(separator: " "),
            status: process.terminationStatus,
            output: output
        )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func cli(_ args: [String]) throws -> String {
    try run(cliURL.path, args, environment: ["CMUX_TAG": tag])
}

func cliJSON(_ args: [String]) throws -> [String: Any] {
    let output = try cli(args)
    guard let data = output.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError(message: "Expected JSON from \(args.joined(separator: " ")), got: \(output)")
    }
    return object
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func buildTerminalProbeBinary() throws {
    try fileManager.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    _ = try run(
        rootURL.appendingPathComponent("scripts/build-cmux-size-tui.sh").path,
        ["--output", terminalProbeBinaryURL.path]
    )
}

func jsonDouble(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
}

func screenshot(label: String) throws -> URL {
    let object = try cliJSON(["rpc", "debug.window.screenshot", "{\"label\":\"\(label)\"}"])
    guard let path = object["path"] as? String else {
        throw ProbeError(message: "debug.window.screenshot returned no path: \(object)")
    }
    return URL(fileURLWithPath: path)
}

func imageSize(_ url: URL) throws -> PixelSize {
    let data = try Data(contentsOf: url)
    guard let rep = NSBitmapImageRep(data: data) else {
        throw ProbeError(message: "Failed to decode PNG at \(url.path)")
    }
    return PixelSize(width: rep.pixelsWide, height: rep.pixelsHigh)
}

func copyArtifact(_ source: URL, named name: String) throws -> URL {
    try fileManager.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    let target = outDirectory.appendingPathComponent(name)
    if fileManager.fileExists(atPath: target.path) {
        try fileManager.removeItem(at: target)
    }
    try fileManager.copyItem(at: source, to: target)
    return target
}

func integerCrop(_ crop: PixelRect?, imageWidth: Int, imageHeight: Int) -> (xRange: Range<Int>, yRange: Range<Int>) {
    guard let crop else {
        return (0..<imageWidth, 0..<imageHeight)
    }
    let minX = max(0, Int(floor(crop.x)))
    let minY = max(0, Int(floor(crop.y)))
    let maxX = min(imageWidth, Int(ceil(crop.x + crop.width)))
    let maxY = min(imageHeight, Int(ceil(crop.y + crop.height)))
    return (minX..<max(minX, maxX), minY..<max(minY, maxY))
}

func detectionCrop(around viewFrame: PixelRect) -> PixelRect {
    PixelRect(
        x: max(0, viewFrame.x - 4),
        y: 80,
        width: viewFrame.width + 96,
        height: 10_000
    )
}

func detectBounds(in url: URL, probe: ProbeColor, crop: PixelRect? = nil) throws -> PixelBounds {
    let data = try Data(contentsOf: url)
    guard let rep = NSBitmapImageRep(data: data) else {
        throw ProbeError(message: "Failed to decode PNG at \(url.path)")
    }

    var minX = Int.max
    var minY = Int.max
    var maxX = Int.min
    var maxY = Int.min
    var count = 0
    let colorSpace = NSColorSpace.deviceRGB
    let cropRanges = integerCrop(crop, imageWidth: rep.pixelsWide, imageHeight: rep.pixelsHigh)

    for y in cropRanges.yRange {
        for x in cropRanges.xRange {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(colorSpace) else {
                continue
            }
            if probe.threshold(color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent) {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                count += 1
            }
        }
    }

    guard count > 0 else {
        throw ProbeError(message: "No \(probe.name) pixels in \(url.path)")
    }
    return PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY, count: count)
}

func boundsAreInset(_ bounds: PixelBounds, in url: URL, minimumInset: Int, crop: PixelRect? = nil) throws -> Bool {
    guard minimumInset > 0 else { return true }
    let size = try imageSize(url)
    _ = crop
    return bounds.minX >= minimumInset
        && bounds.minY >= minimumInset
        && bounds.maxX <= size.width - minimumInset
        && bounds.maxY <= size.height - minimumInset
}

func detectAll(in url: URL, probes: [ProbeColor], crop: PixelRect? = nil) throws -> [String: PixelBounds] {
    var result: [String: PixelBounds] = [:]
    for probe in probes {
        let bounds = try detectBounds(in: url, probe: probe, crop: crop)
        guard bounds.count >= probe.minimumPixels else {
            throw ProbeError(message: "\(probe.name) had \(bounds.count) pixels, expected at least \(probe.minimumPixels), in \(url.path)")
        }
        guard try boundsAreInset(bounds, in: url, minimumInset: probe.minimumInset, crop: crop) else {
            throw ProbeError(message: "\(probe.name) is clipped at screenshot edge in \(url.path): \(bounds)")
        }
        result[probe.name] = bounds
    }
    return result
}

func waitForAll(label: String, probes: [ProbeColor], crop: PixelRect? = nil) throws -> URL {
    var lastPath: URL?
    var lastError: Error?
    for attempt in 0..<24 {
        let path = try screenshot(label: "\(label)_\(attempt)")
        lastPath = path
        do {
            _ = try detectAll(in: path, probes: probes, crop: crop)
            return path
        } catch {
            lastError = error
            Thread.sleep(forTimeInterval: 0.12)
        }
    }
    throw ProbeError(message: "Timed out waiting for probes in \(lastPath?.path ?? "no screenshot"): \(lastError.map(String.init(describing:)) ?? "unknown")")
}

func workspaceRefFromCreateOutput(_ output: String) throws -> String {
    guard let match = output.split(whereSeparator: { $0.isWhitespace }).last else {
        throw ProbeError(message: "Could not parse workspace ref from: \(output)")
    }
    let ref = String(match)
    guard ref.hasPrefix("workspace:") else {
        throw ProbeError(message: "Expected workspace ref, got: \(output)")
    }
    return ref
}

func focusWorkspace(_ workspace: String) throws {
    _ = try cli(["select-workspace", "--workspace", workspace])
}

func currentSurfaceRef() throws -> String {
    let object = try cliJSON(["identify", "--id-format", "both"])
    guard let focused = object["focused"] as? [String: Any],
          let ref = focused["surface_ref"] as? String else {
        throw ProbeError(message: "Could not resolve focused surface ref: \(object)")
    }
    return ref
}

func viewportSize(for workspace: String) throws -> PixelSize {
    try focusWorkspace(workspace)
    return try imageSize(screenshot(label: "viewport_probe"))
}

func setCanvasViewport(scale: Double, workspace: String, viewportSize: PixelSize) throws -> [String: Any] {
    try focusWorkspace(workspace)
    let params = """
    {"workspace_id":"\(workspace)","x":0,"y":0,"width":\(viewportSize.width),"height":\(viewportSize.height),"scale":\(scale)}
    """
    return try cliJSON(["rpc", "debug.canvas.viewport", params])
}

func panCanvas(workspace: String, viewportSize: PixelSize, dx: Double, dy: Double) throws {
    let params = """
    {"workspace_id":"\(workspace)","dx":\(dx),"dy":\(dy),"viewport_width":\(viewportSize.width),"viewport_height":\(viewportSize.height)}
    """
    _ = try cliJSON(["rpc", "debug.canvas.pan", params])
}

func zoomOut(workspace: String, viewportSize: PixelSize) throws -> Double {
    let anchorX = max(1, viewportSize.width / 2)
    let anchorY = max(1, viewportSize.height / 2)
    let params = """
    {"workspace_id":"\(workspace)","start_scale":1,"delta_y":-12,"repeat":24,"viewport_width":\(viewportSize.width),"viewport_height":\(viewportSize.height),"anchor_x":\(anchorX),"anchor_y":\(anchorY)}
    """
    let object = try cliJSON(["rpc", "debug.canvas.wheel_zoom", params])
    guard let scale = jsonDouble(object["end_scale"]) else {
        throw ProbeError(message: "debug.canvas.wheel_zoom returned no end_scale: \(object)")
    }
    return scale
}

func resizeFocusedCanvasItem(
    workspace: String,
    viewportSize: PixelSize,
    width targetWidth: Double = 620,
    height targetHeight: Double = 460
) throws {
    _ = try setCanvasViewport(scale: 1, workspace: workspace, viewportSize: viewportSize)
    let object = try cliJSON(["rpc", "debug.layout", "{}"])
    guard let layout = object["layout"] as? [String: Any],
          let items = layout["canvasItems"] as? [[String: Any]],
          let frame = items.first?["frame"] as? [String: Any],
          let width = jsonDouble(frame["width"]),
          let height = jsonDouble(frame["height"]) else {
        throw ProbeError(message: "Could not read canvas item frame from debug.layout: \(object)")
    }
    let dx = targetWidth - width
    let dy = targetHeight - height
    guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
    let params = """
    {"workspace_id":"\(workspace)","handle":"bottomRight","dx":\(dx),"dy":\(dy)}
    """
    _ = try cliJSON(["rpc", "debug.canvas.resize", params])
    _ = try setCanvasViewport(scale: 1, workspace: workspace, viewportSize: viewportSize)
}

func selectedPanelViewFrame() throws -> PixelRect {
    let object = try cliJSON(["rpc", "debug.layout", "{}"])
    guard let layout = object["layout"] as? [String: Any],
          let panels = layout["selectedPanels"] as? [[String: Any]],
          let frame = panels.first?["viewFrame"] as? [String: Any],
          let x = jsonDouble(frame["x"]),
          let y = jsonDouble(frame["y"]),
          let width = jsonDouble(frame["width"]),
          let height = jsonDouble(frame["height"]) else {
        throw ProbeError(message: "Could not read selected panel view frame from debug.layout: \(object)")
    }
    return PixelRect(x: x, y: y, width: width, height: height)
}

func assertBorderMatchesNativeView(
    surface: String,
    border: PixelBounds,
    viewFrame: PixelRect,
    screenshotURL: URL
) throws {
    let screenshotSize = try imageSize(screenshotURL)
    let expectedTop = Double(screenshotSize.height) - viewFrame.y - viewFrame.height
    let tolerance = surface.hasPrefix("terminal") ? 36.0 : 12.0
    let deltas = [
        abs(Double(border.minX) - viewFrame.x),
        abs(Double(border.minY) - expectedTop),
        abs(Double(border.width) - viewFrame.width),
        abs(Double(border.height) - viewFrame.height)
    ]
    guard deltas.allSatisfy({ $0 <= tolerance }) else {
        throw ProbeError(message: "\(surface) border is not synced with native view frame. border=\(border), viewFrame=\(viewFrame), screenshotHeight=\(screenshotSize.height), expectedTop=\(expectedTop), deltas=\(deltas)")
    }
}

func assertPan(surface: String, marker: String, before: PixelBounds, after: PixelBounds, dx: Double, dy: Double) throws {
    let translationTolerance = 9.0
    let sizeTolerance = 8
    let actualDX = Double(after.minX - before.minX)
    let actualDY = Double(after.minY - before.minY)
    guard abs(actualDX - dx) <= translationTolerance,
          abs(actualDY - dy) <= translationTolerance,
          abs(after.width - before.width) <= sizeTolerance,
          abs(after.height - before.height) <= sizeTolerance else {
        throw ProbeError(message: "\(surface) \(marker) pan mismatch. expected=(\(dx),\(dy)) actual=(\(actualDX),\(actualDY)) before=\(before) after=\(after)")
    }
}

func assertZoom(surface: String, marker: String, before: PixelBounds, after: PixelBounds, scale: Double) throws -> (Double, Double) {
    let tolerance = 0.10
    let widthRatio = Double(after.width) / Double(before.width)
    let heightRatio = Double(after.height) / Double(before.height)
    guard abs(widthRatio - scale) <= tolerance,
          abs(heightRatio - scale) <= tolerance else {
        throw ProbeError(message: "\(surface) \(marker) zoom mismatch. expected=\(scale) actual=(\(widthRatio),\(heightRatio)) before=\(before) after=\(after)")
    }
    return (widthRatio, heightRatio)
}

func terminalTUICommand() -> String {
    "\(shellQuote(terminalProbeBinaryURL.path)) --probe-pattern --interval 0.016"
}

func browserHTML() -> String {
    """
    <html>
      <body style="margin:0;background:#151515;overflow:hidden">
        <div style="position:absolute;inset:0;border:14px solid rgb(0,180,255);box-sizing:border-box"></div>
        <div style="position:absolute;left:72px;top:82px;width:150px;height:96px;background:rgb(255,64,32)"></div>
        <div style="position:absolute;left:322px;top:168px;width:190px;height:118px;background:rgb(0,255,80)"></div>
        <div style="position:absolute;left:168px;top:332px;width:172px;height:110px;background:rgb(40,80,255)"></div>
      </body>
    </html>
    """
}

func makeTerminalWorkspace() throws -> String {
    let workspace = try workspaceRefFromCreateOutput(try cli([
        "new-workspace",
        "--name", "canvas-terminal-pan-zoom-probe",
        "--focus", "true"
    ]))
    try focusWorkspace(workspace)
    return workspace
}

func makeBrowserWorkspace() throws -> String {
    let workspace = try workspaceRefFromCreateOutput(try cli([
        "new-workspace",
        "--name", "canvas-browser-pan-zoom-probe",
        "--focus", "true"
    ]))
    let encoded = Data(browserHTML().utf8).base64EncodedString()
    _ = try cli([
        "new-surface",
        "--type", "browser",
        "--workspace", workspace,
        "--url", "data:text/html;base64,\(encoded)",
        "--focus", "true"
    ])
    try focusWorkspace(workspace)
    Thread.sleep(forTimeInterval: 1.2)
    let surface = try currentSurfaceRef()
    _ = try cli(["browser", "--surface", surface, "wait", "--selector", "body", "--timeout-ms", "5000"])
    return workspace
}

func runSurface(
    surface: String,
    workspace: String,
    probes: [ProbeColor],
    panDX: Double,
    panDY: Double,
    prepareAfterResize: (() throws -> Void)? = nil
) throws -> SurfaceResult {
    try focusWorkspace(workspace)
    let viewport = try viewportSize(for: workspace)
    try resizeFocusedCanvasItem(workspace: workspace, viewportSize: viewport)
    try prepareAfterResize?()
    Thread.sleep(forTimeInterval: 0.5)
    let nativeFrame = try selectedPanelViewFrame()
    let crop = detectionCrop(around: nativeFrame)

    let beforeURL = try copyArtifact(
        try waitForAll(label: "\(surface)_before", probes: probes, crop: crop),
        named: "\(surface)-before.png"
    )
    let before = try detectAll(in: beforeURL, probes: probes, crop: crop)
    guard let border = before["border"] else {
        throw ProbeError(message: "\(surface) did not produce border probe")
    }
    try assertBorderMatchesNativeView(
        surface: surface,
        border: border,
        viewFrame: nativeFrame,
        screenshotURL: beforeURL
    )

    try panCanvas(workspace: workspace, viewportSize: viewport, dx: panDX, dy: panDY)
    let afterPanURL = try copyArtifact(
        try waitForAll(label: "\(surface)_after_pan", probes: probes, crop: crop),
        named: "\(surface)-after-pan.png"
    )
    let afterPan = try detectAll(in: afterPanURL, probes: probes, crop: crop)

    _ = try setCanvasViewport(scale: 1, workspace: workspace, viewportSize: viewport)
    Thread.sleep(forTimeInterval: 0.12)
    let scale = try zoomOut(workspace: workspace, viewportSize: viewport)
    let afterZoomURL = try copyArtifact(
        try waitForAll(label: "\(surface)_after_zoom", probes: probes, crop: crop),
        named: "\(surface)-after-zoom.png"
    )
    let afterZoom = try detectAll(in: afterZoomURL, probes: probes, crop: crop)

    var markerResults: [String: MarkerResult] = [:]
    for probe in probes {
        guard let beforeBounds = before[probe.name],
              let panBounds = afterPan[probe.name],
              let zoomBounds = afterZoom[probe.name] else {
            throw ProbeError(message: "\(surface) missing \(probe.name) bounds")
        }
        try assertPan(surface: surface, marker: probe.name, before: beforeBounds, after: panBounds, dx: panDX, dy: panDY)
        let ratios = try assertZoom(surface: surface, marker: probe.name, before: beforeBounds, after: zoomBounds, scale: scale)
        markerResults[probe.name] = MarkerResult(
            before: beforeBounds,
            afterPan: panBounds,
            afterZoom: zoomBounds,
            panDX: Double(panBounds.minX - beforeBounds.minX),
            panDY: Double(panBounds.minY - beforeBounds.minY),
            zoomWidthRatio: ratios.0,
            zoomHeightRatio: ratios.1
        )
    }

    return SurfaceResult(
        surface: surface,
        beforeScreenshot: beforeURL.path,
        afterPanScreenshot: afterPanURL.path,
        afterZoomScreenshot: afterZoomURL.path,
        nativeViewFrame: nativeFrame,
        expectedPanDX: panDX,
        expectedPanDY: panDY,
        viewportScale: scale,
        markers: markerResults
    )
}

do {
    try fileManager.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    try buildTerminalProbeBinary()
    var lastResult: VerificationResult?
    for iteration in 1...stressCount {
        let terminalWorkspace = try makeTerminalWorkspace()
        let terminal = try runSurface(
            surface: "terminal-\(iteration)",
            workspace: terminalWorkspace,
            probes: terminalProbes,
            panDX: 84,
            panDY: 32,
            prepareAfterResize: {
                try focusWorkspace(terminalWorkspace)
                _ = try cli(["send", "--workspace", terminalWorkspace, terminalTUICommand() + "\n"])
                Thread.sleep(forTimeInterval: 1.0)
            }
        )
        let browser = try runSurface(
            surface: "browser-\(iteration)",
            workspace: try makeBrowserWorkspace(),
            probes: browserProbes,
            panDX: 84,
            panDY: 32
        )
        lastResult = VerificationResult(
            tag: tag,
            artifactDirectory: outDirectory.path,
            terminal: terminal,
            browser: browser
        )
    }

    guard let result = lastResult else {
        throw ProbeError(message: "No verification iterations ran")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    let reportURL = outDirectory.appendingPathComponent("report.json")
    try data.write(to: reportURL)
    print(String(data: data, encoding: .utf8) ?? "")
    print("PASS canvas pan/zoom pixel verifier wrote \(reportURL.path)")
} catch {
    fputs("FAIL canvas pan/zoom pixel verifier: \(error)\n", stderr)
    exit(1)
}
