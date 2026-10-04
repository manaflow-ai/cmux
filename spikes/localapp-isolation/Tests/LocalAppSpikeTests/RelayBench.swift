import Darwin
import Foundation
@testable import LocalAppSpike
import Testing
import WebKit

/// Frame latency per transport mode (runs only with LOCALAPP_SPIKE_BENCH=1; scripts/measure/
/// localapp-isolation.sh sets it on an exclusive fleet worker).
///
/// Each frame is ~300 bytes of `session/update` JSON. The page parses each frame (as direct.ts
/// does) and acknowledges it at once through its transport; the server times send to ack on one
/// clock. So a mode's latency includes the inbound AND the outbound leg: the overhead of B over
/// direct is the round-trip relay cost, an upper bound for the one-way streaming cost.
/// - seq: 300 frames one at a time (idle latency).
/// - burst: 2,000 frames sent back to back (streaming burst); total = first send to last ack.
/// Main-thread CPU is the thread-CPU time of the host's main thread across the burst.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALAPP_SPIKE_BENCH"] == "1"))
struct RelayBench {
    static let rounds = Int(ProcessInfo.processInfo.environment["LOCALAPP_SPIKE_ROUNDS"] ?? "") ?? 5
    static let burst = 2000
    static let sequential = 300

    struct Samples {
        var seq: [UInt64] = []
        var burst: [UInt64] = []
        var paced: [UInt64] = []
        var totals: [UInt64] = []
        var mainCPU: [UInt64] = []
        var mainWall: [UInt64] = []
        var relay: [RelayStats] = []
    }

    static func pct(_ values: [UInt64], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return Double(sorted[index]) / 1e6
    }

    @Test func framesThroughEachMode() async throws {
        let server = SpikeServer()
        try await server.start()
        defer { server.stop() }
        let token = String(repeating: "cd34", count: 16)
        var pages: [BenchPage.Mode: BenchPage] = [:]
        for mode in BenchPage.Mode.allCases {
            let page = BenchPage(mode: mode, spy: false)
            await page.load()
            try await page.connect(server.url, token: token)
            _ = await server.stream(to: mode.rawValue, count: 500, window: 500) // warm up
            pages[mode] = page
        }
        defer { pages.values.forEach { $0.close() } }
        var samples: [BenchPage.Mode: Samples] = [:]
        let modes = BenchPage.Mode.allCases
        for round in 0..<Self.rounds {
            for offset in 0..<modes.count {
                let mode = modes[(round + offset) % modes.count]
                let page = pages[mode]!
                var sample = samples[mode] ?? Samples()
                let sequential = await server.stream(to: mode.rawValue, count: Self.sequential, window: 1)
                sample.seq += sequential.latencies
                // 2,000 frames at 2,000 frames/s (one every 0.5 ms): heavy but real streaming.
                let paced = await server.stream(to: mode.rawValue, count: Self.burst, window: Self.burst, interval: 500_000)
                sample.paced += paced.latencies
                page.relay?.resetStats()
                let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let result = await server.stream(to: mode.rawValue, count: Self.burst, window: Self.burst)
                sample.mainCPU.append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu0)
                sample.burst += result.latencies
                sample.totals.append(result.total)
                if let stats = page.relay?.stats { sample.relay.append(stats); sample.mainWall.append(stats.mainWallNanos) }
                samples[mode] = sample
            }
        }
        var report: [[String: Any]] = []
        let direct = samples[.direct]!
        for mode in modes {
            let s = samples[mode]!
            var row: [String: Any] = [
                "engine": "webkit", "mode": mode.rawValue, "rounds": Self.rounds,
                "suppressionOff": pages[mode]!.suppressionOff,
                "seq_p50_ms": Self.pct(s.seq, 0.5), "seq_p95_ms": Self.pct(s.seq, 0.95), "seq_p99_ms": Self.pct(s.seq, 0.99),
                "burst_p50_ms": Self.pct(s.burst, 0.5), "burst_p95_ms": Self.pct(s.burst, 0.95), "burst_p99_ms": Self.pct(s.burst, 0.99),
                "paced_p50_ms": Self.pct(s.paced, 0.5), "paced_p95_ms": Self.pct(s.paced, 0.95), "paced_p99_ms": Self.pct(s.paced, 0.99),
                "paced_overhead_p50_ms": Self.pct(s.paced, 0.5) - Self.pct(direct.paced, 0.5),
                "paced_overhead_p95_ms": Self.pct(s.paced, 0.95) - Self.pct(direct.paced, 0.95),
                "paced_overhead_p99_ms": Self.pct(s.paced, 0.99) - Self.pct(direct.paced, 0.99),
                "burst_overhead_p50_ms": Self.pct(s.burst, 0.5) - Self.pct(direct.burst, 0.5),
                "burst_overhead_p95_ms": Self.pct(s.burst, 0.95) - Self.pct(direct.burst, 0.95),
                "burst_overhead_p99_ms": Self.pct(s.burst, 0.99) - Self.pct(direct.burst, 0.99),
                "burst_total_median_ms": Self.pct(s.totals, 0.5), "burst_total_max_ms": Self.pct(s.totals, 1),
                "main_cpu_median_ms": Self.pct(s.mainCPU, 0.5), "main_cpu_max_ms": Self.pct(s.mainCPU, 1),
                "seq_overhead_p50_ms": Self.pct(s.seq, 0.5) - Self.pct(direct.seq, 0.5),
                "seq_overhead_p95_ms": Self.pct(s.seq, 0.95) - Self.pct(direct.seq, 0.95),
                "seq_overhead_p99_ms": Self.pct(s.seq, 0.99) - Self.pct(direct.seq, 0.99),
                "burst_total_overhead_ms": Self.pct(s.totals, 0.5) - Self.pct(direct.totals, 0.5),
            ]
            if !s.relay.isEmpty {
                let flushes = s.relay.map(\.flushes).reduce(0, +)
                let frames = s.relay.map(\.inboundFrames).reduce(0, +)
                row["relay_frames_per_flush"] = flushes == 0 ? 0 : Double(frames) / Double(flushes)
                row["relay_main_wall_median_ms"] = Self.pct(s.mainWall, 0.5)
                row["relay_longest_main_call_ms"] = Double(s.relay.map(\.longestMainCallNanos).max() ?? 0) / 1e6
                let delays = s.relay.flatMap(\.queueDelayNanos)
                row["relay_queue_delay_p50_ms"] = Self.pct(delays, 0.5)
                row["relay_queue_delay_p95_ms"] = Self.pct(delays, 0.95)
                row["relay_queue_delay_p99_ms"] = Self.pct(delays, 0.99)
            }
            report.append(row)
            let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print("SPIKE-BENCH " + String(decoding: json, as: UTF8.self))
        }
        if let path = ProcessInfo.processInfo.environment["LOCALAPP_SPIKE_OUT"] {
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            try json.write(to: URL(fileURLWithPath: path + "/webkit-bench.json"))
        }
    }
}
