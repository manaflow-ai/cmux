// motion-capture-timeline: the frame times of one display from ScreenCaptureKit, recorded in a process of its own.
// It is motion-hitches.py's second timing source (plans/cmux-next/chrome-parity/p03-rendering.md, done check DC3):
// what the display showed, read outside the app, so no probe runs in the app under test.
//
//   motion-capture-timeline --out FILE [--fps 120] [--seconds 1800] [--display ID]
//
// motion-hitches.py compiles it (`xcrun swiftc -swift-version 5 -O`) and runs it for a whole session. It writes to
// FILE one `ready DISPLAY_ID WIDTHxHEIGHT FPS` line once capture runs (or one `error TEXT` line, then exit 2), then
// one line per frame ScreenCaptureKit delivers: `frame UPTIME_NS STATUS`. UPTIME_NS is the frame's display time on
// CLOCK_UPTIME_RAW (mach_absolute_time in ns, the clock of the bench's input times); STATUS is complete (the
// content changed), idle, blank, suspended, started or stopped. It captures at a quarter of the display's size:
// a frame arrives when any pixel changed, at any size. Ends at SIGTERM, SIGINT or after --seconds, with `end`.
// It needs the Screen Recording grant; without it the `error` line says so.
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

struct Options {
    var out = ""
    var fps = 120
    var seconds = 1800.0
    var displayID: CGDirectDisplayID?
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("motion-capture-timeline: \(message)\n".utf8))
    exit(64)
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--out": options.out = args.next() ?? ""
        case "--fps": options.fps = Int(args.next() ?? "") ?? 0
        case "--seconds": options.seconds = Double(args.next() ?? "") ?? 0
        case "--display": options.displayID = CGDirectDisplayID(args.next() ?? "")
        default: usage("unknown argument \(arg)")
        }
    }
    if options.out.isEmpty { usage("--out FILE is required") }
    if options.fps <= 0 || options.seconds <= 0 { usage("--fps and --seconds must be positive") }
    return options
}

/// Writes the timeline. Every write runs on `queue`, the stream's sample handler queue.
final class Timeline: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "motion-capture-timeline")
    private let handle: FileHandle
    private let numer: UInt64
    private let denom: UInt64

    init(handle: FileHandle) {
        self.handle = handle
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = UInt64(info.numer)
        denom = UInt64(max(info.denom, 1))
        super.init()
    }

    /// Call on `queue` only.
    func write(_ line: String) {
        handle.write(Data((line + "\n").utf8))
    }

    /// Call on `queue` only.
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
        let nanoseconds: UInt64
        if let displayTime = info[.displayTime] as? UInt64 {
            nanoseconds = displayTime * numer / denom
        } else {
            // The host clock's seconds are mach_absolute_time's.
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            nanoseconds = seconds.isFinite && seconds > 0 ? UInt64(seconds * 1e9) : 0
        }
        write("frame \(nanoseconds) \(Self.name(status))")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.write("error the stream stopped: \(error.localizedDescription)")
            self.close()
            exit(3)
        }
    }

    static func name(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete: "complete"
        case .idle: "idle"
        case .blank: "blank"
        case .suspended: "suspended"
        case .started: "started"
        case .stopped: "stopped"
        @unknown default: "unknown"
        }
    }
}

let options = parseOptions()
guard FileManager.default.createFile(atPath: options.out, contents: nil),
      let handle = FileHandle(forWritingAtPath: options.out) else {
    usage("cannot write \(options.out)")
}
let timeline = Timeline(handle: handle)
var stream: SCStream?
var stopping = false

func fail(_ text: String) -> Never {
    timeline.queue.sync {
        timeline.write("error \(text)")
        timeline.close()
    }
    exit(2)
}

func start() async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let wanted = options.displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted }) else {
            fail("no display \(wanted) among \(content.displays.map(\.displayID))")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(64, display.width / 4)
        configuration.height = max(64, display.height / 4)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.queueDepth = 8
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let made = SCStream(filter: filter, configuration: configuration, delegate: timeline)
        try made.addStreamOutput(timeline, type: .screen, sampleHandlerQueue: timeline.queue)
        try await made.startCapture()
        stream = made
        let line = "ready \(display.displayID) \(configuration.width)x\(configuration.height) \(options.fps)"
        timeline.queue.async { timeline.write(line) }
    } catch {
        fail("ScreenCaptureKit: \(error.localizedDescription) (does this process have the Screen Recording grant?)")
    }
}

/// Runs on the main queue (signal sources and the time cap).
func stop() {
    if stopping { return }
    stopping = true
    let running = stream
    Task {
        if let running { try? await running.stopCapture() }
        timeline.queue.sync {
            timeline.write("end")
            timeline.close()
        }
        exit(0)
    }
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { stop() }
    source.resume()
    return source
}
DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { stop() }
Task { await start() }
dispatchMain()
