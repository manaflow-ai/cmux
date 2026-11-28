// itp-recorder: a screen recorder for frame-level drag checks (the in-tree pages resize work, hq
// artifacts/in-tree-pages). The Computer Use recorder films at a fixed 30 fps (24 fps achieved during window drags),
// so a bar of one 60 Hz frame cannot be judged from it. This films one rect of one display at the display's own rate.
// Built and signed by itp-recorder.sh (bundle id dev.cmux.itp-recorder, a background-only app: it never activates,
// has no Dock icon and opens no window).
//
//   itp-recorder --out DIR --pid PID [--rect X,Y,W,H] [--margin PT] [--fps 120] [--min-fps 55] [--seconds 300]
//                [--app-only] [--mbps 200] [--ppp N]
//   itp-recorder --analyze DIR [--min-fps 55]
//
// Capture: ScreenCaptureKit, a display filter (every window on that display; --app-only keeps the windows of PID's app)
// cropped by sourceRect to the rect: --rect in global points (top-left origin, CoreGraphics), or the bench window (PID's
// largest on-screen window at the start), grown by --margin on each side. The bench window's frame is read every 20 ms
// (CGWindowListCopyWindowInfo, no grant needed) and kept in frames.json as it changes. minimumFrameInterval 1/--fps (default 1/120), showsCursor false,
// 4:2:0 frames, HEVC at --mbps in DIR/movie.mov (a fragmented movie: a cut-off film still plays), at --ppp device
// pixels per point (default the display's). A frame comes only when the composited rect changed.
//
// Lifetime: the run starts on launch (one recording per process). It stops when DIR/stop exists, after --seconds, on
// SIGTERM or SIGINT, or when ScreenCaptureKit stops the stream. Files in DIR:
//   recorder.pid  this process
//   started.json  the crop, the display and the clocks, once the capture started
//   ready.json    the first frame's host time and the clocks, once a frame came
//   spans.json    written by the caller before DIR/stop (optional): {"spans": [{"name", "start", "end"}]} in host
//                 seconds (CLOCK_UPTIME_RAW: Python time.clock_gettime(time.CLOCK_UPTIME_RAW))
//   frames.json   every frame ScreenCaptureKit gave: [t, status, in_movie], t its display time in host seconds;
//                 a frame in the movie plays at t - pts_zero. Beside them crop_global_pt [x, y, w, h] and window, the
//                 bench window's frame [t, x, y, w, h] each time it changed (global points)
//   summary.json  the achieved rate per span and the self-check
//   done          the exit code, written last
//
// Self-check (the achieved rate per run): per span, the complete frames between its start and end; the rate is
// 1 / the median interval between them (the capture rate while the rect moves; a hitch of the filmed app shows in
// the p95 and max, not here) and, beside it, the average (frames - 1) / seconds. A span passes with 10 frames or more,
// a median rate of --min-fps (default 55) or more, at most 1% of its frames missing from the movie (encoder not
// ready), and a crop that holds the bench window's frame at the span's start (within 1 pt; the last reading at or before
// the start, else one within 100 ms after it): a window that moved off the crop would film the wrong region, and a
// frame not known fails the span too. With no spans.json each run of complete frames with no gap over 250 ms and 30 frames or more is a span.
// Exit 0 when every span passes, 3 when one fails or none could be rated, 2 for a usage or set-up error (no Screen
// Recording grant among them). The grant is only read (CGPreflightScreenCaptureAccess): this never asks for it, and
// never calls ScreenCaptureKit without it.
//
// --analyze DIR: the self-check alone over DIR/frames.json (and DIR/spans.json), printed as JSON; no capture, no
// AppKit (itp-recorder.sh's check of the check).
import AppKit
import AVFoundation
import CoreMedia
import Darwin
import ScreenCaptureKit

let bundleID = "dev.cmux.itp-recorder"

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("itp-recorder: \(message)\n".utf8))
    exit(2)
}

