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

struct PixelBounds: Codable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var count: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

struct PixelSize {
    var width: Int
    var height: Int
}

struct SurfaceResult: Codable {
    var surface: String
    var beforeScreenshot: String
    var afterScreenshot: String
    var beforeBounds: PixelBounds
    var afterBounds: PixelBounds
    var viewportScale: Double
    var widthRatio: Double
    var heightRatio: Double
    var tolerance: Double
}

struct VerificationResult: Codable {
    var tag: String
    var artifactDirectory: String
    var terminal: SurfaceResult
    var browser: SurfaceResult
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let tagIndex = arguments.firstIndex(of: "--tag"),
      tagIndex + 1 < arguments.count else {
    fputs("Usage: verify-canvas-surface-scaling.swift --tag <tag> [--out-dir <path>]\n", stderr)
    exit(2)
}

let tag = arguments[tagIndex + 1]
let outDirectory: URL = {
    if let outIndex = arguments.firstIndex(of: "--out-dir"), outIndex + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[outIndex + 1], isDirectory: true)
    }
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    return URL(fileURLWithPath: "/tmp/cmux-canvas-surface-scaling-\(tag)-\(stamp)", isDirectory: true)
}()

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let cliURL = rootURL.appendingPathComponent("scripts/cmux-debug-cli.sh")
let fileManager = FileManager.default

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

func okObject(_ object: [String: Any], key: String) throws -> [String: Any] {
    guard let nested = object[key] as? [String: Any] else {
        throw ProbeError(message: "Missing JSON key \(key) in \(object)")
    }
    return nested
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

func waitForColor(
    label: String,
    threshold: (CGFloat, CGFloat, CGFloat, CGFloat) -> Bool,
    minimumPixels: Int,
    minimumInset: Int = 0
) throws -> URL {
    var lastPath: URL?
    for attempt in 0..<20 {
        let path = try screenshot(label: "\(label)_\(attempt)")
        lastPath = path
        if let bounds = try? detectBounds(in: path, threshold: threshold),
           bounds.count >= minimumPixels,
           (try? boundsAreInset(bounds, in: path, minimumInset: minimumInset)) == true {
            return path
        }
        Thread.sleep(forTimeInterval: 0.15)
    }
    throw ProbeError(message: "Timed out waiting for colored probe in \(lastPath?.path ?? "no screenshot")")
}

func boundsAreInset(_ bounds: PixelBounds, in url: URL, minimumInset: Int) throws -> Bool {
    guard minimumInset > 0 else { return true }
    let size = try imageSize(url)
    return bounds.minX >= minimumInset
        && bounds.minY >= minimumInset
        && bounds.maxX <= size.width - minimumInset
        && bounds.maxY <= size.height - minimumInset
}

func detectBounds(
    in url: URL,
    threshold: (CGFloat, CGFloat, CGFloat, CGFloat) -> Bool
) throws -> PixelBounds {
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

    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(colorSpace) else {
                continue
            }
            if threshold(color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent) {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                count += 1
            }
        }
    }

    guard count > 0 else {
        throw ProbeError(message: "No matching probe pixels in \(url.path)")
    }
    return PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY, count: count)
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

