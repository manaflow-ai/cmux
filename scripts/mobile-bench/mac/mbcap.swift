// mbcap: the Mac half of the mobile bench's competitor capture (scripts/measure/mobile-bench-mac-capture.sh drives it
// through capture.py). An iPhone app running on an Apple Silicon Mac ("Designed for iPhone"), recorded at the display's
// rate with ScreenCaptureKit, every frame's presentation time kept.
//
//   xcrun swiftc -O -parse-as-library mbcap.swift -o mbcap
//
//   mbcap probe                       grants and displays as this process sees them (JSON line)
//   mbcap app BUNDLE_ID               where LaunchServices has the app: {"installed", "path", "version", "build",
//                                     "iphone_app" (an iPhone/iPad app wrapped for the Mac), "name"}
//   mbcap wrapped                     every iPhone/iPad app in /Applications and ~/Applications (JSON line)
//   mbcap pids BUNDLE_ID              the running processes of that app: {"pids": [...]}
//   mbcap window PID                  PID's largest on-screen layer-0 window, global points, top-left origin
//                                     (CGWindowList; no grant): {"window": [x, y, w, h] | null, "id"}
//   mbcap setframe PID X Y W H        moves and sizes PID's first window through Accessibility (exit 3 untrusted)
//   mbcap record X Y W H FPS OUT.mp4  ScreenCaptureKit stream of the main display's rect (global points) at up to FPS,
//                                     at the display's pixel scale, into H.264 (High, 40 Mbit/s at 120 fps), every
//                                     frame's own presentation time kept (no resampling: SCK sends a frame when the
//                                     screen changes). Prints {"ready": true, "t0_ns"} on the first frame; stops on a
//                                     `stop` line, stdin EOF, SIGTERM or 120 s; then prints the summary
//                                     {"frames", "first_pts_ns", "last_pts_ns", "size", "statuses", "dropped",
//                                     "p50_interval_ms", "peak_fps_250ms"} and writes OUT.pts.json (every frame's
//                                     pts in ns). Clocks: pts and t0_ns are CLOCK_UPTIME_RAW ns (mach_absolute_time),
//                                     the clock hid_inject stamps its events with, so stimulus_t = event - first pts.
//   mbcap crop IN.mp4 OUT.mp4 X Y W H every frame of IN (video pixels) cropped to the rect, same presentation times
//   mbcap stats IN.mp4                frames, duration and interval percentiles of a movie (no decode)
//
// Exit 0 done, 1 failed, 2 usage, 3 no grant (Screen Recording for record, Accessibility for setframe).
import AppKit
import ApplicationServices
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct Fail: Error { let code: Int32; let message: String }

func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

let timebase: mach_timebase_info_data_t = { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info }()

/// CMTime on the host clock (mach_absolute_time based) in ns.
func nanoseconds(_ time: CMTime) -> Int64 { CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value }

func box(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
}

/// Intervals (ms) and the highest frame count in any 250 ms window, scaled to a second.
func intervalStats(_ pts: [Int64]) -> [String: Any] {
    guard pts.count > 1 else { return ["p50_interval_ms": 0, "p10_interval_ms": 0, "p90_interval_ms": 0, "peak_fps_250ms": 0] }
    let gaps = zip(pts.dropFirst(), pts).map { Double($0 - $1) / 1e6 }.sorted()
    var peak = 0, j = 0
    for i in 0..<pts.count {
        while pts[i] - pts[j] >= 250_000_000 { j += 1 }
        peak = max(peak, i - j + 1)
    }
    return ["p50_interval_ms": percentile(gaps, 0.5), "p10_interval_ms": percentile(gaps, 0.1),
            "p90_interval_ms": percentile(gaps, 0.9), "peak_fps_250ms": Double(peak) * 4]
}

// MARK: probe, app, windows

func displays() -> [[String: Any]] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).map { id in
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        var fields: [String: Any] = ["id": Int(id), "bounds": box(bounds), "main": id == CGMainDisplayID()]
        fields["refresh_hz"] = mode?.refreshRate ?? 0
        fields["pixels"] = [mode?.pixelWidth ?? 0, mode?.pixelHeight ?? 0]
        if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
            fields["scale"] = Double(screen.backingScaleFactor)
            fields["max_fps"] = screen.maximumFramesPerSecond
            fields["name"] = screen.localizedName
        }
        return fields
    }
}

