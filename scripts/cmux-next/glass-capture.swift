// glass-capture: what the display showed after each real key, read outside the app.
// input-glass-check.py compiles it (`xcrun swiftc -swift-version 5 -O`) and runs it once per surface.
//
//   glass-capture --check-grant
//   glass-capture --out FILE (--pid PID | --region X,Y,W,H) [--keys 200] [--warmup 6] [--interval-ms 120]
//                 [--quiet-ms 40] [--threshold 32] [--key-codes 7,51]
//
// It captures one small region of the display with ScreenCaptureKit at the display's refresh rate and posts real
// key presses at the HID event tap (CGEventPost), as a person's keys arrive: the window server, the app's event
// queue, AppKit. The default keys alternate `x` and Delete, so each one changes one glyph and the caret stays where
// it was. The region is the caret of the focused element of PID (Accessibility: AXBoundsForRange of the selected
// range), else that element's frame, else --region, in global display points (top-left origin).
//
// Chrome reads the time a frame was really shown from the display's presentation feedback
// (ui/gfx/presentation_feedback.h, delivered by components/viz/service/display/display.cc) and EventLatency ends
// there (cc/metrics/event_latency_tracing_recorder.cc). macOS gives a Core Animation app no such feedback, so cmux
// estimates it (PresentationClock); this tool is the ground truth that estimate is calibrated against.
//
// FILE gets, in order: `grant screen=yes|no accessibility=yes|no`; `ready DISPLAY X Y W H HZ SOURCE` once capture
// runs (the region in display-local points, captured at one pixel per point; SOURCE caret, element or region); then
// `key INDEX POST_NS KEYCODE WARMUP` per key (POST_NS read just before the key-down is posted) and `frame NS CHANGED`
// per complete frame (NS its displayTime, CHANGED the pixels that differ from the frame before), interleaved in time
// order; `status NS NAME` for blank, suspended, started and stopped frames; `end`. Every NS is CLOCK_UPTIME_RAW
// (mach_absolute_time in ns), the clock of NSEvent.timestamp and of the app's input.latency slots. On a failure it
// writes one `error TEXT` line and exits 2; without the Screen Recording grant TEXT starts with
// `no-screen-recording-grant`, without the Accessibility grant (needed to post keys) with `no-accessibility-grant`.
import ApplicationServices
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct Options {
    var out = ""
    var checkGrant = false
    var pid: pid_t?
    var region: CGRect?
    var keys = 200
    var warmup = 6
    var intervalMs = 120
    var quietMs = 40
    var threshold = 32
    var keyCodes: [CGKeyCode] = [7, 51]  // kVK_ANSI_X, kVK_Delete
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("glass-capture: \(message)\n".utf8))
    exit(64)
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    func number(_ name: String) -> Int {
        guard let value = Int(args.next() ?? "") else { usage("\(name) needs an integer") }
        return value
    }
    while let arg = args.next() {
        switch arg {
        case "--check-grant": options.checkGrant = true
        case "--out": options.out = args.next() ?? ""
        case "--pid": options.pid = pid_t(number(arg))
        case "--keys": options.keys = number(arg)
        case "--warmup": options.warmup = number(arg)
        case "--interval-ms": options.intervalMs = number(arg)
        case "--quiet-ms": options.quietMs = number(arg)
        case "--threshold": options.threshold = number(arg)
        case "--region":
            let parts = (args.next() ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { usage("--region takes X,Y,W,H") }
            options.region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        case "--key-codes":
            let codes = (args.next() ?? "").split(separator: ",").compactMap { CGKeyCode($0) }
            guard !codes.isEmpty else { usage("--key-codes takes a comma list of virtual key codes") }
            options.keyCodes = codes
        default: usage("unknown argument \(arg)")
        }
    }
    if options.checkGrant { return options }
    if options.out.isEmpty { usage("--out FILE is required") }
    if options.pid == nil && options.region == nil { usage("--pid PID or --region X,Y,W,H is required") }
    if options.keys <= 0 || options.warmup < 0 || options.intervalMs <= 0 || options.quietMs < 0 || options.threshold < 0 {
        usage("--keys and --interval-ms must be positive; --warmup, --quiet-ms and --threshold not negative")
    }
    return options
}

func uptimeNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func grantLine() -> (line: String, screen: Bool, accessibility: Bool) {
    let screen = CGPreflightScreenCaptureAccess()
    let accessibility = AXIsProcessTrusted()
    return ("grant screen=\(screen ? "yes" : "no") accessibility=\(accessibility ? "yes" : "no")", screen, accessibility)
}

