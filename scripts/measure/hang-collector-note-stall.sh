#!/usr/bin/env bash
# The main thread's cost of HangReportCollector.noteStall on its sampled path, the one that hung 2.0 s at a stall's
# end (hq#18810, the HangReportCollector bucket in field_hangs): per call p50/p99/p99.9/max over 6000 calls, baseline
# and under duress (2 spinning threads per core in the test process). Each call goes to a
# fresh collector, so each one starts a resolution job: a detached Task before #58752, a dispatch-source signal
# after. The collector source is taken from each SHA given and the same bench runs against it, in one harness on
# one machine, so a before and an after compare.
#
#   cmux-ci run --class exclusive --os macos --measurement --script scripts/measure/hang-collector-note-stall.sh --ref SHA --arg=BEFORE_SHA --arg=AFTER_SHA
#
# Prints "BENCH-AT <sha>" then `BENCH baseline|duress n=… p50=…ns p99=…ns p999=…ns max=…ns` per SHA, and the load average.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pkg=Packages/macOS/CmuxNext
src=$pkg/Sources/CmuxNextHangReports/HangReportCollector.swift
bench=$pkg/Tests/CmuxNextHangReportsTests/NoteStallBench.swift
[ $# -ge 1 ] || { echo "usage: $0 SHA..." >&2; exit 2; }
[ ! -e "$bench" ] || { echo "refusing to overwrite $bench" >&2; exit 2; }
git diff --quiet -- "$src" || { echo "refusing to overwrite modified $src" >&2; exit 2; }
cleanup() { git checkout -q HEAD -- "$src"; rm -f "$bench"; }
trap cleanup EXIT
cat > "$bench" <<'SWIFT'
import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextHangReports

/// Main-thread cost of noteStall's sampled path (hq#18810), baseline and under CPU duress.
struct NoteStallBench {
    static func ns() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    @MainActor static func run(_ label: String, iterations: Int) -> String {
        #expect(Thread.isMainThread)
        var times: [UInt64] = []
        times.reserveCapacity(iterations)
        var keep: [HangReportCollector] = []
        keep.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let c = HangReportCollector(resolve: { _ in
                #expect(!Thread.isMainThread)
                return [.other]
            })
            c.setEnabled(true)
            keep.append(c)
            let t0 = ns()
            c.noteStall(durationNanos: 500_000_000, cpuNanos: 0, addresses: [1, 2, 3])
            times.append(ns() &- t0)
        }
        withExtendedLifetime(keep) {}
        times.sort()
        func p(_ q: Double) -> UInt64 { times[min(times.count - 1, Int(Double(times.count) * q))] }
        return "BENCH \(label) n=\(iterations) p50=\(p(0.5))ns p99=\(p(0.99))ns p999=\(p(0.999))ns max=\(times.last!)ns"
    }

    @Test func noteStallMainThreadCost() async throws {
        guard ProcessInfo.processInfo.environment["NOTE_STALL_BENCH"] == "1" else { return }
        _ = await Self.run("warmup", iterations: 500)
        print(await Self.run("baseline", iterations: 6000))
        let spinners = ProcessInfo.processInfo.activeProcessorCount * 2
        let stop = StopFlag()
        let group = DispatchGroup()
        for _ in 0..<spinners {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                while !stop.value.load(ordering: .relaxed) {}
            }
        }
        defer {
            stop.value.store(true, ordering: .releasing)
            #expect(group.wait(timeout: .now() + 10) == .success)
        }
        try await Task.sleep(for: .milliseconds(200))
        print(await Self.run("duress", iterations: 6000))
    }
}

final class StopFlag: Sendable {
    let value = Atomic<Bool>(false)
}
SWIFT
ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
echo "host: $(uname -sm) ncpu=$ncpu"
for sha in "$@"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch -q origin "$sha"
  git show "$sha:$src" > "$src" || { echo "no $src at $sha" >&2; exit 1; }
  echo "BENCH-AT $(git rev-parse --short "$sha")"
  (cd "$pkg" && NOTE_STALL_BENCH=1 swift test -c release --filter NoteStallBench)
  echo "load: $(uptime | sed 's/.*load average[s]*: //')"
done
