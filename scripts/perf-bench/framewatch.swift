// framewatch: ScreenCaptureKit frames of one rectangle of the main display, and what changed in each frame, for the
// CHROME PARITY BENCH (chrome_parity.py). The same tool reads both apps (cmux NEXT and Google Chrome): no app socket,
// no DevTools, no tracing in a measured span.
//
//   framewatch watch X Y W H FACTOR SECONDS OUT.jsonl
//       Streams the rectangle (global points, main display) scaled by FACTOR (output pixels = points x FACTOR) at up
//       to 240 frames/s, cursor hidden. Prints "READY" once the first frame came. One JSON line per frame SCK gives:
//         {"t": <displayTime, ns on CLOCK_UPTIME_RAW>, "s": "complete"|"idle"|..., "n": <changed pixels>,
//          "b": [x0, y0, x1, y1] (the changed pixels' box, output pixels, x1/y1 exclusive) }
//       "n" and "b" compare the frame with the previous complete frame (the first frame has n = -1). A pixel changed
//       when one channel moved by more than 24 of 255. The last line is {"summary": {status: count}}.
//       Ends after SECONDS, on SIGINT/SIGTERM, or when stdin closes.
//   framewatch snap X Y W H FACTOR OUT.bgra
//       One frame of the rectangle as raw BGRA rows (width x height x 4 bytes); prints "<width> <height>".
//   framewatch locate RRGGBB [TOL]
//       The box (global points) of the main display's pixels within TOL (default 40) of that colour per channel:
//       prints "x y w h", exit 1 when none. The bench pages and terminals draw 12 x 12 marker squares.
//   framewatch diffbox A.bgra B.bgra WIDTH HEIGHT
//       The box (pixels) where two snaps differ: prints "x y w h n", exit 1 when they are the same.
//
// displayTime is mach_absolute_time, the clock hid_inject stamps its events on, so input and frames line up.
// Needs the Screen Recording grant (never prompts: a job without it exits 3).
// Build: xcrun swiftc -O -parse-as-library framewatch.swift -o framewatch (it has an async @main).
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

let timebase: mach_timebase_info_data_t = { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info }()

func nanoseconds(_ ticks: UInt64) -> UInt64 {
    ticks / UInt64(timebase.denom) * UInt64(timebase.numer) + ticks % UInt64(timebase.denom) * UInt64(timebase.numer) / UInt64(timebase.denom)
}

struct Fail: Error { let code: Int32; let message: String }

let threshold: Int32 = 24

/// The changed-pixel count and box between two BGRA buffers of the same shape.
func diff(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, width: Int, height: Int, rowA: Int, rowB: Int) -> (Int, [Int]) {
    var n = 0, x0 = width, y0 = height, x1 = 0, y1 = 0
    for y in 0..<height {
        let pa = a.advanced(by: y * rowA).assumingMemoryBound(to: UInt32.self)
        let pb = b.advanced(by: y * rowB).assumingMemoryBound(to: UInt32.self)
        for x in 0..<width where pa[x] != pb[x] {
            let u = pa[x], v = pb[x]
            var changed = false
            for shift in stride(from: 0, to: 24, by: 8) {
                let d = Int32((u >> UInt32(shift)) & 0xff) - Int32((v >> UInt32(shift)) & 0xff)
                if abs(d) > threshold { changed = true; break }
            }
            guard changed else { continue }
            n += 1
            if x < x0 { x0 = x }
            if x >= x1 { x1 = x + 1 }
            if y < y0 { y0 = y }
            if y >= y1 { y1 = y + 1 }
        }
    }
    return (n, n == 0 ? [] : [x0, y0, x1, y1])
}

func mainDisplay() async throws -> SCDisplay {
    guard CGPreflightScreenCaptureAccess() else { throw Fail(code: 3, message: "no Screen Recording grant") }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        throw Fail(code: 2, message: "no display")
    }
    return display
}

func configuration(_ rect: CGRect, factor: Double) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.sourceRect = rect
    config.width = max(1, Int((rect.width * factor).rounded()))
    config.height = max(1, Int((rect.height * factor).rounded()))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    config.queueDepth = 8
    config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    return config
}

final class Watcher: NSObject, SCStreamOutput {
    let out: FileHandle
    var previous: Data?
    var lines: [String] = []
    var statuses: [String: Int] = [:]
    var ready = false
    let lock = NSLock()

    init(out: FileHandle) { self.out = out }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first else { return }
        let raw = info[.status] as? Int ?? -1
        let status: String
        switch SCFrameStatus(rawValue: raw) {
        case .complete: status = "complete"
        case .idle: status = "idle"
        case .blank: status = "blank"
        case .suspended: status = "suspended"
        case .started: status = "started"
        case .stopped: status = "stopped"
        default: status = "unknown"
        }
        let ticks = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
        let t = nanoseconds(ticks)
        var n = -1
        var box: [Int] = []
        if status == "complete", let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let current = Data(bytes: base, count: row * height)
                if let previous, previous.count == current.count {
                    previous.withUnsafeBytes { p in
                        (n, box) = diff(p.baseAddress!, base, width: width, height: height, rowA: row, rowB: row)
                    }
                }
                previous = current
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        lock.lock()
        statuses[status, default: 0] += 1
        let b = box.isEmpty ? "" : ", \"b\": [\(box.map(String.init).joined(separator: ", "))]"
        lines.append("{\"t\": \(t), \"s\": \"\(status)\", \"n\": \(n)\(b)}")
        if lines.count >= 240 { flushLocked() }
        let first = !ready && status == "complete"
        if first { ready = true }
        lock.unlock()
        if first { print("READY"); fflush(stdout) }
    }

    func flushLocked() {
        guard !lines.isEmpty else { return }
        out.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        lines.removeAll(keepingCapacity: true)
    }

    func finish() {
        lock.lock()
        flushLocked()
        let summary = statuses.map { "\"\($0.key)\": \($0.value)" }.sorted().joined(separator: ", ")
        out.write("{\"summary\": {\(summary)}}\n".data(using: .utf8)!)
        lock.unlock()
    }
}

