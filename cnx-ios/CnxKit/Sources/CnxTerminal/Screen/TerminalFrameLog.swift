#if os(iOS) && DEBUG
import Foundation
import os
import QuartzCore

/// DEBUG/Demo only (G-04, ACCEPTANCE M-FRAMELOG). Launch with `-CnxFrameLog`:
/// a display link records every frame's interval (actual timestamp minus the
/// previous one) with the page's phase, whether output streamed in the last
/// 100 ms, and the main-thread time the screen spent in the frame. Each
/// gesture (or 5 s of other frames) logs a summary on `dev.cmux.cnx:frames`
/// and appends ndjson lines to `Documents/frame-log.ndjson`, which the rig
/// copies out with `simctl get_app_container`. The terminal's work is also
/// marked with signposts (`output-batch`, `update-document`, `apply-scroll`,
/// `present`) for Instruments.
@MainActor
final class TerminalFrameLog {
    static let isEnabled = CommandLine.arguments.contains("-CnxFrameLog")
    static let signposter = OSSignposter(subsystem: "dev.cmux.cnx", category: "terminal-frames")
    private static let logger = Logger(subsystem: "dev.cmux.cnx", category: "frames")

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var stats: TerminalFrameStats
    private var phase = "following"
    private var lastOutput: CFTimeInterval = 0
    private var workMs = 0.0
    private var windowStart: CFTimeInterval = 0
    private var lines: [String] = []
    private let surfaceName: String

    init(surfaceName: String, frameDuration: Double) {
        self.surfaceName = surfaceName
        stats = TerminalFrameStats(frameDuration: frameDuration)
    }

    func start() {
        guard Self.isEnabled, link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, selector: #selector(DisplayLinkProxy.step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        last = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
        flush(reason: "stop")
    }

    /// The page's phase, read every frame (interacting, following, reading).
    var phaseProvider: () -> String = { "following" }

    func outputArrived() { lastOutput = CACurrentMediaTime() }

    /// Main-thread work done for the screen in this frame.
    func work(_ seconds: CFTimeInterval) { workMs += seconds * 1000 }

    private func tick() {
        guard let link else { return }
        let now = link.timestamp
        defer { last = now; workMs = 0 }
        guard last > 0 else { windowStart = now; return }
        let current = phaseProvider()
        if current != phase {
            if phase == "interacting" { flush(reason: "gesture end") }
            phase = current
        }
        let interval = now - last
        let streaming = now - lastOutput < 0.1
        let key = TerminalFrameStats.Key(phase: phase, streaming: streaming)
        stats.add(key, interval: interval, workMs: workMs)
        lines.append(String(format: "{\"t\":%.4f,\"dt_ms\":%.2f,\"target_ms\":%.2f,\"phase\":\"%@\",\"streaming\":%@,\"work_ms\":%.2f,\"surface\":\"%@\"}",
                            Date().timeIntervalSince1970, interval * 1000, (link.targetTimestamp - now) * 1000, phase,
                            streaming ? "true" : "false", workMs, surfaceName))
        if phase != "interacting", now - windowStart > 5 { flush(reason: "5 s") }
    }

    private func flush(reason: String) {
        windowStart = last
        let report = stats.report
        if !report.isEmpty {
            for line in report.split(separator: "\n") {
                Self.logger.notice("frames \(self.surfaceName, privacy: .public) (\(reason, privacy: .public)): \(line, privacy: .public)")
            }
        }
        stats = TerminalFrameStats(frameDuration: stats.frameDuration)
        guard !lines.isEmpty, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        lines.removeAll(keepingCapacity: true)
        let url = documents.appendingPathComponent("frame-log.ndjson")
        DispatchQueue.global(qos: .utility).async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
#endif