// MARK: Options

struct Options {
    var out: URL?
    var pid: pid_t?
    var rect: CGRect?
    var margin: Double = 0
    var fps: Int32 = 120
    var minFPS: Double = 55
    var seconds: Double = 300
    var appOnly = false
    var mbps: Double = 200
    var pixelsPerPoint: Double?
    var analyze: URL?
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var rest = arguments.dropFirst()[...]
    func value(_ flag: String) -> String {
        guard let next = rest.popFirst() else { fail("\(flag) takes a value") }
        return next
    }
    func number(_ flag: String, _ low: Double, _ high: Double) -> Double {
        let text = value(flag)
        guard let n = Double(text), n.isFinite, n >= low, n <= high else { fail("\(flag) takes \(low) to \(high), not \(text)") }
        return n
    }
    while let flag = rest.popFirst() {
        switch flag {
        case "--out": options.out = URL(fileURLWithPath: (value(flag) as NSString).expandingTildeInPath)
        case "--analyze": options.analyze = URL(fileURLWithPath: (value(flag) as NSString).expandingTildeInPath)
        case "--pid": options.pid = pid_t(number(flag, 1, Double(Int32.max)))
        case "--rect":
            let parts = value(flag).split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4, parts[2] >= 2, parts[3] >= 2 else { fail("--rect takes X,Y,W,H in points, W and H 2 or more") }
            options.rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        case "--margin": options.margin = number(flag, 0, 2000)
        case "--fps": options.fps = Int32(number(flag, 1, 240))
        case "--min-fps": options.minFPS = number(flag, 1, 240)
        case "--seconds": options.seconds = number(flag, 1, 3600)
        case "--mbps": options.mbps = number(flag, 1, 2000)
        case "--ppp": options.pixelsPerPoint = number(flag, 0.25, 4)
        case "--app-only": options.appOnly = true
        case "--help", "-h":
            print("usage: itp-recorder --out DIR --pid PID [--rect X,Y,W,H] [--margin PT] [--fps 120] [--min-fps 55] "
                + "[--seconds 300] [--app-only] [--mbps 200] [--ppp N]\n       itp-recorder --analyze DIR [--min-fps 55]")
            exit(0)
        case "--version":
            let info = Bundle.main.infoDictionary ?? [:]
            print("\(info["CFBundleIdentifier"] as? String ?? bundleID) \(info["ItpRecorderCommit"] as? String ?? "unbundled")")
            exit(0)
        default:
            // LaunchServices may add a process serial number argument on older systems.
            if flag.hasPrefix("-psn_") { continue }
            fail("unknown argument \(flag)")
        }
    }
    if options.analyze == nil {
        guard options.out != nil else { fail("--out DIR is required") }
        guard options.pid != nil else { fail("--pid PID (the bench window's app) is required") }
    }
    return options
}

// MARK: Clocks

let secondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1e9
}()

func hostSeconds() -> Double { Double(mach_absolute_time()) * secondsPerTick }

