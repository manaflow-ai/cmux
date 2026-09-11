import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ObjectiveC.runtime
import QuartzCore

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

private struct Options {
    var outputDirectory: URL
    var timeout: TimeInterval
    var mode: Mode
}

private enum Mode: String, Codable {
    case direct
    case layerHost = "layer-host"
}

private struct PixelStats: Codable {
    let width: Int
    let height: Int
    let redPixels: Int
    let greenPixels: Int
    let bluePixels: Int
    let darkPixels: Int
    let lightPixels: Int
    let nonWhitePixels: Int
}

private struct Summary: Codable {
    let outputDirectory: String
    let mode: Mode
    let displayPath: String
    let contextSource: String
    let contextID: UInt32?
    let swiftWindowID: UInt32
    let captureMode: String
    let screenshotPath: String
    let stats: PixelStats
}

private enum VerifierError: Error, CustomStringConvertible {
    case usage(String)
    case layerContext(String)
    case layerHost(String)
    case timeout(String)
    case capture(String)
    case pngWrite(String)

    var description: String {
        switch self {
        case .usage(let message),
             .layerContext(let message),
             .layerHost(let message),
             .timeout(let message),
             .capture(let message),
             .pngWrite(let message):
            return message
        }
    }
}

@main
struct OwlLayerHostSelfTest {
    static func main() {
        do {
            let options = try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            try SelfTestRunner(options: options).run()
        } catch let error as VerifierError {
            fputs("error: \(error.description)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func parseOptions(arguments: [String]) throws -> Options {
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/layer-host-self-test-latest", isDirectory: true)
        var timeout: TimeInterval = 10
        var mode: Mode = .layerHost

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw VerifierError.usage("missing value for --output-dir")
                }
                outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--timeout":
                index += 1
                guard index < arguments.count,
                      let parsedTimeout = TimeInterval(arguments[index]) else {
                    throw VerifierError.usage("invalid value for --timeout")
                }
                timeout = parsedTimeout
            case "--mode":
                index += 1
                guard index < arguments.count,
                      let parsedMode = Mode(rawValue: arguments[index]) else {
                    throw VerifierError.usage("invalid value for --mode, expected direct or layer-host")
                }
                mode = parsedMode
            case "--help", "-h":
                throw VerifierError.usage("""
                Usage: OwlLayerHostSelfTest [--output-dir <dir>] [--timeout <seconds>] [--mode direct|layer-host]
                """)
            default:
                throw VerifierError.usage("unknown argument \(argument)")
            }
            index += 1
        }

        return Options(outputDirectory: outputDirectory, timeout: timeout, mode: mode)
    }
}

private final class SelfTestRunner {
    private let options: Options
    private let fileManager = FileManager.default
    private let contentSize = CGSize(width: 960, height: 640)

    init(options: Options) {
        self.options = options
    }

    func run() throws {
        try fileManager.removeItemIfPresent(at: options.outputDirectory)
        try fileManager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()

        let fixture = try makeFixture(mode: options.mode)
        defer {
            fixture.window.close()
            pumpApp(app, for: 0.1)
        }

        app.activate(ignoringOtherApps: true)
        fixture.window.show()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        pumpApp(app, for: 0.2)

        let screenshotURL = options.outputDirectory.appendingPathComponent("\(options.mode.rawValue)-self-test.png")
        let deadline = Date().addingTimeInterval(options.timeout)
        var lastError = "no capture attempted"
        var lastWindowID: UInt32?

        while Date() < deadline {
            pumpApp(app, for: 0.05)
            CATransaction.flush()

            guard let windowID = swiftHostWindowID(title: fixture.window.title, minimumSize: contentSize) else {
                lastError = "Swift self-test window was not visible in CGWindowList"
                continue
            }
            lastWindowID = windowID

            do {
                let attempts = try captureWindowAttempts(windowID: windowID, to: screenshotURL)
                var attemptSummaries: [String] = []
                for attempt in attempts {
                    let stats = analyze(image: attempt.image)
                    attemptSummaries.append("\(attempt.mode)=\(stats)")
                    if !stats.hasFixturePixels {
                        continue
                    }
                    let summary = Summary(
                        outputDirectory: options.outputDirectory.path,
                        mode: options.mode,
                        displayPath: fixture.displayPath,
                        contextSource: fixture.contextSource,
                        contextID: fixture.contextID,
                        swiftWindowID: windowID,
                        captureMode: attempt.mode,
                        screenshotPath: attempt.url.path,
                        stats: stats
                    )
                    try JSONEncoder.pretty.encode(summary)
                        .write(to: options.outputDirectory.appendingPathComponent("summary.json"))

                    print("OWL LayerHost self-test passed")
                    print("Artifacts: \(options.outputDirectory.path)")
                    print("Mode: \(summary.mode.rawValue)")
                    print("Display path: \(summary.displayPath)")
                    print("Context source: \(summary.contextSource)")
                    if let contextID = summary.contextID {
                        print("Context ID: \(contextID)")
                    }
                    print("Capture mode: \(summary.captureMode)")
                    print("Screenshot: \(summary.screenshotPath)")
                    print("Stats: \(summary.stats)")
                    return
                }
                lastError = "pixel stats did not contain fixture colors: \(attemptSummaries.joined(separator: "; "))"
            } catch let error as VerifierError {
                lastError = error.description
            } catch {
                lastError = String(describing: error)
            }
        }

        throw VerifierError.timeout(
            "timed out waiting for \(options.mode.rawValue) self-test: \(lastError); lastWindowID=\(lastWindowID.map(String.init) ?? "none")"
        )
    }