func probe() {
    emit(["screen_recording": CGPreflightScreenCaptureAccess(), "post_event": CGPreflightPostEventAccess(),
          "accessibility": AXIsProcessTrusted(), "displays": displays(), "user": NSUserName()])
}

func appInfo(_ url: URL) -> [String: Any] {
    let bundle = Bundle(url: url)
    let info = bundle?.infoDictionary ?? [:]
    // An iPhone or iPad app on a Mac is a wrapper: X.app/Wrapper/X.app (WrappedBundle links to it) holds the iOS bundle.
    let fm = FileManager.default
    var inner = info
    var iphone = false
    let wrapper = url.appendingPathComponent("Wrapper")
    if let items = try? fm.contentsOfDirectory(atPath: wrapper.path), let name = items.first(where: { $0.hasSuffix(".app") }) {
        iphone = true
        if let wrapped = Bundle(url: wrapper.appendingPathComponent(name))?.infoDictionary { inner = wrapped }
    } else if fm.fileExists(atPath: url.appendingPathComponent("WrappedBundle").path) {
        iphone = true
    }
    if inner["LSRequiresIPhoneOS"] as? Bool == true || inner["UIDeviceFamily"] != nil { iphone = true }
    return ["installed": true, "path": url.path, "iphone_app": iphone,
            "bundle_id": inner["CFBundleIdentifier"] as? String ?? info["CFBundleIdentifier"] as? String ?? "",
            "name": inner["CFBundleDisplayName"] as? String ?? inner["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
            "version": inner["CFBundleShortVersionString"] as? String ?? "", "build": inner["CFBundleVersion"] as? String ?? "",
            "device_family": inner["UIDeviceFamily"] ?? NSNull()]
}

func app(_ bundleID: String) {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        emit(appInfo(url))
        return
    }
    // LaunchServices may not have registered a wrapper yet: look for it by its inner bundle id too.
    for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".app") {
            let fields = appInfo(URL(fileURLWithPath: root).appendingPathComponent(name))
            if fields["bundle_id"] as? String == bundleID { emit(fields); return }
        }
    }
    emit(["installed": false, "bundle_id": bundleID])
}

func wrapped() {
    var apps: [[String: Any]] = []
    for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() where name.hasSuffix(".app") {
            let fields = appInfo(URL(fileURLWithPath: root).appendingPathComponent(name))
            if fields["iphone_app"] as? Bool == true { apps.append(fields) }
        }
    }
    emit(["wrapped": apps])
}

func pids(_ bundleID: String) {
    emit(["pids": NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { Int($0.processIdentifier) }])
}

func appWindow(_ pid: Int32) -> (CGRect, Int)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: (CGRect, Int)?
    var bestArea = 0.0
    for info in list {
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
        let area = Double(rect.width * rect.height)
        if area > bestArea { bestArea = area; best = (rect, info[kCGWindowNumber as String] as? Int ?? 0) }
    }
    return best
}

func window(_ pid: Int32) {
    if let found = appWindow(pid) { emit(["window": box(found.0), "id": found.1]) } else { emit(["window": NSNull()]) }
}

func setFrame(_ pid: Int32, _ rect: CGRect) throws {
    guard AXIsProcessTrusted() else { throw Fail(code: 3, message: "no Accessibility grant") }
    let element = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement], let first = windows.first else { throw Fail(code: 1, message: "pid \(pid) has no AX window") }
    var origin = rect.origin, size = rect.size
    let position = AXValueCreate(.cgPoint, &origin)!, extent = AXValueCreate(.cgSize, &size)!
    let a = AXUIElementSetAttributeValue(first, kAXPositionAttribute as CFString, position)
    let b = AXUIElementSetAttributeValue(first, kAXSizeAttribute as CFString, extent)
    Thread.sleep(forTimeInterval: 0.3)
    var fields: [String: Any] = ["position": a.rawValue, "size": b.rawValue]
    if let found = appWindow(pid) { fields["window"] = box(found.0) }
    emit(fields)
}

// MARK: record