// MARK: Region

/// The focused element of `pid` through Accessibility.
func focusedElement(of pid: pid_t) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

func rectValue(_ value: CFTypeRef?) -> CGRect? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &rect) else { return nil }
    return rect
}

/// The caret of `element`: the bounds of its selected range, in global display points.
func caretRect(of element: AXUIElement) -> CGRect? {
    var range: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
          let range else { return nil }
    var bounds: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range,
                                                     &bounds) == .success,
          let rect = rectValue(bounds), rect.height > 0 else { return nil }
    return rect
}

/// The frame of `element` in global display points.
func elementFrame(of element: AXUIElement) -> CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size,
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent),
          extent.width > 0, extent.height > 0 else { return nil }
    return CGRect(origin: origin, size: extent)
}

/// The region to capture and where it came from. Around a caret: three line heights before it and five after (the
/// glyph typed and the caret's next place), half a line above and below.
func captureRegion(_ options: Options) -> (rect: CGRect, source: String)? {
    if let pid = options.pid, let element = focusedElement(of: pid) {
        if let caret = caretRect(of: element) {
            let line = max(caret.height, 12)
            var box = CGRect(x: caret.minX - 3 * line, y: caret.minY - line / 2, width: 8 * line, height: caret.height + line)
            if let frame = elementFrame(of: element) { box = box.intersection(frame.insetBy(dx: -2, dy: -2)) }
            if !box.isNull, box.width >= 4, box.height >= 4 { return (box.integral, "caret") }
        }
        if let frame = elementFrame(of: element) { return (frame.integral, "element") }
    }
    if let region = options.region { return (region.integral, "region") }
    return nil
}

/// The refresh rate of `displayID` in Hz: the mode's rate, else the screen's maximum frame rate, else 60.
func refreshHz(_ displayID: CGDirectDisplayID) -> Double {
    if let mode = CGDisplayCopyDisplayMode(displayID), mode.refreshRate > 0 { return mode.refreshRate }
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID }),
       screen.maximumFramesPerSecond > 0 {
        return Double(screen.maximumFramesPerSecond)
    }
    return 60
}

// MARK: Capture and keys

/// Writes FILE, compares frames and posts keys. Every method runs on `queue` (the stream's sample handler queue and
/// the key timer's), so the frame state and the key schedule share one thread.
final class GlassRun: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "glass-capture", qos: .userInteractive)
    private let handle: FileHandle
    private let options: Options
    private let numer: UInt64
    private let denom: UInt64
    private let source = CGEventSource(stateID: .hidSystemState)
    private var previous: [UInt8] = []
    private var lastChangeNanos: UInt64 = 0
    private var posted = 0
    private var timer: DispatchSourceTimer?
    var onFinish: (() -> Void)?

    init(handle: FileHandle, options: Options) {
        self.handle = handle
        self.options = options
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = UInt64(info.numer)
        denom = UInt64(max(info.denom, 1))
        super.init()
    }

    func write(_ line: String) {
        handle.write(Data((line + "\n").utf8))
    }

    func close() {
        try? handle.synchronize()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        let nanos: UInt64
        if let displayTime = info[.displayTime] as? UInt64 {
            nanos = displayTime * numer / denom
        } else {
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            nanos = seconds.isFinite && seconds > 0 ? UInt64(seconds * 1e9) : 0
        }
        switch status {
        case .complete:
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let changed = changedPixels(pixels)
            if changed > 0 { lastChangeNanos = max(lastChangeNanos, nanos) }
            write("frame \(nanos) \(changed)")
        case .idle: return
        case .blank: write("status \(nanos) blank")
        case .suspended: write("status \(nanos) suspended")
        case .started: write("status \(nanos) started")
        case .stopped: write("status \(nanos) stopped")
        @unknown default: write("status \(nanos) unknown")
        }
    }

    /// The pixels of `buffer` (BGRA) whose blue, green or red differ by more than the threshold from the frame
    /// before; keeps a copy of this frame. The first frame counts as unchanged.
    private func changedPixels(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let packed = width * 4
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let first = previous.count != packed * height
        if first { previous = [UInt8](repeating: 0, count: packed * height) }
        let limit = options.threshold
        var changed = 0
        previous.withUnsafeMutableBufferPointer { old in
            guard let kept = old.baseAddress else { return }
            if first {
                for row in 0..<height { memcpy(kept + row * packed, bytes + row * rowBytes, packed) }
                return
            }
            for row in 0..<height {
                let line = bytes + row * rowBytes
                let saved = kept + row * packed
                var x = 0
                while x < packed {
                    let b = abs(Int(line[x]) - Int(saved[x]))
                    let g = abs(Int(line[x + 1]) - Int(saved[x + 1]))
                    let r = abs(Int(line[x + 2]) - Int(saved[x + 2]))
                    if max(b, max(g, r)) > limit { changed += 1 }
                    x += 4
                }
                memcpy(saved, line, packed)
            }
        }
        return changed
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.write("error the stream stopped: \(error.localizedDescription)")
            self.close()
            exit(2)
        }
    }

    /// Starts the key schedule: one key per interval once the region has shown no change for --quiet-ms (a key
    /// waits at most ten intervals for that; input-glass-check.py drops a key that did not get it).
    func startKeys() {
        let made = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(options.intervalMs)
        made.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        var waited = 0
        made.setEventHandler { [weak self] in
            guard let self else { return }
            let total = self.options.warmup + self.options.keys
            if self.posted >= total {
                made.cancel()
                self.onFinish?()
                return
            }
            let now = uptimeNanos()
            let quiet = UInt64(self.options.quietMs) * 1_000_000
            if now < self.lastChangeNanos + quiet && waited < 10 {
                waited += 1
                return
            }
            waited = 0
            self.post(index: self.posted)
            self.posted += 1
        }
        timer = made
        made.resume()
    }

    private func post(index: Int) {
        let code = options.keyCodes[index % options.keyCodes.count]
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            write("error CGEvent could not make key \(code)")
            close()
            exit(2)
        }
        let postNanos = uptimeNanos()
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        write("key \(index) \(postNanos) \(code) \(index < options.warmup ? 1 : 0)")
    }
}

