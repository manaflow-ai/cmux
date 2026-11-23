// Keypress-to-glyph latency of a running app's focused text input, measured from outside the app, so the
// same harness times cmux NEXT, Zed and Warp (scripts/measure/composer-key-latency.sh compiles and runs it).
// Per key: mach_absolute_time just before CGEventPostToPid, then the ScreenCaptureKit frame (SCStream on the
// app's front window region of its display, SCStreamFrameInfo.displayTime) that first shows the change.
//
//   swiftc -O -swift-version 5 -o keylat composer-key-latency.swift
//   keylat OUT_JSON SHOTS_DIR ROUNDS PER_ROUND GAP_MS SPEC [SPEC ...]
//   SPEC  name|pid|setup[|fallback-name|fallback-setup]
//         setup: chords sent to pid once before the first round, space separated (cmd-shift-slash, cmd-n,
//         escape, ...); empty for none. When 3 probe keys show no glyph, the fallback setup is sent and the
//         app is measured under the fallback name (Zed's agent panel -> a plain buffer); else it is
//         "blocked: no-echo" (a login wall, an unfocused input).
//
// The keys are 'm' then Delete, GAP_MS apart (so the field never grows and the caret stays solid: editors
// stop blinking while typed into). For each key the frame before it is the baseline; the frame state just
// before the next key is the key's end state; the latency is the first frame whose 16 px tiles that differ
// in the end state carry at least a quarter of the end state's changed pixels. Tiles that change by
// themselves (spinners, a blinking caret) during a 300 ms quiet window before each round's measured keys are
// ignored. Apps alternate every round (the order rotates). Prints
//   KEYLAT <app> n <N> p50 <ms> p95 <ms> min <ms> hz <refresh>      (the 'm' insertions)
//   KEYLAT-DEL <app> n <N> p50 <ms> p95 <ms> min <ms> hz <refresh>  (the deletions)
//   KEYLAT <app> blocked: <why>

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)
func say(_ s: String) { print("KEYLAT-LOG \(s)") }

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func ticksToMs(_ ticks: Int64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

func pump(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

let args = CommandLine.arguments
guard args.count >= 7, let rounds = Int(args[3]), let perRound = Int(args[4]), let gapMs = Double(args[5]) else {
    FileHandle.standardError.write(Data("usage: keylat OUT_JSON SHOTS_DIR ROUNDS PER_ROUND GAP_MS SPEC...\n".utf8))
    exit(2)
}
let outFile = args[1], shotsDir = args[2]

// MARK: keys

let keyCodes: [String: CGKeyCode] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
    "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
    "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E, "slash": 0x2C, "period": 0x2F,
    "return": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "escape": 0x35,
]

func post(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil, pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        event.flags = flags
        if let text {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event.postToPid(pid)
    }
}

func chord(_ spec: String, pid: pid_t) {
    var flags: CGEventFlags = []
    var key = ""
    for part in spec.split(separator: "-").map(String.init) {
        switch part {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: key = part
        }
    }
    guard let code = keyCodes[key] else { say("unknown key in chord \(spec)"); return }
    post(code, flags: flags, pid: pid)
}

// MARK: windows, displays, activation

func frontWindow(_ pid: pid_t) -> (CGWindowID, CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    var best: (CGWindowID, CGRect)?
    var bestArea: CGFloat = 0
    for window in list {
        guard (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } == pid,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              let id = window[kCGWindowNumber as String] as? Int else { continue }
        if rect.width * rect.height > bestArea { bestArea = rect.width * rect.height; best = (CGWindowID(id), rect) }
    }
    return best
}

// The owner of the frontmost normal window (front to back order), which needs no run loop to be current.
func frontPid() -> pid_t? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
        if let owner = window[kCGWindowOwnerPID as String] as? Int { return pid_t(owner) }
    }
    return nil
}

