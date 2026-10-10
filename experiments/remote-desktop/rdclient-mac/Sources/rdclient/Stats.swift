import Darwin
import Foundation

/// Monotonic clock in nanoseconds (CLOCK_UPTIME_RAW, the clock VideoToolbox and mach use).
@inline(__always)
func nowNs() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

@inline(__always)
func ms(_ a: UInt64, _ b: UInt64) -> Double {
    b >= a ? Double(b - a) / 1e6 : -Double(a - b) / 1e6
}

/// Nearest-rank percentiles over a sample list, emitted as a JSON object.
func percentiles(_ xs: [Double]) -> [String: Any] {
    guard !xs.isEmpty else { return ["n": 0] }
    let s = xs.sorted()
    func q(_ p: Double) -> Double {
        let idx = Int((p / 100 * Double(s.count - 1)).rounded())
        return s[min(max(idx, 0), s.count - 1)]
    }
    let mean = s.reduce(0, +) / Double(s.count)
    return [
        "n": s.count,
        "min": round3(s[0]), "p50": round3(q(50)), "p95": round3(q(95)),
        "p99": round3(q(99)), "max": round3(s[s.count - 1]), "mean": round3(mean),
    ]
}

func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[s.count / 2]
}

/// Process CPU time (user + system) from getrusage.
struct CPUTimes {
    let user: Double
    let sys: Double
    let wallNs: UInt64

    static func now() -> CPUTimes {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return CPUTimes(user: secs(ru.ru_utime), sys: secs(ru.ru_stime), wallNs: nowNs())
    }

    func delta(to end: CPUTimes) -> [String: Any] {
        let wall = Double(end.wallNs - wallNs) / 1e9
        let u = end.user - user
        let s = end.sys - sys
        return [
            "user_s": round3(u), "sys_s": round3(s), "wall_s": round3(wall),
            "cpu_pct_one_core": wall > 0 ? round3((u + s) / wall * 100) : 0,
        ]
    }
}

/// Facts about the machine this process runs on.
func machineInfo() -> [String: Any] {
    func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return [
        "host": ProcessInfo.processInfo.hostName,
        "chip": sysctlString("machdep.cpu.brand_string"),
        "model": sysctlString("hw.model"),
        "cores": ProcessInfo.processInfo.activeProcessorCount,
        "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        "load_avg_1m": loadAvg1(),
    ]
}

func loadAvg1() -> Double {
    var l = [Double](repeating: 0, count: 3)
    return getloadavg(&l, 3) > 0 ? round3(l[0]) : -1
}

func utcNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

func emitJSON(_ obj: [String: Any], to path: String?) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    if let path {
        try data.write(to: URL(fileURLWithPath: path))
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("[rdclient] \(s)\n".utf8))
}

/// JSON-friendly optional: the value, or NSNull when absent.
func orNull<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
