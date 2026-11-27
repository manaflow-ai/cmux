import Darwin
import Foundation

/// Retained allocator blocks/bytes and CPU time at a fixed fixture boundary.
struct ProcessSnapshotMeasurement {
    let instant = ContinuousClock.now
    let cpuSeconds: Double
    let blocks: UInt64
    let bytes: UInt64

    init() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        cpuSeconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        blocks = UInt64(statistics.blocks_in_use)
        bytes = UInt64(statistics.size_in_use)
    }

    func report(_ phase: String, since start: Self) {
        print("PROCESS_SNAPSHOT_FIXTURE phase=\(phase) wall=\(start.instant.duration(to: instant)) cpu_seconds=\(cpuSeconds - start.cpuSeconds) retained_blocks_delta=\(Int64(blocks) - Int64(start.blocks)) retained_bytes_delta=\(Int64(bytes) - Int64(start.bytes))")
    }
}