/// Every clock a caller may hold, read together, so host times convert to any of them. `host` is
/// mach_absolute_time (CLOCK_UPTIME_RAW), the clock of frame times and spans.
func clocks() -> [String: Double] {
    func read(_ id: clockid_t) -> Double {
        var ts = timespec()
        clock_gettime(id, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
    let before = hostSeconds()
    let realtime = read(CLOCK_REALTIME), uptimeRaw = read(CLOCK_UPTIME_RAW)
    let monotonicRaw = read(CLOCK_MONOTONIC_RAW), monotonic = read(CLOCK_MONOTONIC)
    let after = hostSeconds()
    return ["host": (before + after) / 2, "host_gap": after - before, "realtime": realtime, "uptime_raw": uptimeRaw,
            "monotonic_raw": monotonicRaw, "monotonic": monotonic]
}

// MARK: Self-check

struct FrameRecord {
    let t: Double
    let status: String
    let inMovie: Bool
}

struct Span {
    let name: String
    let start: Double
    let end: Double
}

/// The bench window's frame (global points) read at host time `t`.
struct WindowSample {
    let t: Double
    let frame: CGRect
}

/// The window's frame at `start`: the last reading at or before it, else the first within 100 ms after it.
func windowFrame(at start: Double, _ samples: [WindowSample]) -> CGRect? {
    if let before = samples.last(where: { $0.t <= start }) { return before.frame }
    if let after = samples.first(where: { $0.t > start }), after.t - start <= 0.1 { return after.frame }
    return nil
}

func box(_ rect: CGRect) -> [Double] { [rounded(rect.minX, 1), rounded(rect.minY, 1), rounded(rect.width, 1), rounded(rect.height, 1)] }

func percentile(_ sorted: [Double], _ q: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let rank = Int((q * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
}

func rounded(_ value: Double, _ places: Double = 2) -> Double {
    let scale = pow(10, places)
    return (value * scale).rounded() / scale
}

/// The achieved rate of one span and whether it passes.
func rate(_ span: Span, _ frames: [FrameRecord], minFPS: Double, crop: CGRect?, windows: [WindowSample]) -> [String: Any] {
    let inside = frames.filter { $0.status == "complete" && $0.t >= span.start && $0.t <= span.end }
    let times = inside.map(\.t)
    let missing = inside.filter { !$0.inMovie }.count
    var row: [String: Any] = ["name": span.name, "start": span.start, "end": span.end, "frames": times.count,
                              "not_in_movie": missing]
    var reasons: [String] = []
    let window = windowFrame(at: span.start, windows)
    if let window { row["window_at_start_pt"] = box(window) }
    if let crop, let window {
        let holds = crop.insetBy(dx: -1, dy: -1).contains(window)
        row["crop_holds_window"] = holds
        if !holds { reasons.append("the crop \(box(crop)) does not hold the bench window \(box(window)) at the span's start") }
    } else {
        row["crop_holds_window"] = false
        reasons.append(crop == nil ? "no crop recorded" : "the bench window's frame at the span's start is not known")
    }
    guard times.count >= 2, let first = times.first, let last = times.last, last > first else {
        reasons.append("\(times.count) frame(s) in the span: nothing to rate")
        row["ok"] = false
        row["reason"] = reasons.joined(separator: "; ")
        return row
    }
    let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
    let p50 = percentile(intervals, 0.5)
    let fpsP50 = p50 > 0 ? 1 / p50 : 0
    let average = Double(times.count - 1) / (last - first)
    row["seconds"] = rounded(last - first, 3)
    row["interval_ms"] = ["p50": rounded(p50 * 1000), "p95": rounded(percentile(intervals, 0.95) * 1000),
                          "max": rounded((intervals.last ?? 0) * 1000)]
    row["fps_p50"] = rounded(fpsP50, 1)
    row["fps_avg"] = rounded(average, 1)
    if times.count < 10 { reasons.append("\(times.count) frames, under 10") }
    if fpsP50 < minFPS { reasons.append("achieved \(rounded(fpsP50, 1)) fps (median interval), under \(minFPS): re-run") }
    if missing > max(1, times.count / 100) { reasons.append("\(missing) of \(times.count) frames missing from the movie") }
    row["ok"] = reasons.isEmpty
    if !reasons.isEmpty { row["reason"] = reasons.joined(separator: "; ") }
    return row
}

/// Runs of complete frames with no gap over 250 ms and 30 frames or more: the spans when the caller gave none.
func motionSpans(_ frames: [FrameRecord]) -> [Span] {
    let times = frames.filter { $0.status == "complete" }.map(\.t)
    var spans: [Span] = []
    var runStart = 0
    for index in times.indices where index == times.count - 1 || times[index + 1] - times[index] > 0.25 {
        if index - runStart + 1 >= 30 {
            spans.append(Span(name: "motion-\(spans.count + 1)", start: times[runStart], end: times[index]))
        }
        runStart = index + 1
    }
    return spans
}

func readSpans(_ url: URL) throws -> [Span]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let list = (object as? [String: Any])?["spans"] ?? object
    guard let rows = list as? [[String: Any]] else { throw Failure("spans.json: no list of spans") }
    return try rows.enumerated().map { (index: Int, row: [String: Any]) throws -> Span in
        guard let start = (row["start"] as? NSNumber)?.doubleValue, let end = (row["end"] as? NSNumber)?.doubleValue,
              end > start else { throw Failure("spans.json: span \(index) needs start < end (host seconds)") }
        return Span(name: row["name"] as? String ?? "span-\(index + 1)", start: start, end: end)
    }
}

func assess(_ frames: [FrameRecord], spans given: [Span]?, minFPS: Double, crop: CGRect?, windows: [WindowSample]) -> [String: Any] {
    let spans = given ?? motionSpans(frames)
    let rows = spans.map { rate($0, frames, minFPS: minFPS, crop: crop, windows: windows) }
    let rated = rows.compactMap { $0["fps_p50"] as? Double }
    var result: [String: Any] = [
        "min_fps": minFPS, "spans_from": given == nil ? "motion (no spans.json)" : "spans.json", "spans": rows,
        "frames": ["complete": frames.filter { $0.status == "complete" }.count,
                   "idle": frames.filter { $0.status == "idle" }.count,
                   "other": frames.filter { $0.status != "complete" && $0.status != "idle" }.count,
                   "not_in_movie": frames.filter { $0.status == "complete" && !$0.inMovie }.count],
    ]
    if let worst = rated.min() { result["achieved_fps_p50"] = worst }
    if let worstAverage = rows.compactMap({ $0["fps_avg"] as? Double }).min() { result["achieved_fps_avg"] = worstAverage }
    let failed = rows.filter { $0["ok"] as? Bool != true }
    result["ok"] = !rows.isEmpty && failed.isEmpty
    if rows.isEmpty {
        result["reason"] = "no span to rate (no spans.json and no run of 30 frames)"
    } else if !failed.isEmpty {
        result["reason"] = failed.map { "\($0["name"] ?? "?"): \($0["reason"] ?? "failed")" }.joined(separator: "; ")
    }
    return result
}

func writeJSON(_ object: Any, _ url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    try? data.write(to: url, options: .atomic)
}

func analyzeOffline(_ dir: URL, minFPS: Double) -> Int32 {
    do {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("frames.json")))
        guard let rows = (object as? [String: Any])?["frames"] as? [[Any]] else { throw Failure("frames.json: no frames list") }
        let frames = rows.compactMap { row -> FrameRecord? in
            guard row.count >= 3, let t = (row[0] as? NSNumber)?.doubleValue, let status = row[1] as? String,
                  let inMovie = row[2] as? Bool else { return nil }
            return FrameRecord(t: t, status: status, inMovie: inMovie)
        }
        let index = object as? [String: Any]
        let crop = (index?["crop_global_pt"] as? [NSNumber]).flatMap { v -> CGRect? in
            v.count == 4 ? CGRect(x: v[0].doubleValue, y: v[1].doubleValue, width: v[2].doubleValue, height: v[3].doubleValue) : nil
        }
        let windows = ((index?["window"] as? [[NSNumber]]) ?? []).compactMap { v -> WindowSample? in
            v.count == 5 ? WindowSample(t: v[0].doubleValue, frame: CGRect(x: v[1].doubleValue, y: v[2].doubleValue,
                                                                          width: v[3].doubleValue, height: v[4].doubleValue)) : nil
        }
        let result = assess(frames, spans: try readSpans(dir.appendingPathComponent("spans.json")), minFPS: minFPS,
                            crop: crop, windows: windows)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return result["ok"] as? Bool == true ? 0 : 3
    } catch {
        FileHandle.standardError.write(Data("itp-recorder: \(error)\n".utf8))
        return 2
    }
}

// MARK: Capture

/// Resumes a continuation once: on the callback or the deadline, whichever comes first.
final class Once<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    func set(_ continuation: CheckedContinuation<T, Error>) { lock.lock(); self.continuation = continuation; lock.unlock() }
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// A ScreenCaptureKit call with a completion, or a failure after `seconds` (a stuck replayd never answers).
func deadline<T>(_ what: String, seconds: Double = 10,
                 _ call: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
    let once = Once<T>()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        once.set(continuation)
        call { once.resume($0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            once.resume(.failure(Failure("ScreenCaptureKit did not \(what) within \(Int(seconds)) s")))
        }
    }
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let options: Options
    let out: URL
    let movieURL: URL
    /// Frames, the writer and `ending` live on this queue only.
    private let queue = DispatchQueue(label: "dev.cmux.itp-recorder.frames", qos: .userInteractive)
    private var frames: [FrameRecord] = []
    private var firstTime: Double?
    private var ending = false
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writeError: String?
    private let flags = NSLock()
    private var stopReason: String?
    private var signalSources: [DispatchSourceSignal] = []
    /// The bench window, the crop (global points) and the window's frame each time it changed: the run's own task only.
    private var benchWindow: CGWindowID = 0
    private var crop: CGRect?
    private var windows: [WindowSample] = []

    /// Reads the bench window's frame (no Screen Recording grant needed for bounds) and keeps it when it changed.
    private func sampleWindow() {
        guard benchWindow != 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], benchWindow) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return }
        if windows.last?.frame != frame { windows.append(WindowSample(t: hostSeconds(), frame: frame)) }
    }

    init(_ options: Options, out: URL) {
        self.options = options
        self.out = out
        movieURL = out.appendingPathComponent("movie.mov")
    }

    func requestStop(_ reason: String) {
        flags.lock()
        if stopReason == nil { stopReason = reason }
        flags.unlock()
    }

    private var stopRequested: String? {
        flags.lock()
        defer { flags.unlock() }
        return stopReason
    }

    private func file(_ name: String) -> URL { out.appendingPathComponent(name) }

    /// One recording; the exit code.
    func run() async -> Int32 {
        var summary: [String: Any] = ["bundle_id": Bundle.main.bundleIdentifier ?? "unbundled",
                                      "commit": Bundle.main.infoDictionary?["ItpRecorderCommit"] as? String ?? "unbundled",
                                      "fps_asked": Int(options.fps), "shows_cursor": false, "codec": "hevc",
                                      "mbps": options.mbps, "clocks_start": clocks()]
        func finish(_ code: Int32, _ error: String? = nil) -> Int32 {
            if let error { summary["error"] = error; summary["ok"] = false }
            summary["clocks_end"] = clocks()
            writeJSON(summary, file("summary.json"))
            try? Data("\(code)\n".utf8).write(to: file("done"), options: .atomic)
            return code
        }
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for name in ["stop", "done", "summary.json", "frames.json", "started.json", "ready.json", "movie.mov"] {
                try? FileManager.default.removeItem(at: file(name))
            }
            try Data("\(getpid())\n".utf8).write(to: file("recorder.pid"), options: .atomic)
        } catch {
            return finish(2, "output folder: \(error)")
        }
        // Read the grant only. Without it, ScreenCaptureKit would open the system's prompt: never on a shared Mac.
        guard CGPreflightScreenCaptureAccess() else {
            return finish(2, "no Screen Recording grant for \(Bundle.main.bundleIdentifier ?? "this process") (not asked)")
        }
        installSignals()
        let stream: SCStream
        do {
            let content: SCShareableContent = try await deadline("list the shareable content") { done in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                    done(content.map { .success($0) } ?? .failure(error ?? Failure("no shareable content")))
                }
            }
            // The bench window: PID's largest on-screen window. Its frame is read all through the run (the self-check
            // fails a span whose crop does not hold it at the span's start).
            guard let window = content.windows
                .filter({ $0.owningApplication?.processID == options.pid && $0.windowLayer == 0 && $0.isOnScreen })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw Failure("no on-screen window of pid \(options.pid ?? 0)")
            }
            benchWindow = window.windowID
            summary["window"] = ["id": Int(window.windowID), "title": window.title ?? "",
                                 "frame_pt": box(window.frame)] as [String: Any]
            var rect = (options.rect ?? window.frame).insetBy(dx: -options.margin, dy: -options.margin)
            guard let display = content.displays.max(by: {
                $0.frame.intersection(rect).area < $1.frame.intersection(rect).area
            }), display.frame.intersects(rect) else {
                throw Failure("no display under the rect \(rect)")
            }
            let source = rect.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let filter: SCContentFilter
            if options.appOnly {
                guard let app = content.applications.first(where: { $0.processID == options.pid }) else {
                    throw Failure("ScreenCaptureKit lists no app with pid \(options.pid ?? 0)")
                }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let scale = options.pixelsPerPoint ?? Double(filter.pointPixelScale)
            let width = Int((source.width * scale).rounded()) / 2 * 2
            let height = Int((source.height * scale).rounded()) / 2 * 2
            guard width >= 2, height >= 2 else { throw Failure("the rect has no size on its display") }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = source
            configuration.width = width
            configuration.height = height
            configuration.scalesToFit = false
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: options.fps)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.queueDepth = 8
            configuration.captureResolution = .best
            if #available(macOS 14.2, *) { configuration.includeChildWindows = true }
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            summary["display"] = ["id": Int(display.displayID), "name": screen?.localizedName ?? "",
                                  "max_fps": screen?.maximumFramesPerSecond ?? 0,
                                  "frame_pt": [display.frame.minX, display.frame.minY, display.frame.width, display.frame.height]] as [String: Any]
            crop = rect
            summary["crop"] = ["global_pt": [rect.minX, rect.minY, rect.width, rect.height],
                               "source_rect_pt": [source.minX, source.minY, source.width, source.height],
                               "pixels": [width, height], "pixels_per_point": scale,
                               "filter": options.appOnly ? "display, the windows of pid \(options.pid ?? 0) only" : "display, every window"] as [String: Any]
            let made = SCStream(filter: filter, configuration: configuration, delegate: self)
            try made.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            let _: Bool = try await deadline("start the capture") { done in
                made.startCapture { error in done(error.map { .failure($0) } ?? .success(true)) }
            }
            stream = made
        } catch {
            return finish(2, "\(error)")
        }
        var started = summary
        started["clocks"] = clocks()
        writeJSON(started, file("started.json"))
        let began = hostSeconds()
        var wroteReady = false
        sampleWindow()
        while stopRequested == nil {
            sampleWindow()
            if !wroteReady, let first = queue.sync(execute: { firstTime }) {
                writeJSON(["first_frame": first, "clocks": clocks()] as [String: Any], file("ready.json"))
                wroteReady = true
            }
            if FileManager.default.fileExists(atPath: file("stop").path) { requestStop("stop file") }
            if hostSeconds() - began >= options.seconds { requestStop("--seconds") }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        summary["stopped_by"] = stopRequested
        queue.sync { ending = true }
        do {
            let _: Bool = try await deadline("stop the capture") { done in
                stream.stopCapture { error in done(error.map { .failure($0) } ?? .success(true)) }
            }
        } catch {
            summary["stop_error"] = "\(error)"
        }
        let movieStatus: String = await withCheckedContinuation { continuation in
            queue.async { self.closeMovie { continuation.resume(returning: $0) } }
        }
        let (recorded, first, writeError) = queue.sync { (frames, firstTime, self.writeError) }
        summary["movie"] = ["path": movieURL.path, "status": movieStatus, "write_error": writeError ?? ""]
        sampleWindow()
        writeJSON(["clock": "host seconds (mach_absolute_time, CLOCK_UPTIME_RAW)", "pts_zero": first ?? 0,
                   "crop_global_pt": crop.map(box) ?? [], "window_id": Int(benchWindow),
                   "window": windows.map { [$0.t] + box($0.frame) },
                   "frames": recorded.map { [$0.t, $0.status, $0.inMovie] as [Any] }] as [String: Any], file("frames.json"))
        let spans: [Span]?
        do { spans = try readSpans(file("spans.json")) } catch {
            return finish(2, "\(error)")
        }
        let check = assess(recorded, spans: spans, minFPS: options.minFPS, crop: crop, windows: windows)
        for (key, value) in check { summary[key] = value }
        if movieStatus != "completed" {
            summary["ok"] = false
            summary["reason"] = [summary["reason"] as? String, "movie \(movieStatus)"].compactMap { $0 }.joined(separator: "; ")
        }
        return finish(summary["ok"] as? Bool == true ? 0 : 3)
    }

    private func installSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.requestStop(number == SIGTERM ? "SIGTERM" : "SIGINT") }
            source.resume()
            signalSources.append(source)
        }
    }

    // On `queue`.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !ending,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let time = Double((info[.displayTime] as? NSNumber)?.uint64Value ?? 0) * secondsPerTick
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            frames.append(FrameRecord(t: time, status: Self.name(status), inMovie: false))
            return
        }
        if firstTime == nil {
            firstTime = time
            openMovie(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        }
        var appended = false
        if let input, let adaptor, input.isReadyForMoreMediaData {
            appended = adaptor.append(buffer, withPresentationTime: CMTime(seconds: time - (firstTime ?? time), preferredTimescale: 1_000_000))
        }
        frames.append(FrameRecord(t: time, status: "complete", inMovie: appended))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        requestStop("ScreenCaptureKit stopped the stream: \(error)")
    }

    // On `queue`, at the first complete frame: an HEVC movie at that frame's size, fragmented each half second.
    private func openMovie(width: Int, height: Int) {
        do {
            let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
            writer.movieFragmentInterval = CMTime(value: 1, timescale: 2)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(options.mbps * 1_000_000), AVVideoExpectedSourceFrameRateKey: Int(options.fps),
                    AVVideoMaxKeyFrameIntervalKey: Int(options.fps), AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Failure("the movie writer refused a \(width)x\(height) input") }
            writer.add(input)
            // Before startWriting: an adaptor made on a started input raises an Objective-C exception.
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.startWriting() else { throw Failure("the movie writer did not start: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        } catch {
            writeError = "\(error)"
        }
    }

    // On `queue`.
    private func closeMovie(_ done: @escaping (String) -> Void) {
        guard let writer, let input, writer.status == .writing else {
            done("not written: \(writer.map { "status \($0.status.rawValue) \(String(describing: $0.error))" } ?? "no frame came")")
            return
        }
        input.markAsFinished()
        writer.finishWriting {
            done(writer.status == .completed ? "completed" : "failed: \(String(describing: writer.error))")
        }
    }

    private static func name(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        @unknown default: return "unknown"
        }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: Main

setvbuf(stdout, nil, _IOLBF, 0)
let options = parseOptions(CommandLine.arguments)
if let dir = options.analyze { exit(analyzeOffline(dir, minFPS: options.minFPS)) }
guard let out = options.out else { fail("--out DIR is required") }
// A background-only app: never activates, no Dock icon, no menu bar, no window.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let recorder = Recorder(options, out: out)
Task.detached {
    let code = await recorder.run()
    exit(code)
}
application.run()
