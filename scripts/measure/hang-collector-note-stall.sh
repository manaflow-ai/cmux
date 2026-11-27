#!/usr/bin/env bash
# The main thread's cost of HangReportCollector.noteStall on its sampled path, the one that hung 2.0 s at a stall's
# end (hq#18810, the HangReportCollector bucket in field_hangs): per call p50/p99/p99.9/max over 5000 calls, idle
# and under duress (one `yes` per core plus 2 spinning threads per core in the test process). Each call goes to a
# fresh collector, so each one starts a resolution job: a detached Task before #58752, a dispatch-source signal
# after. The collector source is taken from each SHA given and the same bench runs against it, in one harness on
# one machine, so a before and an after compare.
#
#   cmux-ci run --class exclusive --os macos --measurement --script scripts/measure/hang-collector-note-stall.sh --ref SHA --arg=BEFORE_SHA --arg=AFTER_SHA
#
# Prints "BENCH-AT <sha>" then `BENCH idle|duress n=… p50=…ns p99=…ns p999=…ns max=…ns` per SHA, and the load average.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
pkg=Packages/macOS/CmuxNext
src=$pkg/Sources/CmuxNextHangReports/HangReportCollector.swift
bench=$pkg/Tests/CmuxNextHangReportsTests/NoteStallBench.swift
[ $# -ge 1 ] || { echo "usage: $0 SHA..." >&2; exit 2; }
cleanup() { git checkout -q HEAD -- "$src"; rm -f "$bench"; [ -n "${yes_pids:-}" ] && kill $yes_pids 2>/dev/null; }
trap cleanup EXIT
cat > "$bench" <<'SWIFT'
import Foundation
import Testing
@testable import CmuxNextHangReports

/// Main-thread cost of noteStall's sampled path (hq#18810), idle and under CPU duress.
struct NoteStallBench {
    static func ns() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func run(_ label: String, iterations: Int) -> String {
        var times: [UInt64] = []
        times.reserveCapacity(iterations)
        var keep: [HangReportCollector] = []
        keep.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let c = HangReportCollector(resolve: { _ in [.other] })
            c.setEnabled(true)
            keep.append(c)
            let t0 = ns()
            c.noteStall(durationNanos: 500_000_000, cpuNanos: 0, addresses: [1, 2, 3])
            times.append(ns() &- t0)
        }
        times.sort()
        func p(_ q: Double) -> UInt64 { times[min(times.count - 1, Int(Double(times.count) * q))] }
        return "BENCH \(label) n=\(iterations) p50=\(p(0.5))ns p99=\(p(0.99))ns p999=\(p(0.999))ns max=\(times.last!)ns"
    }

    @Test func noteStallMainThreadCost() async throws {
        guard ProcessInfo.processInfo.environment["NOTE_STALL_BENCH"] == "1" else { return }
        _ = Self.run("warmup", iterations: 500)
        print(Self.run("idle", iterations: 5000))
        let spinners = ProcessInfo.processInfo.activeProcessorCount * 2
        let stop = ManagedAtomicFlag()
        for _ in 0..<spinners {
            Thread.detachNewThread { var x = 0; while !stop.isSet { x &+= 1 } ; _ = x }
        }
        try await Task.sleep(for: .milliseconds(200))
        print(Self.run("duress", iterations: 5000))
        stop.set()
    }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
SWIFT
ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
echo "host: $(uname -sm) ncpu=$ncpu"
(cd $pkg && swift build -c release --build-tests >/dev/null 2>&1) || true
for sha in "$@"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch -q origin "$sha"
  git show "$sha:$src" > "$src" || { echo "no $src at $sha" >&2; exit 1; }
  echo "BENCH-AT $(git rev-parse --short "$sha")"
  yes_pids=""
  for _ in $(seq "$ncpu"); do yes >/dev/null & yes_pids="$yes_pids $!"; done
  (cd $pkg && NOTE_STALL_BENCH=1 swift test -c release --filter NoteStallBench 2>&1) | grep -E '^BENCH|error:|failed' | head -20
  echo "load: $(uptime | sed 's/.*load average[s]*: //')"
  kill $yes_pids 2>/dev/null; wait $yes_pids 2>/dev/null; yes_pids=""
done