func activate(_ pid: pid_t) -> String {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return "no-app" }
    app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    pump(0.6)
    if frontPid() == pid { return "activate" }
    if let url = app.bundleURL {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", url.path]
        try? open.run()
        open.waitUntilExit()
        pump(0.8)
        if frontPid() == pid { return "open-a" }
    }
    // Last resort: a click in the window's title bar strip (top 10 pt, centre), which activates the app.
    if let window = frontWindow(pid) {
        let rect = window.1
        let point = CGPoint(x: rect.midX, y: rect.minY + 6)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        pump(0.6)
        if frontPid() == pid { return "title-click" }
    }
    return "not-front"
}

func displayHz(_ displayID: CGDirectDisplayID) -> (Int, Double) {
    let screen = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
    }
    return (screen?.maximumFramesPerSecond ?? 0, CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0)
}

func screenshot(_ windowID: CGWindowID, _ name: String) {
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", "\(windowID)", "\(shotsDir)/\(name).png"]
    try? shot.run()
    shot.waitUntilExit()
}

// MARK: capture

struct KeyRecord {
    var kind: String
    var measured: Bool
    var t: UInt64
    var baseline: [UInt32]
    var frames: [(UInt64, [Int: Int])] = []
}

final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "keylat.frames", qos: .userInteractive)
    let tile = 16
    var width = 0, height = 0, tilesX = 0
    var last: [UInt32] = []
    var calibrating = false
    var noise = Set<Int>()
    var key: KeyRecord?
    var done: [KeyRecord] = []
    var frameCount = 0

    func diff(_ a: [UInt32], _ b: [UInt32]) -> [Int: Int] {
        var tiles: [Int: Int] = [:]
        guard a.count == b.count else { return tiles }
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    let row = y * width, tileRow = (y / tile) * tilesX
                    var x = 0
                    while x < width {
                        if pa[row + x] != pb[row + x] { tiles[tileRow + x / tile, default: 0] += 1 }
                        x += 1
                    }
                }
            }
        }
        return tiles
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sample.imageBuffer else { return }
        let shown = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var current = [UInt32](repeating: 0, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            current.withUnsafeMutableBytes { dst in
                for y in 0..<h { memcpy(dst.baseAddress! + y * w * 4, base + y * rowBytes, w * 4) }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        frameCount += 1
        if w != width || h != height {
            width = w; height = h; tilesX = (w + tile - 1) / tile
            last = current
            return
        }
        if calibrating, !last.isEmpty { for t in diff(last, current).keys { noise.insert(t) } }
        if var record = key {
            if shown < record.t { record.baseline = current } else { record.frames.append((shown, diff(record.baseline, current))) }
            key = record
        }
        last = current
    }

    // Ends the open key (if any) and opens one stamped now; the caller posts the key right after.
    func begin(kind: String, measured: Bool) {
        queue.sync {
            if let record = key { done.append(record) }
            key = KeyRecord(kind: kind, measured: measured, t: mach_absolute_time(), baseline: last)
        }
    }

    func finish() { queue.sync { if let record = key { done.append(record) }; key = nil } }

    // ms from the key to the first frame showing a quarter of its end state's change; nil when nothing changed.
    func latency(_ record: KeyRecord) -> Double? {
        guard let end = record.frames.last?.1 else { return nil }
        let endTiles = end.filter { !noise.contains($0.key) }
        let endSum = endTiles.values.reduce(0, +)
        guard endSum > 0 else { return nil }
        for (shown, tiles) in record.frames {
            let sum = endTiles.keys.reduce(0) { $0 + (tiles[$1] ?? 0) }
            if sum * 4 >= endSum { return ticksToMs(Int64(shown) - Int64(record.t)) }
        }
        return nil
    }
}

func shareable() -> SCShareableContent? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: SCShareableContent?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        if let error { say("SCShareableContent: \(error)") }
        result = content
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 10)
    return result
}

struct Session {
    let stream: SCStream
    let capture: Capture
    let displayID: CGDirectDisplayID
}

