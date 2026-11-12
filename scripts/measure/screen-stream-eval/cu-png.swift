// The computer-use preview's frame path as the app runs it today, on one window, for the cu-png
// target (README.md): a ScreenCaptureKit window stream at the window's own pixel size (BGRA, as
// the helper's `application_surface_start` writes its frame ring), read at 6 frames a second,
// scaled to 360 px on the long side with vImage (ComputerUseFrameRing.scaled), encoded as PNG
// (ComputerUseHelperSurfaceFrames.png) and as a base64 `data:` URL (what the app hands the chat
// webview). It leaves out what the app adds on top, so its cost is a floor: the helper's copy into
// the shared-memory ring, the corner rounding, the JavaScript evaluation and the webview's PNG decode.
//
//   swiftc -O -o screen-eval-cu-png cu-png.swift
//   screen-eval-cu-png WINDOW_ID SECONDS SNAPSHOT_PNG GO_FILE RAW_JSON [FPS] [LONG_SIDE]
//
// RAW_JSON: {"series": [{"unix_ms", "bytes", "frames", "encode_ms"}], "extra": {...}}, one row a second
// (bytes: the data URLs' length; encode_ms: the p50 of that second's scale + PNG + base64 wall time).

import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 6, let windowID = UInt32(args[1]), let seconds = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: screen-eval-cu-png WINDOW_ID SECONDS SNAPSHOT_PNG GO_FILE RAW_JSON [FPS] [LONG_SIDE]\n".utf8))
    exit(2)
}
let (snapshotFile, goFile, rawFile) = (args[3], args[4], args[5])
let fps = args.count > 6 ? Int(args[6]) ?? 6 : 6
let longSide = args.count > 7 ? Int(args[7]) ?? 360 : 360

func unixMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
func threadCPUms() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
}
func processCPUms() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let t = { (v: timeval) in Double(v.tv_sec) * 1000 + Double(v.tv_usec) / 1000 }
    return t(usage.ru_utime) + t(usage.ru_stime)
}
func p50(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.sorted()[values.count / 2] }

final class Newest: NSObject, SCStreamOutput, @unchecked Sendable {
    let lock = NSLock()
    var buffer: CVPixelBuffer?
    var sequence: UInt64 = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = sample.imageBuffer else { return }
        lock.lock()
        buffer = image
        sequence += 1
        lock.unlock()
    }
}

/// ComputerUseFrameRing.scaledSize and .scaled: vImage scale of BGRA into a CGImage.
func scaled(_ buffer: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let scale = min(1, Double(longSide) / Double(max(width, height)))
    let size = (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                               rowBytes: CVPixelBufferGetBytesPerRow(buffer))
    guard let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: size.0 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
          let data = context.data else { return nil }
    var destination = vImage_Buffer(data: data, height: vImagePixelCount(size.1), width: vImagePixelCount(size.0),
                                    rowBytes: context.bytesPerRow)
    guard vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil } // as ComputerUseFrameRing.scaled
    return context.makeImage()
}

func png(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("cu-png: \(text)\n".utf8))
    exit(1)
}

let newest = Newest()
let started = DispatchSemaphore(value: 0)
var stream: SCStream?
SCShareableContent.getWithCompletionHandler { content, error in
    guard let content, let window = content.windows.first(where: { $0.windowID == windowID }) else {
        fail("no window \(windowID) (\(error.map { "\($0)" } ?? "not listed"))")
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    let pointScale = Double(filter.pointPixelScale)
    config.width = Int(window.frame.width * pointScale)
    config.height = Int(window.frame.height * pointScale)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.showsCursor = true
    let s = SCStream(filter: filter, configuration: config, delegate: nil)
    do {
        try s.addStreamOutput(newest, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cu-png.capture"))
    } catch { fail("output: \(error)") }
    s.startCapture { error in
        if let error { fail("start: \(error)") }
        stream = s
        FileHandle.standardError.write(Data("cu-png: capturing window \(windowID) at \(config.width)x\(config.height) px, \(fps) fps, scaled to \(longSide) px\n".utf8))
        started.signal()
    }
}
if started.wait(timeout: .now() + 15) == .timedOut { fail("capture did not start within 15 s") }

// The app's pacing: one read per 1/fps; a read that finds no newer frame sends nothing.
let interval = 1.0 / Double(fps)
let cpuStart = processCPUms(), wallStart = Date()
let end = wallStart.addingTimeInterval(seconds)
var lastSequence: UInt64 = 0
var lastPNG: Data?
var series: [[String: Any]] = []
var second = (start: unixMs(), bytes: 0, frames: 0, ms: [Double]())
var allMs: [Double] = [], allCPU: [Double] = [], allBytes: [Double] = []
var wentGo = false
var next = Date()
while Date() < end {
    next = next.addingTimeInterval(interval)
    newest.lock.lock()
    let (buffer, sequence) = (newest.buffer, newest.sequence)
    newest.lock.unlock()
    if let buffer, sequence > lastSequence {
        lastSequence = sequence
        let t0 = Date(), c0 = threadCPUms()
        if let image = scaled(buffer), let data = png(image) {
            let url = "data:image/png;base64,\(data.base64EncodedString())"
            let ms = Date().timeIntervalSince(t0) * 1000, cpu = threadCPUms() - c0
            second.bytes += url.utf8.count
            second.frames += 1
            second.ms.append(ms)
            allMs.append(ms); allCPU.append(cpu); allBytes.append(Double(url.utf8.count))
            lastPNG = data
            if !wentGo {
                wentGo = true
                FileManager.default.createFile(atPath: goFile, contents: nil)
                FileHandle.standardError.write(Data("passive: first frame\n".utf8))
            }
        }
    }
    // Fixed one-second buckets, each stamped at its end as rd's series is (eval.py takes a row as
    // one second and keeps rows whose stamp falls in a phase): a late tick never stretches a bucket.
    let now = unixMs()
    while now >= second.start + 1000 {
        series.append(["unix_ms": second.start + 1000, "bytes": second.bytes, "frames": second.frames,
                       "encode_ms": p50(second.ms) as Any])
        second = (second.start + 1000, 0, 0, [])
    }
    let wait = next.timeIntervalSinceNow
    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
}
let wall = Date().timeIntervalSince(wallStart) * 1000
let cpuPct = (processCPUms() - cpuStart) / wall * 100
stream?.stopCapture { _ in }
if let lastPNG { try? lastPNG.write(to: URL(fileURLWithPath: snapshotFile)) }
let report: [String: Any] = [
    "series": series,
    "extra": ["process_cpu_pct": cpuPct, "frame_cpu_ms_p50": p50(allCPU) as Any, "frame_wall_ms_p50": p50(allMs) as Any,
              "frame_bytes_p50": p50(allBytes) as Any, "frames": allMs.count, "fps": fps, "long_side": longSide,
              "path": "SCK window BGRA -> vImage scale -> PNG -> base64 data URL (no ring copy, corners, JS eval or webview decode)"],
]
let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
try json.write(to: URL(fileURLWithPath: rawFile))
exit(0)
