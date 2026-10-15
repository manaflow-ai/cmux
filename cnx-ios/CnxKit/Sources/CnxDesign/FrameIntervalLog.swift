import Foundation

/// Frame-interval statistics (G-04): the gaps between display frames while
/// something moves, as percentiles and hitch counts. Pure value code so the
/// math is testable on macOS; the iOS recorder below feeds it.
public struct FrameIntervalStats: Codable, Hashable, Sendable {
    public var label: String
    /// Frames counted (intervals, not timestamps).
    public var frames: Int
    /// The display's nominal frame interval (ms), from the link's target.
    public var expectedMs: Double
    public var p50Ms: Double
    public var p90Ms: Double
    public var p95Ms: Double
    public var p99Ms: Double
    public var maxMs: Double
    /// Intervals longer than 1.5 frames: at least one frame was dropped.
    public var hitches: Int
    /// Frames the display skipped in all (each interval of n frames skips n - 1).
    public var droppedFrames: Int
    /// Time spent late per second of motion (ms/s), Apple's hitch time ratio.
    public var hitchMsPerSecond: Double
    public var durationSeconds: Double
    /// Every interval (ms, in order), so windows can be pooled later.
    public var intervalsMs: [Double]?

    /// Summarizes `intervals` (seconds). `expected` is the nominal frame interval (seconds).
    public init(label: String, intervals: [Double], expected: Double) {
        self.label = label
        let raw = intervals.map { ($0 * 100_000).rounded() / 100 }
        intervalsMs = raw
        let ms = raw.sorted()
        let expectedMs = expected * 1000
        func percentile(_ p: Double) -> Double {
            guard !ms.isEmpty else { return 0 }
            let rank = min(ms.count - 1, max(0, Int((p * Double(ms.count)).rounded(.up)) - 1))
            return ms[rank]
        }
        frames = ms.count
        self.expectedMs = expectedMs
        p50Ms = percentile(0.50)
        p90Ms = percentile(0.90)
        p95Ms = percentile(0.95)
        p99Ms = percentile(0.99)
        maxMs = ms.last ?? 0
        var hitches = 0
        var dropped = 0
        var late = 0.0
        if expectedMs > 0 {
            for value in ms where value > expectedMs * 1.5 {
                hitches += 1
                dropped += max(1, Int((value / expectedMs).rounded()) - 1)
                late += value - expectedMs
            }
        }
        self.hitches = hitches
        droppedFrames = dropped
        let duration = ms.reduce(0, +) / 1000
        durationSeconds = duration
        hitchMsPerSecond = duration > 0 ? late / duration : 0
    }

    /// One line for logs: `label frames=N p50=.. p95=.. p99=.. max=.. hitches=N dropped=N hitch=Xms/s`.
    public var line: String {
        func f(_ value: Double) -> String { String(format: "%.1f", value) }
        return "\(label) frames=\(frames) expected=\(f(expectedMs))ms p50=\(f(p50Ms)) p90=\(f(p90Ms)) p95=\(f(p95Ms)) "
            + "p99=\(f(p99Ms)) max=\(f(maxMs)) hitches=\(hitches) dropped=\(droppedFrames) hitch=\(f(hitchMsPerSecond))ms/s "
            + "dur=\(f(durationSeconds))s"
    }
}

#if os(iOS)
import OSLog
import QuartzCore

/// G-04: an in-app CADisplayLink frame-interval recorder with signposts, for
/// timing claims that do not depend on screen-recording timing (laptop load
/// makes recordings unreliable). DEBUG and Demo builds turn it on with the
/// `CNX_FRAMELOG=1` environment variable (`SIMCTL_CHILD_CNX_FRAMELOG=1`); it
/// costs nothing when off. Each `begin`/`end` pair is one window: the
/// summary goes to the `dev.cmux.cnx` `frames` log (`FRAMELOG <line>`) and, as
/// JSON lines, to `Library/Caches/framelog.jsonl` in the app container.
/// Each frame is also an `OSSignposter` event (`frame`, with its interval),
/// and each window an interval (`window`), for Instruments.
@MainActor
public final class FrameIntervalLog {
    public static let shared = FrameIntervalLog()

    /// Whether recording is on for this process.
    public let isEnabled: Bool
    private let log = Logger(subsystem: "dev.cmux.cnx", category: "frames")
    private let signposter = OSSignposter(subsystem: "dev.cmux.cnx", category: "frames")
    private var link: CADisplayLink?
    private var label: String?
    private var lastTimestamp: CFTimeInterval?
    private var intervals: [Double] = []
    private var expected: Double = 1.0 / 60
    private var window: OSSignpostIntervalState?
    /// Called with every finished window (tests and drivers).
    public var onSummary: ((FrameIntervalStats) -> Void)?

    public init(enabled: Bool? = nil) {
        #if DEBUG
        isEnabled = enabled ?? (ProcessInfo.processInfo.environment["CNX_FRAMELOG"] == "1")
        #else
        isEnabled = enabled ?? false
        #endif
    }

    /// Starts a window named `label` (ends the current one first).
    public func begin(_ label: String) {
        guard isEnabled else { return }
        if self.label != nil { end() }
        self.label = label
        intervals = []
        intervals.reserveCapacity(4096)
        lastTimestamp = nil
        window = signposter.beginInterval("window", "\(label, privacy: .public)")
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Ends the window and returns its summary (nil when none was open).
    @discardableResult
    public func end() -> FrameIntervalStats? {
        guard isEnabled, let label else { return nil }
        link?.invalidate()
        link = nil
        self.label = nil
        if let window { signposter.endInterval("window", window) }
        window = nil
        let stats = FrameIntervalStats(label: label, intervals: intervals, expected: expected)
        log.notice("FRAMELOG \(stats.line, privacy: .public)")
        Self.append(stats)
        onSummary?(stats)
        return stats
    }

    fileprivate func tick(_ link: CADisplayLink) {
        // The nominal interval: what the display promised for this frame.
        let nominal = link.targetTimestamp - link.timestamp
        if nominal > 0.001 { expected = nominal }
        if let lastTimestamp {
            let interval = link.timestamp - lastTimestamp
            intervals.append(interval)
            signposter.emitEvent("frame", "\(interval * 1000, format: .fixed(precision: 2), privacy: .public)")
        }
        lastTimestamp = link.timestamp
    }

    /// JSON lines next to the app's caches, read back with `simctl get_app_container`.
    public static var fileURL: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appending(path: "framelog.jsonl")
    }

    private static func append(_ stats: FrameIntervalStats) {
        guard var data = try? JSONEncoder().encode(stats) else { return }
        data.append(0x0A)
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Breaks the display link's retain of its target.
    @MainActor
    private final class Proxy: NSObject {
        weak var owner: FrameIntervalLog?
        init(_ owner: FrameIntervalLog) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
}
#endif