    private func makeFixture(mode: Mode) throws -> FixtureWindow {
        switch mode {
        case .direct:
            let window = DirectLayerWindow(
                title: "OWL direct layer self test",
                size: contentSize
            )
            return FixtureWindow(
                window: window,
                displayPath: "Swift CALayer fixture directly hosted in an NSWindow",
                contextSource: "none",
                contextID: nil
            )
        case .layerHost:
            let context = try RemoteLayerContext(size: contentSize)
            let window = try LayerHostWindow(
                title: "OWL LayerHost self test",
                contextID: context.contextID,
                size: contentSize
            )
            return FixtureWindow(
                window: window,
                displayPath: "same-process CAContext hosted by Swift CALayerHost",
                contextSource: context.source,
                contextID: context.contextID
            )
        }
    }
}

private struct FixtureWindow {
    let window: TestWindow
    let displayPath: String
    let contextSource: String
    let contextID: UInt32?
}

private protocol TestWindow {
    var title: String { get }
    func show()
    func close()
}

private final class RemoteLayerContext {
    let context: NSObject
    let contextID: UInt32
    let source: String
    private let rootLayer: CALayer

    init(size: CGSize) throws {
        rootLayer = Self.makeFixtureLayer(size: size)
        let created = try Self.makeCAContext()
        context = created.context
        source = created.source

        context.setValue(rootLayer, forKey: "layer")
        CATransaction.flush()

        guard let number = context.value(forKey: "contextId") as? NSNumber else {
            throw VerifierError.layerContext("CAContext did not expose contextId")
        }
        contextID = number.uint32Value
        guard contextID != 0 else {
            throw VerifierError.layerContext("CAContext returned contextId 0")
        }
    }

    private static func makeCAContext() throws -> (context: NSObject, source: String) {
        guard let contextClass = NSClassFromString("CAContext") else {
            throw VerifierError.layerContext("CAContext class is not available")
        }

        let connectionSelector = NSSelectorFromString("contextWithCGSConnection:options:")
        if let method = class_getClassMethod(contextClass, connectionSelector) {
            typealias ContextWithCGSConnection = @convention(c) (AnyClass, Selector, UInt32, NSDictionary) -> AnyObject?
            let implementation = method_getImplementation(method)
            let create = unsafeBitCast(implementation, to: ContextWithCGSConnection.self)
            if let context = create(contextClass, connectionSelector, CGSMainConnectionID(), [:] as NSDictionary) as? NSObject {
                return (context, "CAContext.contextWithCGSConnection")
            }
        }

        let remoteSelector = NSSelectorFromString("remoteContextWithOptions:")
        guard let method = class_getClassMethod(contextClass, remoteSelector) else {
            throw VerifierError.layerContext("CAContext has neither contextWithCGSConnection:options: nor remoteContextWithOptions:")
        }

        typealias RemoteContextWithOptions = @convention(c) (AnyClass, Selector, NSDictionary) -> AnyObject?
        let implementation = method_getImplementation(method)
        let create = unsafeBitCast(implementation, to: RemoteContextWithOptions.self)
        guard let context = create(contextClass, remoteSelector, [:] as NSDictionary) as? NSObject else {
            throw VerifierError.layerContext("remoteContextWithOptions: returned nil")
        }
        return (context, "CAContext.remoteContextWithOptions")
    }

