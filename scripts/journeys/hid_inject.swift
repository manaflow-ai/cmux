// hid_inject: real HID input at exact times, for timed video and latency cases (handoff resize-videos/KIT.md).
//
//   hid_inject run SCRIPT.json LOG.json      posts the script's events, writes the log, exit 0 (ran), 2 (bad script),
//                                            3 (no PostEvent grant), 4 (ran, but below the rate floor: NOT RUN)
//   hid_inject plan SCRIPT.json LOG.json     no events: the same schedule and log with "posted": false (self-check)
//   hid_inject stampcheck                    no events: an event stamped as `run` stamps it must read back through
//                                            NSEvent within 5 ms of CLOCK_UPTIME_RAW (exit 0), else exit 5
//
// Python makes no timestamp on a timed path (cmux-ad 2026-11-02 03:40Z). This compiled tool posts each event with
// CGEventPost at the HID tap at a mach_absolute_time deadline, sets the event's own timestamp to the moment it is
// posted, and logs that timestamp: the clock of NSEvent.timestamp, CACurrentMediaTime and ScreenCaptureKit's
// displayTime. A CGEvent timestamp counts mach ticks, not nanoseconds (125/3 ns a tick on Apple silicon; the app's
// DebugKeySequence notes the same, #30257): the event gets mach_absolute_time(), the log gets the same instant in ns.
// The app's input journal and the recorder's frames use the same clock, so a judge lines them up after
// the run. CuaDriver's call takes 260-290 ms and its drag reached the app at about 12 events/s: not for timed paths.
//
// SCRIPT: {"start_delay_ms": 200, "rate_floor": 0.95, "steps": [STEP, ...]}, coordinates in global points from the
// primary display's top-left (CGEvent's space). STEP is one of:
//   {"do": "move", "x": X, "y": Y}
//   {"do": "key", "key_code": N, "modifiers": ["cmd","shift","option","control"], "hold_ms": 40}
//   {"do": "click", "x": X, "y": Y, "count": 1, "hold_ms": 40, "modifiers": [...]}
//   {"do": "drag", "from": [X, Y], "to": [X, Y], "duration_ms": D, "hz": 120, "hold_ms": 60, "modifiers": [...]}
//       mouse down at `from`, `hold_ms`, then one dragged event per 1/hz s on a straight line to `to`, mouse up
//   {"do": "wait", "ms": N}
// LOG: {"clock": "mach_absolute_time ns", "start_ns", "steps": [{"do", "events": N, "target_hz"?, "achieved_hz"?}],
//       "events": [[t_ns, type, x, y, key_code]], "rate_floor", "rate_ok": bool, "posted": bool}. A drag's
//       achieved rate is (drag events - 1) / (last - first drag timestamp); a late wake of this process lowers it.
import AppKit
import CoreGraphics
import Foundation

struct Fail: Error { let code: Int32; let message: String }

func machNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

let timebase: mach_timebase_info_data_t = { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info }()

/// Mach ticks to nanoseconds (the same clock as CLOCK_UPTIME_RAW).
func nanoseconds(_ ticks: UInt64) -> UInt64 { ticks / UInt64(timebase.denom) * UInt64(timebase.numer) + ticks % UInt64(timebase.denom) * UInt64(timebase.numer) / UInt64(timebase.denom) }

/// The largest time any script value may name: an hour (larger values would overflow the sleep math).
let maxMilliseconds = 3_600_000.0

/// Sleeps until `deadline` (mach ns): a coarse sleep, then a short spin, so each event leaves within ~50 µs of its time.
func wait(until deadline: UInt64) {
    while true {
        let now = machNow()
        if now >= deadline { return }
        let left = deadline - now
        if left > 2_000_000 { usleep(useconds_t((left - 1_000_000) / 1_000)) }
    }
}

func flags(_ names: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for n in names {
        switch n {
        case "cmd", "command": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "option", "alt": f.insert(.maskAlternate)
        case "control", "ctrl": f.insert(.maskControl)
        default: break
        }
    }
    return f
}

