// The frame recorder of the tab switch harness (scripts/cmux-next/tab_switch_frames.py): the screen where one app
// window is, as the window server composites it, every frame the display shows a change, read through
// ScreenCaptureKit from outside the app. It works the same on a shipped NIGHTLY (no debug.* control commands) and
// on a tagged build, and it sees the window's Chromium page windows too (a display region, not a window filter).
//
//   swiftc -O -o tab-switch-recorder recorder.swift
//   tab-switch-recorder PID [WIDTH]
//
// It prints one JSON line on stdout once capture runs ({"ready": true, "w", "h", "window": [x, y, w, h] points,
// "display_hz", "preflight", ...}, or {"error": ...} and exits 1), then reads commands on stdin, one a line:
//   begin PATH   start a segment: every frame from now (and the frame on screen now, first) goes to PATH
//   mark NAME    stamp NAME with this process's clock now (the harness writes it just before it sends an action)
//   end          close the segment; prints {"ended": true, "frames": N, "marks": [[NAME, SECONDS], ...]}
//   quit         stop capture and exit (EOF does too)
// A segment file is records of an 8-byte little-endian Float64 (the frame's display time, seconds of the host clock,
// mach_absolute_time) and then W*H bytes of 8-bit gray, row by row from the top. Frames come only when the picture
// changed (ScreenCaptureKit's `complete` frames), so a frame lasts until the next one's time.

import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

func fail(_ text: String) -> Never {
    emit(["error": text])
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    FileHandle.standardError.write(Data("usage: tab-switch-recorder PID [WIDTH]\n".utf8))
    exit(2)
}
let outWidth = args.count > 2 ? max(64, Int(args[2]) ?? 480) : 480

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func seconds(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }
func now() -> Double { seconds(mach_absolute_time()) }

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let lock = NSLock()
    let width: Int, height: Int
    var latest: (time: Double, gray: [UInt8])?
    var file: FileHandle?
    var written = 0
    var marks: [[Any]] = []
    var received = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sample.imageBuffer else { return }
        let time = (info[.displayTime] as? UInt64).map(seconds) ?? now()
        guard let gray = Self.gray(buffer, width: width, height: height) else { return }
        lock.lock()
        defer { lock.unlock() }
        received += 1
        latest = (time, gray)
        if let file { write(file, time, gray) }
    }

    func write(_ file: FileHandle, _ time: Double, _ gray: [UInt8]) {
        var stamp = time.bitPattern.littleEndian
        var record = Data(bytes: &stamp, count: 8)
        record.append(contentsOf: gray)
        file.write(record)
        written += 1
    }

    /// BGRA to 8-bit gray at the stream's own size (the stream already scales the region to width x height).
    static func gray(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let (w, h) = (min(width, CVPixelBufferGetWidth(buffer)), min(height, CVPixelBufferGetHeight(buffer)))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<h {
            let row = pixels + y * rowBytes
            for x in 0..<w {
                // One typed step each: the expression in one line ran past the type checker's limit.
                let p: UnsafeMutablePointer<UInt8> = row + x * 4 // B, G, R, A
                let r: Int = Int(p[2]) * 77
                let g: Int = Int(p[1]) * 150
                let b: Int = Int(p[0]) * 29
                let luma: Int = (r + g + b) >> 8
                out[y * width + x] = UInt8(luma)
            }
        }
        return out
    }

    func begin(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        file?.closeFile()
        guard FileManager.default.createFile(atPath: path, contents: nil), let handle = FileHandle(forWritingAtPath: path) else {
            file = nil
            return "cannot write \(path)"
        }
        file = handle
        written = 0
        marks = []
        // The picture on screen now: a segment always starts with what was there before its first mark.
        if let latest { write(handle, latest.time, latest.gray) }
        return nil
    }

    func mark(_ name: String) {
        let time = now()
        lock.lock()
        marks.append([name, time])
        lock.unlock()
    }

    func end() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        file?.closeFile()
        file = nil
        return ["ended": true, "frames": written, "marks": marks]
    }
}