func startCapture(pid: pid_t) -> Session? {
    guard let window = frontWindow(pid), let content = shareable() else { say("pid \(pid): no window or no content"); return nil }
    let rect = window.1
    let center = CGPoint(x: rect.midX, y: rect.midY)
    guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else { return nil }
    let source = rect.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    let config = SCStreamConfiguration()
    config.sourceRect = source
    config.width = max(16, Int(source.width))
    config.height = max(16, Int(source.height))
    config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    config.queueDepth = 6
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let capture = Capture()
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    do { try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue) } catch {
        say("addStreamOutput: \(error)"); return nil
    }
    let semaphore = DispatchSemaphore(value: 0)
    var failed: Error?
    stream.startCapture { error in failed = error; semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 10)
    if let failed { say("startCapture: \(failed)"); return nil }
    return Session(stream: stream, capture: capture, displayID: display.displayID)
}

func stopCapture(_ session: Session) {
    let semaphore = DispatchSemaphore(value: 0)
    session.stream.stopCapture { _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 5)
}

// Types pairs ('m', Delete) GAP_MS apart; returns nothing, the records are in the capture.
func typePairs(_ session: Session, pid: pid_t, count: Int, measured: Bool) {
    for _ in 0..<count {
        session.capture.begin(kind: "insert", measured: measured)
        post(keyCodes["m"]!, text: "m", pid: pid)
        pump(gapMs / 1000)
        session.capture.begin(kind: "delete", measured: measured)
        post(keyCodes["delete"]!, text: "\u{7F}", pid: pid)
        pump(gapMs / 1000)
    }
    session.capture.finish()
}

func calibrate(_ session: Session) {
    session.capture.queue.sync { session.capture.calibrating = true }
    pump(0.3)
    session.capture.queue.sync { session.capture.calibrating = false }
}

// MARK: apps