final class Injector {
    let post: Bool
    let source = CGEventSource(stateID: .hidSystemState)
    var events: [[Any]] = []
    init(post: Bool) { self.post = post }

    /// Posts one event at `deadline` with its own timestamp set to the posting moment; logs it.
    func emit(_ make: () -> CGEvent?, at deadline: UInt64, type: String, x: Double = 0, y: Double = 0, key: Int = -1) {
        wait(until: deadline)
        let ticks = mach_absolute_time()
        if post, let event = make() {
            event.timestamp = CGEventTimestamp(ticks)
            event.post(tap: .cghidEventTap)
        }
        events.append([nanoseconds(ticks), type, x, y, key])
    }

    func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, mods: CGEventFlags, clicks: Int64 = 1,
               at deadline: UInt64, name: String) {
        emit({
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
            e?.flags = mods
            e?.setIntegerValueField(.mouseEventClickState, value: clicks)
            return e
        }, at: deadline, type: name, x: p.x, y: p.y)
    }
}

func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

/// A time in ms from the script, refused past ``maxMilliseconds``.
func millis(_ v: Any?, default value: Double) throws -> Double {
    let ms = max(0, number(v) ?? value)
    guard ms <= maxMilliseconds else { throw Fail(code: 2, message: "a time over an hour (\(ms) ms)") }
    return ms
}

func point(_ v: Any?) throws -> CGPoint {
    guard let a = v as? [Any], a.count == 2, let x = number(a[0]), let y = number(a[1]) else {
        throw Fail(code: 2, message: "a point is [x, y]")
    }
    return CGPoint(x: x, y: y)
}

/// Plays the script; returns the per-step summary.
func play(_ script: [String: Any], _ inj: Injector, start: UInt64) throws -> [[String: Any]] {
    guard let steps = script["steps"] as? [[String: Any]], !steps.isEmpty else { throw Fail(code: 2, message: "no steps") }
    var t = start
    var out: [[String: Any]] = []
    for step in steps {
        let kind = step["do"] as? String ?? ""
        let mods = flags(step["modifiers"] as? [String] ?? [])
        let first = inj.events.count
        var summary: [String: Any] = ["do": kind]
        switch kind {
        case "wait":
            t += UInt64(try millis(step["ms"], default: 0) * 1e6)
        case "move":
            let p = CGPoint(x: number(step["x"]) ?? 0, y: number(step["y"]) ?? 0)
            inj.mouse(.mouseMoved, p, mods: mods, at: t, name: "move")
        case "key":
            guard let code = number(step["key_code"]).map({ CGKeyCode($0) }) else { throw Fail(code: 2, message: "key needs key_code") }
            let hold = UInt64(try millis(step["hold_ms"], default: 40) * 1e6)
            inj.emit({ let e = CGEvent(keyboardEventSource: inj.source, virtualKey: code, keyDown: true); e?.flags = mods; return e },
                     at: t, type: "key_down", key: Int(code))
            t += hold
            inj.emit({ let e = CGEvent(keyboardEventSource: inj.source, virtualKey: code, keyDown: false); e?.flags = mods; return e },
                     at: t, type: "key_up", key: Int(code))
        case "click":
            let p = CGPoint(x: number(step["x"]) ?? 0, y: number(step["y"]) ?? 0)
            let hold = UInt64(try millis(step["hold_ms"], default: 40) * 1e6)
            for n in 1...max(1, min(10, Int(number(step["count"]) ?? 1))) {
                inj.mouse(.leftMouseDown, p, mods: mods, clicks: Int64(n), at: t, name: "down")
                t += hold
                inj.mouse(.leftMouseUp, p, mods: mods, clicks: Int64(n), at: t, name: "up")
                t += hold
            }
        case "drag":
            let a = try point(step["from"]), b = try point(step["to"])
            let duration = try millis(step["duration_ms"], default: 0) / 1000
            let hz = max(1, min(1000, number(step["hz"]) ?? 120))
            let hold = UInt64(try millis(step["hold_ms"], default: 60) * 1e6)
            inj.mouse(.mouseMoved, a, mods: mods, at: t, name: "move")
            t += 20_000_000
            inj.mouse(.leftMouseDown, a, mods: mods, at: t, name: "down")
            t += hold
            let count = max(1, Int((duration * hz).rounded()))
            let dragStart = t
            for i in 1...count {
                let f = Double(i) / Double(count)
                let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                inj.mouse(.leftMouseDragged, p, mods: mods, at: dragStart + UInt64(Double(i) * 1e9 / hz), name: "drag")
            }
            t = dragStart + UInt64(Double(count) * 1e9 / hz)
            inj.mouse(.leftMouseUp, b, mods: mods, at: t, name: "up")
            let drags = inj.events[first...].filter { ($0[1] as? String) == "drag" }.compactMap { $0[0] as? UInt64 }
            if drags.count > 1, let lo = drags.first, let hi = drags.last, hi > lo {
                summary["target_hz"] = hz
                summary["achieved_hz"] = Double(drags.count - 1) / (Double(hi - lo) / 1e9)
            }
        default:
            throw Fail(code: 2, message: "unknown step \(kind)")
        }
        summary["events"] = inj.events.count - first
        out.append(summary)
        if t < machNow() { t = machNow() }
    }
    return out
}

