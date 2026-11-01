// first5s-photon: what one app window showed, frame by frame, read from ScreenCaptureKit in a process of its own
// (scripts/cmux-next/first-5s-typing.py's external clock: it times classic cmux, which has no typing probe, and
// checks the probe of cmux-next builds against the screen).
//
//   first5s-photon --pid PID --out FILE [--seconds 600] [--rect X,Y,W,H] [--fps 240]
//
// Captures the largest on-screen window of PID (desktop independent: other windows do not count) at its point size;
// --rect is a part of it in window points from its top left. Writes to FILE one `ready WINDOW_ID WxH` line once the
// stream runs (or `error TEXT`, exit 2), then one line per delivered frame whose pixels changed:
// `frame DISPLAY_UPTIME_NS CHANGED_PIXELS X Y W H`, the bounding box of the change against the frame before, in
// captured pixels. DISPLAY_UPTIME_NS is the frame's display time on CLOCK_UPTIME_RAW (mach_absolute_time in ns, the
// clock of NSEvent timestamps and of the bench's key posts). Ends at SIGTERM, SIGINT or after --seconds with `end`.
// Needs the Screen Recording grant.
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct Options {
    var pid: pid_t = 0
    var out = ""
    var seconds = 600.0
    var rect: CGRect?
    var fps = 240
}

func fail(_ text: String, _ handle: FileHandle? = nil) -> Never {
    handle?.write(Data("error \(text)\n".utf8))
    FileHandle.standardError.write(Data("first5s-photon: \(text)\n".utf8))
    exit(2)
}

func parse() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--pid": options.pid = pid_t(args.next() ?? "") ?? 0
        case "--out": options.out = args.next() ?? ""
        case "--seconds": options.seconds = Double(args.next() ?? "") ?? 0
        case "--fps": options.fps = Int(args.next() ?? "") ?? 0
        case "--rect":
            let parts = (args.next() ?? "").split(separator: ",").compactMap { Double($0) }
            if parts.count == 4 { options.rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) }
        default: fail("unknown argument \(arg)")
        }
    }
    if options.pid <= 0 || options.out.isEmpty || options.seconds <= 0 || options.fps <= 0 { fail("--pid and --out are required") }
    return options
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "first5s-photon")
    private let handle: FileHandle
    private let numer: UInt64
    private let denom: UInt64
    private var previous: [UInt32] = []
    private var width = 0
    private var height = 0

    init(handle: FileHandle) {
        self.handle = handle
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = UInt64(info.numer)
        denom = UInt64(info.denom)
    }

    func write(_ line: String) { handle.write(Data((line + "\n").utf8)) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let machTime = (info[.displayTime] as? UInt64) ?? 0
        let uptimeNs = machTime * numer / denom
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        if w != width || h != height {
            width = w; height = h
            previous = [UInt32](repeating: 0, count: w * h)
        }
        var changed = 0, minX = w, minY = h, maxX = -1, maxY = -1
        previous.withUnsafeMutableBufferPointer { last in
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
                let offset = y * w
                for x in 0..<w where row[x] != last[offset + x] {
                    last[offset + x] = row[x]
                    changed += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        if changed > 0 {
            write("frame \(uptimeNs) \(changed) \(minX) \(minY) \(maxX - minX + 1) \(maxY - minY + 1)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        write("error stopped: \(error.localizedDescription)")
        write("end")
        exit(3)
    }
}

let options = parse()
FileManager.default.createFile(atPath: options.out, contents: nil)
guard let handle = FileHandle(forWritingAtPath: options.out) else { fail("cannot write \(options.out)") }
let recorder = Recorder(handle: handle)
var activeStream: SCStream?

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        recorder.queue.sync { recorder.write("end") }
        exit(0)
    }
    source.resume()
    _ = Unmanaged.passRetained(source)
}
DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) {
    recorder.queue.sync { recorder.write("end") }
    exit(0)
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication?.processID == options.pid && $0.frame.width > 200 && $0.frame.height > 200 }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            fail("no on-screen window of pid \(options.pid)", handle)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let rect = options.rect ?? CGRect(origin: .zero, size: window.frame.size)
        config.sourceRect = rect
        config.width = max(16, Int(rect.width))
        config.height = max(16, Int(rect.height))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 8
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        activeStream = stream
        recorder.queue.sync { recorder.write("ready \(window.windowID) \(config.width)x\(config.height)") }
    } catch {
        fail("capture: \(error.localizedDescription)", handle)
    }
}
dispatchMain()