final class AppRun {
    var name: String
    let pid: pid_t
    let setup: String
    let fallbackName: String?
    let fallbackSetup: String?
    var status = "pending"
    var setupUsed = ""
    var activations: [String] = []
    var insert: [Double] = [], delete: [Double] = []
    var insertMisses = 0, deleteMisses = 0
    var noiseTiles: [Int] = []
    var hz = 0
    var modeHz = 0.0
    var frames = 0
    init(_ spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        name = parts[0]
        pid = pid_t(parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        setup = parts.count > 2 ? parts[2] : ""
        fallbackName = parts.count > 3 ? parts[3] : nil
        fallbackSetup = parts.count > 4 ? parts[4] : nil
    }
}

func sendSetup(_ setup: String, pid: pid_t) {
    for item in setup.split(separator: " ") {
        chord(String(item), pid: pid)
        pump(1.5)
    }
}

// Three probe pairs: does an 'm' show at all?
func probe(_ app: AppRun) -> Bool {
    guard let session = startCapture(pid: app.pid) else { return false }
    pump(0.3)
    typePairs(session, pid: app.pid, count: 1, measured: false) // stop the caret blinking
    calibrate(session)
    typePairs(session, pid: app.pid, count: 3, measured: false)
    pump(0.2)
    stopCapture(session)
    let capture = session.capture
    let seen = capture.done.filter { $0.kind == "insert" }.suffix(3).compactMap { capture.latency($0) }
    say("\(app.name) probe: \(seen.count)/3 insertions seen \(seen.map { String(format: "%.1f", $0) })")
    return seen.count >= 2
}

let apps = args[6...].map(AppRun.init)
let permissions = ["screen_capture": CGPreflightScreenCaptureAccess(), "post_event": CGPreflightPostEventAccess()]
say("permissions \(permissions)")
if !permissions["screen_capture"]! { say("no Screen Recording permission: ScreenCaptureKit will deliver nothing") }

for app in apps {
    guard app.pid > 0, NSRunningApplication(processIdentifier: app.pid) != nil else { app.status = "blocked: not running"; continue }
    app.activations.append(activate(app.pid))
    sendSetup(app.setup, pid: app.pid)
    app.setupUsed = app.setup
    if probe(app) {
        app.status = "ok"
    } else if let fallback = app.fallbackName {
        if let window = frontWindow(app.pid) { screenshot(window.0, "\(app.name)-no-echo") }
        say("\(app.name): no echo, falling back to \(fallback) (\(app.fallbackSetup ?? ""))")
        app.name = fallback
        sendSetup(app.fallbackSetup ?? "", pid: app.pid)
        app.setupUsed = app.fallbackSetup ?? ""
        app.status = probe(app) ? "ok" : "blocked: no-echo"
    } else {
        app.status = "blocked: no-echo"
    }
    if let window = frontWindow(app.pid) { screenshot(window.0, "\(app.name)-setup") }
}

let live = apps.filter { $0.status == "ok" }
for round in 0..<rounds where !live.isEmpty {
    let order = (0..<live.count).map { live[($0 + round) % live.count] }
    for app in order {
        app.activations.append(activate(app.pid))
        guard let session = startCapture(pid: app.pid) else { app.insertMisses += perRound; continue }
        pump(0.3)
        typePairs(session, pid: app.pid, count: 3, measured: false)
        calibrate(session)
        typePairs(session, pid: app.pid, count: perRound, measured: true)
        pump(0.2)
        stopCapture(session)
        let capture = session.capture
        for record in capture.done where record.measured {
            let value = capture.latency(record)
            if record.kind == "insert" {
                if let value { app.insert.append(value) } else { app.insertMisses += 1 }
            } else {
                if let value { app.delete.append(value) } else { app.deleteMisses += 1 }
            }
        }
        app.noiseTiles.append(capture.noise.count)
        app.frames += capture.frameCount
        (app.hz, app.modeHz) = displayHz(session.displayID)
        say("round \(round) \(app.name): \(app.insert.count) insert, \(app.insertMisses) missed, noise tiles \(capture.noise.count)")
        if round == rounds - 1, let window = frontWindow(app.pid) { screenshot(window.0, "\(app.name)-end") }
    }
}

func pct(_ values: [Double], _ q: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[max(0, min(sorted.count - 1, Int((q * Double(sorted.count)).rounded(.up)) - 1))]
}
func stats(_ values: [Double]) -> [String: Any] {
    func value(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
    return ["n": values.count, "p50": value(pct(values, 0.5)), "p95": value(pct(values, 0.95)),
            "min": value(values.min()), "max": value(values.max())]
}
func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }

var rows: [[String: Any]] = []
for app in apps {
    if app.status != "ok" {
        print("KEYLAT \(app.name) \(app.status)")
    } else {
        print("KEYLAT \(app.name) n \(app.insert.count) p50 \(f1(pct(app.insert, 0.5))) p95 \(f1(pct(app.insert, 0.95))) min \(f1(app.insert.min())) hz \(app.hz)")
        print("KEYLAT-DEL \(app.name) n \(app.delete.count) p50 \(f1(pct(app.delete, 0.5))) p95 \(f1(pct(app.delete, 0.95))) min \(f1(app.delete.min())) hz \(app.hz)")
    }
    rows.append(["name": app.name, "pid": app.pid, "status": app.status, "setup": app.setupUsed,
                 "activations": app.activations, "insert": stats(app.insert), "delete": stats(app.delete),
                 "insert_ms": app.insert, "delete_ms": app.delete, "insert_misses": app.insertMisses,
                 "delete_misses": app.deleteMisses, "noise_tiles": app.noiseTiles, "frames": app.frames,
                 "hz": app.hz, "display_mode_hz": app.modeHz])
}
let report: [String: Any] = ["rounds": rounds, "per_round": perRound, "gap_ms": gapMs, "permissions": permissions,
                             "method": "CGEventPostToPid key -> first SCStream frame (displayTime) showing the key's change",
                             "apps": rows]
if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: URL(fileURLWithPath: outFile))
}
exit(live.isEmpty ? 1 : 0)