let options = parseOptions()
let grant = grantLine()
if options.checkGrant {
    print(grant.line)
    exit(grant.screen && grant.accessibility ? 0 : 2)
}
guard FileManager.default.createFile(atPath: options.out, contents: nil),
      let handle = FileHandle(forWritingAtPath: options.out) else {
    usage("cannot write \(options.out)")
}
let run = GlassRun(handle: handle, options: options)
var stream: SCStream?

func fail(_ text: String) -> Never {
    run.queue.sync {
        run.write("error \(text)")
        run.close()
    }
    exit(2)
}

run.queue.sync { run.write(grant.line) }
if !grant.screen {
    fail("no-screen-recording-grant: this process may not capture the screen (System Settings > Privacy & Security > "
        + "Screen & System Audio Recording, for the app that started it)")
}
if !grant.accessibility {
    fail("no-accessibility-grant: this process may not post keys (System Settings > Privacy & Security > "
        + "Accessibility, for the app that started it)")
}

func finish() {
    let running = stream
    run.queue.asyncAfter(deadline: .now() + .milliseconds(400)) {
        Task {
            if let running { try? await running.stopCapture() }
            run.queue.sync {
                run.write("end")
                run.close()
            }
            exit(0)
        }
    }
}

func start() async {
    guard let found = captureRegion(options) else {
        fail("no region: pid \(options.pid.map { "\($0)" } ?? "-") has no focused element with a frame and no --region was given")
    }
    let region = found.rect
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) else {
            fail("no display contains the region \(region)")
        }
        let local = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            .intersection(CGRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height))
        guard !local.isNull, local.width >= 1, local.height >= 1 else { fail("the region \(region) is off its display") }
        let hz = refreshHz(display.displayID)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local
        configuration.width = Int(local.width)
        configuration.height = Int(local.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(hz.rounded()))
        configuration.queueDepth = 8
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let made = SCStream(filter: filter, configuration: configuration, delegate: run)
        try made.addStreamOutput(run, type: .screen, sampleHandlerQueue: run.queue)
        try await made.startCapture()
        stream = made
        let line = "ready \(display.displayID) \(Int(local.minX)) \(Int(local.minY)) \(Int(local.width)) \(Int(local.height)) "
            + "\(hz) \(found.source)"
        run.queue.async {
            run.write(line)
            run.onFinish = finish
            run.startKeys()
        }
    } catch {
        fail("ScreenCaptureKit: \(error.localizedDescription) (does this process have the Screen Recording grant?)")
    }
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: run.queue)
    source.setEventHandler {
        run.write("error stopped by signal \(number)")
        run.close()
        exit(2)
    }
    source.resume()
    return source
}
Task { await start() }
dispatchMain()