/// An event stamped exactly as `run` stamps one must read back through AppKit on the clock of CLOCK_UPTIME_RAW.
func stampCheck() -> Int32 {
    let ticks = mach_absolute_time()
    guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left) else {
        FileHandle.standardError.write(Data("hid_inject: no event to stamp\n".utf8))
        return 5
    }
    event.timestamp = CGEventTimestamp(ticks)
    let expected = Double(nanoseconds(ticks)) / 1e9
    let read = NSEvent(cgEvent: event)?.timestamp ?? -1
    let off = abs(read - expected)
    print("stampcheck: NSEvent.timestamp \(read) s, CLOCK_UPTIME_RAW \(expected) s, off \(off * 1000) ms")
    return off < 0.005 ? 0 : 5
}

func main() -> Int32 {
    let args = CommandLine.arguments
    if args.count == 2, args[1] == "stampcheck" { return stampCheck() }
    guard args.count == 4, ["run", "plan"].contains(args[1]) else {
        FileHandle.standardError.write(Data("usage: hid_inject run|plan SCRIPT.json LOG.json\n".utf8))
        return 2
    }
    let post = args[1] == "run"
    do {
        guard let data = FileManager.default.contents(atPath: args[2]),
              let script = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Fail(code: 2, message: "cannot read \(args[2])")
        }
        if post && !CGPreflightPostEventAccess() {
            throw Fail(code: 3, message: "no PostEvent (Accessibility) grant for this process: NOT RUN")
        }
        let inj = Injector(post: post)
        let start = machNow() + UInt64(try millis(script["start_delay_ms"], default: 200) * 1e6)
        let steps = try play(script, inj, start: start)
        let floor = number(script["rate_floor"]) ?? 0.95
        let rateOK = steps.allSatisfy { s in
            guard let target = s["target_hz"] as? Double, let got = s["achieved_hz"] as? Double else { return true }
            return got >= floor * target
        }
        let log: [String: Any] = ["clock": "mach_absolute_time ns (CLOCK_UPTIME_RAW)", "start_ns": start, "posted": post,
                                  "rate_floor": floor, "rate_ok": rateOK, "steps": steps, "events": inj.events]
        try JSONSerialization.data(withJSONObject: log).write(to: URL(fileURLWithPath: args[3]))
        return rateOK ? 0 : 4
    } catch let fail as Fail {
        FileHandle.standardError.write(Data("hid_inject: \(fail.message)\n".utf8))
        return fail.code
    } catch {
        FileHandle.standardError.write(Data("hid_inject: \(error)\n".utf8))
        return 2
    }
}

exit(main())