func writerSettings(width: Int, height: Int, fps: Int) -> [String: Any] {
    // About 0.15 bit a pixel a frame at 120 fps: a phone-sized window's text stays sharp in a still.
    let bitrate = max(8_000_000, min(80_000_000, Int(Double(width * height * fps) * 0.15)))
    return [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoExpectedSourceFrameRateKey: fps,
                                              AVVideoMaxKeyFrameIntervalKey: fps,
                                              AVVideoAllowFrameReorderingKey: false] as [String: Any]]
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let lock = NSLock()
    var pts: [Int64] = []
    var statuses: [String: Int] = [:]
    var dropped = 0
    var failed = 0
    var stopping = false
    var streamError: String?

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let movie = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings(width: width, height: height, fps: fps))
        video.expectsMediaDataInRealTime = true
        guard movie.canAdd(video) else { throw Fail(code: 1, message: "the writer takes no H.264 input of \(width)x\(height)") }
        movie.add(video)
        // The adaptor before startWriting: AVFoundation refuses one for an input whose writer already started.
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard movie.startWriting() else { throw Fail(code: 1, message: "startWriting: \(movie.error.map { "\($0)" } ?? "")") }
        writer = movie
        input = video
        adaptor = pixels
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
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
        lock.lock()
        defer { lock.unlock() }
        statuses[status, default: 0] += 1
        guard !stopping, SCFrameStatus(rawValue: raw) == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let first = pts.isEmpty
        if first { writer.startSession(atSourceTime: time) }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        if adaptor.append(buffer, withPresentationTime: time) { pts.append(nanoseconds(time)) } else { failed += 1 }
        if first { emit(["ready": true, "t0_ns": nanoseconds(time)]) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        streamError = "\(error)"
        lock.unlock()
    }

    func finish() async -> [String: Any] {
        lock.lock()
        stopping = true
        let times = pts
        lock.unlock()
        if let last = times.last {
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: last, timescale: 1_000_000_000))
            await writer.finishWriting()
        } else {
            writer.cancelWriting()
        }
        var fields = intervalStats(times)
        fields["frames"] = times.count
        fields["first_pts_ns"] = times.first ?? 0
        fields["last_pts_ns"] = times.last ?? 0
        fields["statuses"] = statuses
        fields["dropped"] = dropped
        fields["append_failed"] = failed
        fields["writer_status"] = writer.status.rawValue
        if let error = writer.error { fields["writer_error"] = "\(error)" }
        if let streamError { fields["stream_error"] = streamError }
        return fields
    }
}

func record(_ a: [String]) async throws {
    guard a.count == 8, let x = Double(a[2]), let y = Double(a[3]), let w = Double(a[4]), let h = Double(a[5]),
          let fps = Int(a[6]), w > 0, h > 0, fps > 0, fps <= 240 else {
        throw Fail(code: 2, message: "usage: mbcap record X Y W H FPS OUT.mp4")
    }
    guard CGPreflightScreenCaptureAccess() else { throw Fail(code: 3, message: "no Screen Recording grant for this process") }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        throw Fail(code: 1, message: "no display")
    }
    let origin = CGDisplayBounds(display.displayID).origin
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let scale = Double(filter.pointPixelScale)
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(x: x - origin.x, y: y - origin.y, width: w, height: h)
    let width = Int(w * scale) / 2 * 2, height = Int(h * scale) / 2 * 2
    config.width = width
    config.height = height
    config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    config.showsCursor = false
    config.capturesAudio = false
    config.queueDepth = 8
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    let url = URL(fileURLWithPath: a[7])
    let recorder = try Recorder(url: url, width: width, height: height, fps: fps)
    let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "mbcap.record", qos: .userInteractive))
    try await stream.startCapture()
    let done = DispatchSemaphore(value: 0)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { done.signal() }
        source.resume()
        return source
    }
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) { if line == "stop" { break } }
        done.signal()
    }
    _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global().async { c.resume(returning: done.wait(timeout: .now() + 120) == .success) }
    }
    try? await stream.stopCapture()
    var summary = await recorder.finish()
    _ = sources
    summary["size"] = [width, height]
    summary["scale"] = scale
    summary["display_id"] = Int(display.displayID)
    summary["rect"] = [x, y, w, h]
    summary["done"] = true
    let times = recorder.pts
    if let data = try? JSONSerialization.data(withJSONObject: ["clock": "CLOCK_UPTIME_RAW ns", "pts_ns": times]) {
        try? data.write(to: URL(fileURLWithPath: a[7] + ".pts.json"))
    }
    emit(summary)
    if times.isEmpty { throw Fail(code: 1, message: "no frame was recorded") }
}

// MARK: movies

func videoTrack(_ path: String) async -> (AVURLAsset, AVAssetTrack?, Double) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let track = try? await asset.loadTracks(withMediaType: .video).first
    var fps = 0.0
    if let track { fps = Double((try? await track.load(.nominalFrameRate)) ?? 0) }
    return (asset, track, fps)
}

