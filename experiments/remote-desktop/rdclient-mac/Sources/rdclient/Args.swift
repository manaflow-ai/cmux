/// Minimal `--key value` argument parser.
struct Args {
    let command: String
    private var values: [String: String] = [:]

    init(_ argv: [String]) throws {
        guard argv.count >= 2 else { throw UsageError.message(Args.usage) }
        command = argv[1]
        var i = 2
        while i < argv.count {
            let key = argv[i]
            guard key.hasPrefix("--") else { throw UsageError.message("unexpected argument \(key)") }
            let name = String(key.dropFirst(2))
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                values[name] = argv[i + 1]
                i += 2
            } else {
                values[name] = "true"
                i += 1
            }
        }
    }

    func string(_ name: String) -> String? { values[name] }
    func string(_ name: String, default d: String) -> String { values[name] ?? d }

    func int(_ name: String, default d: Int) throws -> Int {
        guard let v = values[name] else { return d }
        guard let n = Int(v) else { throw UsageError.message("--\(name) needs an integer, got \(v)") }
        return n
    }

    func flag(_ name: String) -> Bool { values[name] == "true" }

    static let usage = """
    usage:
      rdclient connect --addr HOST:7400 [--socks-unix PATH] --workload marker|text|motion|idle
                       --capture damage|poll [--samples 300] [--width 1920] [--height 1080]
                       [--max-fps 60] [--bitrate-kbps 8000] [--pixfmt 420v|420f] [--keycode 38]
                       [--pings 100] [--idle-seconds 30] [--label NAME] [--out FILE.json]
      rdclient selftest [--width 1920] [--height 1080] [--frames 600] [--bitrate-kbps 8000]
                        [--codecs h264,hevc,av1] [--workloads marker,text,motion] [--out FILE.json]
      rdclient fakehost [--port 7400]   (loopback test host: marker workload, damage mode, H.264)
    """
}

enum UsageError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let m): return m
        }
    }
}
