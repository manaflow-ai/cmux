// Fidelity cross check (plans/cmux-next/ghostty-next.md section 12): feed each
// corpus case through a GhosttyNextKit MANUAL_MIRROR surface with the session
// host's grid and scrollback, encode READY and COMPLETE with
// ghostty_surface_encode_snapshot, and compare them with the session host's
// libghostty-vt snapshots (ghostty-vt tests/terminal_corpus.rs output).
//
// Usage: crosscheck <corpus dir> <host snapshot dir> <out dir> <ghostty config file>
import AppKit
import GhosttyNextKit

let args = CommandLine.arguments
guard args.count == 5 else {
    print("usage: crosscheck <corpus dir> <host dir> <out dir> <config file>")
    exit(2)
}
let corpus = URL(fileURLWithPath: args[1])
let hostDir = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
let configPath = args[4]

struct Case: Decodable { let name: String; let file: String; let cols: UInt16; let rows: UInt16; let features: [String] }
struct Manifest: Decodable { let cases: [Case] }

final class Sink: @unchecked Sendable { var bytes: [UInt8] = [] }
struct SurfaceRef: @unchecked Sendable { let raw: ghostty_surface_t }
nonisolated(unsafe) var app: ghostty_app_t?
let outputQueue = DispatchQueue(label: "crosscheck.output")

func encode(_ surface: ghostty_surface_t, _ phase: ghostty_surface_snapshot_phase_e) -> [UInt8]? {
    let sink = Sink()
    let ok = ghostty_surface_encode_snapshot(surface, { userdata, bytes, len in
        let sink = Unmanaged<Sink>.fromOpaque(userdata!).takeUnretainedValue()
        sink.bytes.append(contentsOf: UnsafeBufferPointer(start: bytes, count: Int(len)))
    }, Unmanaged.passUnretained(sink).toOpaque(), phase)
    return ok ? sink.bytes : nil
}

/// Records of a snapshot: (tag, bytes) after the 10-byte envelope.
func records(_ data: [UInt8]) -> [(UInt16, ArraySlice<UInt8>)] {
    var out: [(UInt16, ArraySlice<UInt8>)] = []
    var at = 10
    while at + 10 <= data.count {
        let tag = UInt16(data[at]) | UInt16(data[at + 1]) << 8
        let len = Int(data[at + 2]) | Int(data[at + 3]) << 8 | Int(data[at + 4]) << 16 | Int(data[at + 5]) << 24
        guard at + 10 + len <= data.count else { break }
        out.append((tag, data[at..<(at + 10 + len)]))
        at += 10 + len
    }
    return out
}

let tagNames: [UInt16: String] = [1: "TERMINAL", 2: "SCREEN", 3: "PAGE", 4: "HISTORY", 5: "READY", 6: "FINISH", 7: "CONTINUATION"]

func compare(_ label: String, _ phone: [UInt8], _ host: [UInt8]) -> String {
    if phone == host { return "\(label) equal (\(host.count) B)" }
    let a = records(phone), b = records(host)
    var diffs: [String] = []
    if Array(phone.prefix(10)) != Array(host.prefix(10)) { diffs.append("envelope") }
    for i in 0..<max(a.count, b.count) {
        let left = i < a.count ? a[i] : nil, right = i < b.count ? b[i] : nil
        if left?.0 != right?.0 || left.map({ Array($0.1) }) != right.map({ Array($0.1) }) {
            let name = tagNames[right?.0 ?? left?.0 ?? 0] ?? "?"
            diffs.append("\(name)#\(i)")
        }
    }
    return "\(label) DIFFERS phone \(phone.count) B host \(host.count) B records \(diffs.prefix(8).joined(separator: ","))"
}

@MainActor
func run() {
    let manifest = try! JSONDecoder().decode(Manifest.self, from: Data(contentsOf: corpus.appendingPathComponent("manifest.json")))
    print("snapshot version phone=\(ghostty_surface_snapshot_version())")
    var allEqual = true
    for c in manifest.cases {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200))
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = 1
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.io_write_cb = { _, _, _ in }
        guard let raw = ghostty_surface_new(app, &config) else { print("\(c.name): surface_new failed"); exit(1) }
        let surface = SurfaceRef(raw: raw)
        let bytes = try! Data(contentsOf: corpus.appendingPathComponent(c.file))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ready: [UInt8]? = nil
        nonisolated(unsafe) var complete: [UInt8]? = nil
        let cols = c.cols, rows = c.rows
        outputQueue.async {
            _ = ghostty_surface_set_grid(surface.raw, cols, rows, 1)
            bytes.withUnsafeBytes { buf in
                ghostty_surface_process_output(surface.raw, buf.baseAddress!.assumingMemoryBound(to: CChar.self), UInt(buf.count))
            }
            ready = encode(surface.raw, GHOSTTY_SURFACE_SNAPSHOT_READY)
            complete = encode(surface.raw, GHOSTTY_SURFACE_SNAPSHOT_COMPLETE)
            done.signal()
        }
        // Keep the main thread free for the app mailbox while the queue works.
        while done.wait(timeout: .now()) == .timedOut {
            ghostty_app_tick(app)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard let ready, let complete else { print("\(c.name): encode failed"); exit(1) }
        try! Data(ready).write(to: outDir.appendingPathComponent("\(c.name).ready.ghostsnp"))
        try! Data(complete).write(to: outDir.appendingPathComponent("\(c.name).complete.ghostsnp"))
        let hostReady = try! [UInt8](Data(contentsOf: hostDir.appendingPathComponent("\(c.name).ready.ghostsnp")))
        let hostComplete = try! [UInt8](Data(contentsOf: hostDir.appendingPathComponent("\(c.name).complete.ghostsnp")))
        let excluded = c.features.contains { $0.contains("excluded") }
        let r = compare("READY", ready, hostReady), k = compare("COMPLETE", complete, hostComplete)
        if (ready != hostReady || complete != hostComplete) && !excluded { allEqual = false }
        print("case \(c.name)\(excluded ? " (excluded feature)" : ""): \(r); \(k)")
        ghostty_surface_free(raw)
    }
    print(allEqual ? "CROSSCHECK PASS" : "CROSSCHECK FAIL")
    exit(allEqual ? 0 : 1)
}

guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
      let config = ghostty_config_new() else { print("ghostty_init failed"); exit(1) }
configPath.withCString { ghostty_config_load_file(config, $0) }
ghostty_config_finalize(config)
var runtime = ghostty_runtime_config_s()
runtime.wakeup_cb = { _ in }
runtime.action_cb = { _, _, _ in false }
runtime.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
runtime.write_clipboard_cb = { _, _, _, _, _ in }
runtime.close_surface_cb = { _, _ in }
guard let created = ghostty_app_new(&runtime, config) else { print("ghostty_app_new failed"); exit(1) }
app = created
MainActor.assumeIsolated { run() }