    static func makeFixtureLayer(size: CGSize) -> CALayer {
        let root = CALayer()
        root.isGeometryFlipped = true
        root.anchorPoint = .zero
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor(calibratedRed: 0.972, green: 0.972, blue: 0.972, alpha: 1).cgColor
        root.contentsScale = NSScreen.main?.backingScaleFactor ?? 1

        func addBlock(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: NSColor) {
            let layer = CALayer()
            layer.anchorPoint = .zero
            layer.frame = CGRect(x: x, y: y, width: width, height: height)
            layer.backgroundColor = color.cgColor
            root.addSublayer(layer)
        }

        addBlock(x: 48, y: 56, width: 180, height: 140, color: .systemRed)
        addBlock(x: 288, y: 56, width: 180, height: 140, color: .systemGreen)
        addBlock(x: 528, y: 56, width: 180, height: 140, color: .systemBlue)

        let text = CATextLayer()
        text.anchorPoint = .zero
        text.frame = CGRect(x: 48, y: 238, width: 760, height: 72)
        text.string = "OWL_LAYER_HOST_SENTINEL"
        text.fontSize = 40
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 1
        text.foregroundColor = NSColor(calibratedRed: 0.078, green: 0.078, blue: 0.078, alpha: 1).cgColor
        root.addSublayer(text)

        return root
    }
}

private final class DirectLayerWindow: TestWindow {
    let title: String
    private let window: NSWindow

    init(title: String, size: CGSize) {
        self.title = title

        let frame = NSRect(origin: .zero, size: size)
        let contentView = NSView(frame: frame)
        contentView.wantsLayer = true
        contentView.layer = RemoteLayerContext.makeFixtureLayer(size: size)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = contentView
        window.backgroundColor = .white
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.sharingType = .readOnly
    }

    func close() {
        window.close()
    }
}

private final class LayerHostWindow: TestWindow {
    let title: String
    private let window: NSWindow

    init(title: String, contextID: UInt32, size: CGSize) throws {
        self.title = title

        let frame = NSRect(origin: .zero, size: size)
        let contentView = NSView(frame: frame)
        contentView.wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.isGeometryFlipped = true
        rootLayer.backgroundColor = NSColor.white.cgColor
        rootLayer.frame = CGRect(origin: .zero, size: size)
        contentView.layer = rootLayer

        let hostLayer = try makeCALayerHost(contextID: contextID)
        hostLayer.anchorPoint = .zero
        hostLayer.bounds = rootLayer.bounds
        hostLayer.position = .zero
        hostLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.addSublayer(hostLayer)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = contentView
        window.backgroundColor = .white
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.sharingType = .readOnly
    }

    func close() {
        window.close()
    }
}

private func makeCALayerHost(contextID: UInt32) throws -> CALayer {
    guard let layerClass = NSClassFromString("CALayerHost") as? NSObject.Type else {
        throw VerifierError.layerHost("CALayerHost is not available")
    }
    guard let layer = layerClass.init() as? CALayer else {
        throw VerifierError.layerHost("CALayerHost did not instantiate as CALayer")
    }
    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1
    layer.setValue(NSNumber(value: contextID), forKey: "contextId")
    return layer
}

private func pumpApp(_ app: NSApplication, for duration: TimeInterval) {
    let end = Date().addingTimeInterval(duration)
    repeat {
        if let event = app.nextEvent(
            matching: .any,
            until: Date().addingTimeInterval(0.01),
            inMode: .default,
            dequeue: true
        ) {
            app.sendEvent(event)
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    } while Date() < end
}

private func swiftHostWindowID(title: String, minimumSize: CGSize) -> UInt32? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    var fallback: (id: UInt32, area: Double)?
    for window in windows {
        guard (window[kCGWindowOwnerPID as String] as? Int32) == getpid(),
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber,
              width.doubleValue >= minimumSize.width,
              height.doubleValue >= minimumSize.height else {
            continue
        }
        let id = windowNumber(from: window)
        guard let id else {
            continue
        }
        if (window[kCGWindowName as String] as? String) == title {
            return id
        }
        let area = width.doubleValue * height.doubleValue
        if fallback == nil || area > fallback!.area {
            fallback = (id, area)
        }
    }

    return fallback?.id
}

private func windowNumber(from window: [String: Any]) -> UInt32? {
    if let number = window[kCGWindowNumber as String] as? UInt32 {
        return number
    }
    if let number = window[kCGWindowNumber as String] as? Int {
        return UInt32(number)
    }
    return nil
}