func stats(_ path: String) async throws {
    let (asset, track, fps) = await videoTrack(path)
    guard let track, let reader = try? AVAssetReader(asset: asset) else { throw Fail(code: 1, message: "no video track in \(path)") }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else { throw Fail(code: 1, message: "cannot read \(path)") }
    var times: [Int64] = []
    while let sample = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sample) > 0 { times.append(nanoseconds(CMSampleBufferGetPresentationTimeStamp(sample))) }
    }
    times.sort()
    var fields = intervalStats(times)
    fields["frames"] = times.count
    fields["duration_s"] = times.count > 1 ? Double(times.last! - times.first!) / 1e9 : 0
    fields["first_s"] = Double(times.first ?? 0) / 1e9
    fields["nominal_fps"] = fps
    emit(fields)
}

func crop(_ a: [String]) async throws {
    guard a.count == 8, let x = Int(a[4]), let y = Int(a[5]), let w = Int(a[6]), let h = Int(a[7]), w > 1, h > 1 else {
        throw Fail(code: 2, message: "usage: mbcap crop IN.mp4 OUT.mp4 X Y W H (video pixels)")
    }
    let (asset, track, fps) = await videoTrack(a[2])
    guard let track, let reader = try? AVAssetReader(asset: asset) else { throw Fail(code: 1, message: "no video track in \(a[2])") }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw Fail(code: 1, message: "cannot read \(a[2])") }
    let width = w / 2 * 2, height = h / 2 * 2
    let url = URL(fileURLWithPath: a[3])
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings(width: width, height: height, fps: max(30, Int(fps.rounded()))))
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    guard writer.startWriting() else { throw Fail(code: 1, message: "startWriting: \(writer.error.map { "\($0)" } ?? "")") }
    var frames = 0
    var last = CMTime.invalid
    while let sample = output.copyNextSampleBuffer() {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if frames == 0 { writer.startSession(atSourceTime: time) }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        guard let pool = adaptor.pixelBufferPool else { throw Fail(code: 1, message: "no pixel buffer pool") }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let target = made else { throw Fail(code: 1, message: "no pixel buffer") }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        let sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
        let srow = CVPixelBufferGetBytesPerRow(source), trow = CVPixelBufferGetBytesPerRow(target)
        if let s = CVPixelBufferGetBaseAddress(source), let t = CVPixelBufferGetBaseAddress(target) {
            let x0 = max(0, min(x, sw - 1)), copyW = max(0, min(width, sw - x0))
            for row in 0..<height {
                let sy = y + row
                let dst = t.advanced(by: row * trow)
                if sy < 0 || sy >= sh { memset(dst, 0, trow); continue }
                memcpy(dst, s.advanced(by: sy * srow + x0 * 4), copyW * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(target, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        if adaptor.append(target, withPresentationTime: time) { frames += 1; last = time }
    }
    input.markAsFinished()
    if last.isValid { writer.endSession(atSourceTime: last) }
    await writer.finishWriting()
    emit(["frames": frames, "size": [width, height], "writer_status": writer.status.rawValue,
          "writer_error": writer.error.map { "\($0)" } ?? ""])
    if frames == 0 || writer.status != .completed { throw Fail(code: 1, message: "crop wrote no movie") }
}

@main
struct MBCap {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let a = CommandLine.arguments
        do {
            switch a.count > 1 ? a[1] : "" {
            case "probe": probe()
            case "app" where a.count == 3: app(a[2])
            case "wrapped": wrapped()
            case "pids" where a.count == 3: pids(a[2])
            case "window" where a.count == 3: window(Int32(a[2]) ?? -1)
            case "setframe" where a.count == 7:
                let v = a[3...6].compactMap(Double.init)
                guard v.count == 4 else { throw Fail(code: 2, message: "usage: mbcap setframe PID X Y W H") }
                try setFrame(Int32(a[2]) ?? -1, CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
            case "record": try await record(a)
            case "crop": try await crop(a)
            case "stats" where a.count == 3: try await stats(a[2])
            default: throw Fail(code: 2, message: "usage: mbcap probe|app|wrapped|pids|window|setframe|record|crop|stats ...")
            }
            exit(0)
        } catch let fail as Fail {
            FileHandle.standardError.write("mbcap: \(fail.message)\n".data(using: .utf8)!)
            exit(fail.code)
        } catch {
            FileHandle.standardError.write("mbcap: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