func rect(_ a: ArraySlice<String>) throws -> CGRect {
    let v = a.compactMap(Double.init)
    guard v.count == 4, v[2] > 0, v[3] > 0 else { throw Fail(code: 2, message: "a rectangle is X Y W H (points, W and H > 0)") }
    return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
}

func watch(_ args: [String]) async throws {
    guard args.count == 9, let factor = Double(args[6]), factor > 0, factor <= 2, let seconds = Double(args[7]) else {
        throw Fail(code: 2, message: "usage: framewatch watch X Y W H FACTOR SECONDS OUT.jsonl")
    }
    let area = try rect(args[2..<6])
    let display = try await mainDisplay()
    FileManager.default.createFile(atPath: args[8], contents: nil)
    guard let out = FileHandle(forWritingAtPath: args[8]) else { throw Fail(code: 2, message: "cannot write \(args[8])") }
    let watcher = Watcher(out: out)
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let stream = SCStream(filter: filter, configuration: configuration(area, factor: factor), delegate: nil)
    try stream.addStreamOutput(watcher, type: .screen, sampleHandlerQueue: DispatchQueue(label: "framewatch", qos: .userInteractive))
    try await stream.startCapture()
    let done = DispatchSemaphore(value: 0)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { done.signal() }
        source.resume()
        return source
    }
    // stdin closing (the bench died) ends the watch too.
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) { if line == "stop" { break } }
        done.signal()
    }
    _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global().async { c.resume(returning: done.wait(timeout: .now() + seconds) == .success) }
    }
    try? await stream.stopCapture()
    watcher.finish()
    try? out.close()
    _ = sources
}

func capture(_ area: CGRect, factor: Double) async throws -> (Data, Int, Int) {
    let display = try await mainDisplay()
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(area, factor: factor))
    let width = image.width, height = image.height
    var data = Data(count: width * height * 4)
    data.withUnsafeMutableBytes { p in
        let context = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (data, width, height)
}

func snap(_ args: [String]) async throws {
    guard args.count == 8, let factor = Double(args[6]), factor > 0, factor <= 2 else {
        throw Fail(code: 2, message: "usage: framewatch snap X Y W H FACTOR OUT.bgra")
    }
    let (data, width, height) = try await capture(try rect(args[2..<6]), factor: factor)
    try data.write(to: URL(fileURLWithPath: args[7]))
    print("\(width) \(height)")
}

func locate(_ args: [String]) async throws {
    guard args.count >= 3, args[2].count == 6, let rgb = UInt32(args[2], radix: 16) else {
        throw Fail(code: 2, message: "usage: framewatch locate RRGGBB [TOL]")
    }
    let tol = Int32(args.count > 3 ? Int(args[3]) ?? 40 : 40)
    let display = try await mainDisplay()
    let frame = CGDisplayBounds(display.displayID)
    let (data, width, height) = try await capture(CGRect(x: 0, y: 0, width: frame.width, height: frame.height), factor: 1)
    let want = [Int32((rgb >> 16) & 0xff), Int32((rgb >> 8) & 0xff), Int32(rgb & 0xff)]
    var x0 = width, y0 = height, x1 = -1, y1 = -1
    data.withUnsafeBytes { p in
        let px = p.bindMemory(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4  // BGRA
                if abs(Int32(px[i + 2]) - want[0]) <= tol, abs(Int32(px[i + 1]) - want[1]) <= tol, abs(Int32(px[i]) - want[2]) <= tol {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
        }
    }
    guard x1 >= 0 else { throw Fail(code: 1, message: "no pixel of #\(args[2]) on the main display") }
    print("\(x0) \(y0) \(x1 - x0 + 1) \(y1 - y0 + 1)")
}

func diffbox(_ args: [String]) throws {
    guard args.count == 6, let width = Int(args[4]), let height = Int(args[5]),
          let a = FileManager.default.contents(atPath: args[2]), let b = FileManager.default.contents(atPath: args[3]),
          a.count == width * height * 4, b.count == a.count else {
        throw Fail(code: 2, message: "usage: framewatch diffbox A.bgra B.bgra WIDTH HEIGHT (two snaps of that size)")
    }
    let (n, box) = a.withUnsafeBytes { pa in
        b.withUnsafeBytes { pb in diff(pa.baseAddress!, pb.baseAddress!, width: width, height: height, rowA: width * 4, rowB: width * 4) }
    }
    guard n > 0 else { throw Fail(code: 1, message: "the snaps are the same") }
    print("\(box[0]) \(box[1]) \(box[2] - box[0]) \(box[3] - box[1]) \(n)")
}

@main
struct FrameWatch {
    static func main() async {
        let args = CommandLine.arguments
        do {
            switch args.count > 1 ? args[1] : "" {
            case "watch": try await watch(args)
            case "snap": try await snap(args)
            case "locate": try await locate(args)
            case "diffbox": try diffbox(args)
            default: throw Fail(code: 2, message: "usage: framewatch watch|snap|locate|diffbox ...")
            }
            exit(0)
        } catch let fail as Fail {
            FileHandle.standardError.write("framewatch: \(fail.message)\n".data(using: .utf8)!)
            exit(fail.code)
        } catch {
            FileHandle.standardError.write("framewatch: \(error)\n".data(using: .utf8)!)
            exit(2)
        }
    }
}