func resizeFocusedCanvasItem(
    workspace: String,
    viewportSize: PixelSize,
    width targetWidth: Double = 720,
    height targetHeight: Double = 520
) throws {
    _ = try setCanvasViewport(scale: 1, workspace: workspace, viewportSize: viewportSize)
    let object = try cliJSON(["rpc", "debug.layout", "{}"])
    let layout = try okObject(object, key: "layout")
    guard let items = layout["canvasItems"] as? [[String: Any]],
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

func zoomOut(workspace: String, viewportSize: PixelSize) throws -> [String: Any] {
    try focusWorkspace(workspace)
    let anchorX = max(1, viewportSize.width / 2)
    let anchorY = max(1, viewportSize.height / 2)
    let params = """
    {"workspace_id":"\(workspace)","start_scale":1,"delta_y":-12,"repeat":24,"viewport_width":\(viewportSize.width),"viewport_height":\(viewportSize.height),"anchor_x":\(anchorX),"anchor_y":\(anchorY)}
    """
    return try cliJSON(["rpc", "debug.canvas.wheel_zoom", params])
}

func assertScale(surface: String, before: PixelBounds, after: PixelBounds, viewportScale: Double) throws -> (Double, Double) {
    let widthRatio = Double(after.width) / Double(before.width)
    let heightRatio = Double(after.height) / Double(before.height)
    let tolerance = 0.09
    guard abs(widthRatio - viewportScale) <= tolerance,
          abs(heightRatio - viewportScale) <= tolerance else {
        throw ProbeError(
            message: "\(surface) probe scaled incorrectly. expected \(viewportScale), got width \(widthRatio), height \(heightRatio). before=\(before) after=\(after)"
        )
    }
    return (widthRatio, heightRatio)
}

func terminalProbe() throws -> SurfaceResult {
    let workspace = try workspaceRefFromCreateOutput(try cli([
        "new-workspace",
        "--name", "canvas-terminal-scale-probe",
        "--focus", "true"
    ]))
    try focusWorkspace(workspace)
    Thread.sleep(forTimeInterval: 0.5)

    let terminalCommand = """
    printf '\\033[2J\\033[H'; for i in {1..10}; do printf '\\033[48;2;255;0;0m                              \\033[0m\\n'; done; printf '\\033[0mCANVAS_TERMINAL_PROBE\\n'
    """
    _ = try cli(["send", "--workspace", workspace, terminalCommand + "\n"])
    Thread.sleep(forTimeInterval: 0.6)
    let size = try viewportSize(for: workspace)
    try resizeFocusedCanvasItem(workspace: workspace, viewportSize: size)
    Thread.sleep(forTimeInterval: 0.3)

    let beforeSource = try waitForColor(
        label: "terminal_before",
        threshold: terminalRedThreshold,
        minimumPixels: 200,
        minimumInset: 16
    )
    let beforeCopy = try copyArtifact(beforeSource, named: "terminal-before.png")
    let beforeBounds = try detectBounds(
        in: beforeCopy,
        threshold: terminalRedThreshold
    )

    let zoom = try zoomOut(workspace: workspace, viewportSize: size)
    guard let viewportScale = zoom["end_scale"] as? Double else {
        throw ProbeError(message: "debug.canvas.wheel_zoom returned no end_scale: \(zoom)")
    }
    Thread.sleep(forTimeInterval: 0.5)

    let afterSource = try waitForColor(
        label: "terminal_after",
        threshold: terminalRedThreshold,
        minimumPixels: 50
    )
    let afterCopy = try copyArtifact(afterSource, named: "terminal-after.png")
    let afterBounds = try detectBounds(
        in: afterCopy,
        threshold: terminalRedThreshold
    )

    let ratios = try assertScale(
        surface: "terminal",
        before: beforeBounds,
        after: afterBounds,
        viewportScale: viewportScale
    )
    return SurfaceResult(
        surface: "terminal",
        beforeScreenshot: beforeCopy.path,
        afterScreenshot: afterCopy.path,
        beforeBounds: beforeBounds,
        afterBounds: afterBounds,
        viewportScale: viewportScale,
        widthRatio: ratios.0,
        heightRatio: ratios.1,
        tolerance: 0.09
    )
}

func terminalRedThreshold(red: CGFloat, green: CGFloat, blue: CGFloat, alpha _: CGFloat) -> Bool {
    red > 0.74 && green < 0.36 && blue < 0.28
}

func browserProbe() throws -> SurfaceResult {
    let workspace = try workspaceRefFromCreateOutput(try cli([
        "new-workspace",
        "--name", "canvas-browser-scale-probe",
        "--focus", "true"
    ]))
    let html = """
    <html><body style='margin:0;background:#151515;overflow:hidden'><div id='probe' style='position:absolute;left:64px;top:72px;width:360px;height:180px;background:#00ff00'></div></body></html>
    """
    let encoded = Data(html.utf8).base64EncodedString()
    let dataURL = "data:text/html;base64,\(encoded)"
    _ = try cli([
        "new-surface",
        "--type", "browser",
        "--workspace", workspace,
        "--url", dataURL,
        "--focus", "true"
    ])
    try focusWorkspace(workspace)
    Thread.sleep(forTimeInterval: 1.4)
    let surface = try currentSurfaceRef()
    _ = try cli(["browser", "--surface", surface, "wait", "--selector", "#probe", "--timeout-ms", "5000"])

    let size = try viewportSize(for: workspace)
    try resizeFocusedCanvasItem(workspace: workspace, viewportSize: size)
    Thread.sleep(forTimeInterval: 0.5)
    let beforeSource = try waitForColor(
        label: "browser_before",
        threshold: { red, green, blue, _ in green > 0.82 && red < 0.22 && blue < 0.22 },
        minimumPixels: 1_000,
        minimumInset: 16
    )
    let beforeCopy = try copyArtifact(beforeSource, named: "browser-before.png")
    let beforeBounds = try detectBounds(
        in: beforeCopy,
        threshold: { red, green, blue, _ in green > 0.82 && red < 0.22 && blue < 0.22 }
    )

    let zoom = try zoomOut(workspace: workspace, viewportSize: size)
    guard let viewportScale = zoom["end_scale"] as? Double else {
        throw ProbeError(message: "debug.canvas.wheel_zoom returned no end_scale: \(zoom)")
    }
    Thread.sleep(forTimeInterval: 0.6)
    let afterSource = try waitForColor(
        label: "browser_after",
        threshold: { red, green, blue, _ in green > 0.82 && red < 0.22 && blue < 0.22 },
        minimumPixels: 200
    )
    let afterCopy = try copyArtifact(afterSource, named: "browser-after.png")
    let afterBounds = try detectBounds(
        in: afterCopy,
        threshold: { red, green, blue, _ in green > 0.82 && red < 0.22 && blue < 0.22 }
    )

    let ratios = try assertScale(
        surface: "browser",
        before: beforeBounds,
        after: afterBounds,
        viewportScale: viewportScale
    )
    return SurfaceResult(
        surface: "browser",
        beforeScreenshot: beforeCopy.path,
        afterScreenshot: afterCopy.path,
        beforeBounds: beforeBounds,
        afterBounds: afterBounds,
        viewportScale: viewportScale,
        widthRatio: ratios.0,
        heightRatio: ratios.1,
        tolerance: 0.09
    )
}

do {
    try fileManager.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    let terminal = try terminalProbe()
    let browser = try browserProbe()
    let result = VerificationResult(
        tag: tag,
        artifactDirectory: outDirectory.path,
        terminal: terminal,
        browser: browser
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    let reportURL = outDirectory.appendingPathComponent("report.json")
    try data.write(to: reportURL)
    print(String(data: data, encoding: .utf8) ?? "")
    print("PASS canvas surface scaling verifier wrote \(reportURL.path)")
} catch {
    fputs("FAIL canvas surface scaling verifier: \(error)\n", stderr)
    exit(1)
}