private struct CaptureAttempt {
    let mode: String
    let url: URL
    let image: CGImage
}

private func captureWindowAttempts(windowID: UInt32, to url: URL) throws -> [CaptureAttempt] {
    var attempts: [CaptureAttempt] = []
    var errors: [String] = []

    let stem = url.deletingPathExtension().path
    let extensionName = url.pathExtension.isEmpty ? "png" : url.pathExtension
    let screencaptureURL = URL(fileURLWithPath: "\(stem)-screencapture.\(extensionName)")
    let cgWindowURL = URL(fileURLWithPath: "\(stem)-cgwindow.\(extensionName)")
    let screenURL = URL(fileURLWithPath: "\(stem)-screen.\(extensionName)")

    do {
        let image = try captureWindowWithScreencapture(windowID: windowID, to: screencaptureURL)
        attempts.append(CaptureAttempt(mode: "screencapture", url: screencaptureURL, image: image))
    } catch {
        errors.append("screencapture: \(error)")
    }

    do {
        guard let image = CGWindowListCreateImage(
            .null,
            [.optionIncludingWindow],
            CGWindowID(windowID),
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            throw VerifierError.capture("CGWindowListCreateImage returned nil")
        }
        try pngData(from: image).write(to: cgWindowURL)
        attempts.append(CaptureAttempt(mode: "cgwindow", url: cgWindowURL, image: image))
    } catch {
        errors.append("cgwindow: \(error)")
    }

    do {
        let image = try captureScreen(to: screenURL)
        attempts.append(CaptureAttempt(mode: "screen", url: screenURL, image: image))
    } catch {
        errors.append("screen: \(error)")
    }

    if attempts.isEmpty {
        throw VerifierError.capture(errors.joined(separator: "; "))
    }
    return attempts
}

private func captureWindowWithScreencapture(windowID: UInt32, to url: URL) throws -> CGImage {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l\(windowID)", url.path]
    process.standardOutput = Pipe()
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw VerifierError.capture("screencapture failed with status \(process.terminationStatus) windowID=\(windowID) \(errorText)")
    }

    let data = try Data(contentsOf: url)
    guard let image = loadImage(from: data) else {
        throw VerifierError.capture("screencapture returned invalid PNG data")
    }
    return image
}

private func captureScreen(to url: URL) throws -> CGImage {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", url.path]
    process.standardOutput = Pipe()
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw VerifierError.capture("screen screencapture failed with status \(process.terminationStatus) \(errorText)")
    }

    let data = try Data(contentsOf: url)
    guard let image = loadImage(from: data) else {
        throw VerifierError.capture("screen screencapture returned invalid PNG data")
    }
    return image
}

private func pngData(from image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        throw VerifierError.pngWrite("could not create PNG destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw VerifierError.pngWrite("could not finalize PNG data")
    }
    return data as Data
}

private func loadImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func analyze(image: CGImage) -> PixelStats {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
        CGImageAlphaInfo.premultipliedLast.rawValue

    pixels.withUnsafeMutableBytes { buffer in
        if let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    var red = 0
    var green = 0
    var blue = 0
    var dark = 0
    var light = 0
    var nonWhite = 0

    for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
        let r = Int(pixels[offset])
        let g = Int(pixels[offset + 1])
        let b = Int(pixels[offset + 2])

        if r >= 200, g <= 100, b <= 100 {
            red += 1
        }
        if r <= 120, g >= 120, b <= 140 {
            green += 1
        }
        if r <= 120, g <= 160, b >= 160 {
            blue += 1
        }
        if r < 70, g < 70, b < 70 {
            dark += 1
        }
        if r > 230, g > 230, b > 230 {
            light += 1
        }
        if r < 245 || g < 245 || b < 245 {
            nonWhite += 1
        }
    }

    return PixelStats(
        width: width,
        height: height,
        redPixels: red,
        greenPixels: green,
        bluePixels: blue,
        darkPixels: dark,
        lightPixels: light,
        nonWhitePixels: nonWhite
    )
}

private extension PixelStats {
    var hasFixturePixels: Bool {
        redPixels > 12_000 &&
            greenPixels > 12_000 &&
            bluePixels > 8_000 &&
            darkPixels > 1_000 &&
            lightPixels > 20_000 &&
            nonWhitePixels > 40_000
    }
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        guard fileExists(atPath: url.path) else {
            return
        }
        try removeItem(at: url)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