func displayHz(_ displayID: CGDirectDisplayID) -> Double {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID }),
       screen.maximumFramesPerSecond > 0 {
        return Double(screen.maximumFramesPerSecond)
    }
    let rate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
    return rate > 0 ? rate : 60
}

let preflight = CGPreflightScreenCaptureAccess()
var recorder: Recorder?
var stream: SCStream?
var ready: [String: Any] = [:]
let started = DispatchSemaphore(value: 0)
var startError: String?

SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
    defer { started.signal() }
    guard let content else {
        startError = "no shareable content (Screen Recording grant? preflight \(preflight)): \(error.map { "\($0)" } ?? "none")"
        return
    }
    let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 200 }
    func area(_ w: SCWindow) -> Double { Double(w.frame.width) * Double(w.frame.height) }
    guard let window = windows.max(by: { area($0) < area($1) }) else {
        startError = "no on-screen window of pid \(pid) (\(content.windows.count) windows listed; preflight \(preflight))"
        return
    }
    guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) ?? content.displays.first else {
        startError = "no display"
        return
    }
    let region = window.frame.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    let regionWidth = Double(region.width), regionHeight = Double(region.height)
    let scaledHeight: Double = Double(outWidth) * regionHeight / regionWidth
    let height = max(32, Int(scaledHeight.rounded()))
    let hz = displayHz(display.displayID)
    let config = SCStreamConfiguration()
    config.sourceRect = region
    config.width = outWidth
    config.height = height
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(60, Int(hz.rounded()))))
    config.queueDepth = 8
    config.showsCursor = false
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let made = Recorder(width: outWidth, height: height)
    let s = SCStream(filter: filter, configuration: config, delegate: nil)
    do {
        try s.addStreamOutput(made, type: .screen, sampleHandlerQueue: DispatchQueue(label: "tab-switch.recorder"))
    } catch {
        startError = "stream output: \(error)"
        return
    }
    let capture = DispatchSemaphore(value: 0)
    s.startCapture { error in
        if let error { startError = "start capture: \(error)" }
        capture.signal()
    }
    capture.wait()
    guard startError == nil else { return }
    recorder = made
    stream = s
    func box(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
    var fields: [String: Any] = [:]
    fields["ready"] = true
    fields["w"] = outWidth
    fields["h"] = height
    fields["window_id"] = Int(window.windowID)
    fields["window"] = box(window.frame)
    fields["display"] = box(display.frame)
    fields["display_id"] = Int(display.displayID)
    fields["display_hz"] = hz
    fields["preflight"] = preflight
    fields["px_per_point"] = Double(outWidth) / regionWidth
    ready = fields
}
if started.wait(timeout: .now() + 20) == .timedOut { fail("capture did not start within 20 s (preflight \(preflight))") }
if let startError { fail(startError) }
guard let recorder else { fail("no recorder") }
// The first frame: a capture that never delivers one (no grant) says so here, not in every segment.
let firstBy = Date().addingTimeInterval(5)
while Date() < firstBy {
    recorder.lock.lock()
    let got = recorder.received
    recorder.lock.unlock()
    if got > 0 { break }
    Thread.sleep(forTimeInterval: 0.01)
}
ready["first_frame"] = recorder.received > 0
emit(ready)

while let line = readLine() {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first {
    case "begin":
        if parts.count == 2, let problem = recorder.begin(parts[1]) { emit(["error": problem]) } else { emit(["begun": true]) }
    case "mark":
        recorder.mark(parts.count == 2 ? parts[1] : "")
    case "end":
        emit(recorder.end())
    case "quit":
        break
    default:
        emit(["error": "unknown command \(line)"])
        continue
    }
    if parts.first == "quit" { break }
}
_ = recorder.end()
let stopped = DispatchSemaphore(value: 0)
stream?.stopCapture { _ in stopped.signal() }
_ = stopped.wait(timeout: .now() + 5)
exit(0)
