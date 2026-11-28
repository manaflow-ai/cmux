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
root=$PWD
source scripts/measure/fetch-commit.sh
pkg=Packages/macOS/CmuxNext
src=$pkg/Sources/CmuxNextHangReports/HangReportCollector.swift
[ $# -ge 1 ] || { echo "usage: $0 SHA..." >&2; exit 2; }
# The bench builds in a throwaway package of its own: CmuxNextCompat, CmuxNextHangReports (the --ref's sources, with
# HangReportCollector.swift from each SHA) and one test target, NoteStallBench. A `swift test` in the CmuxNext package
# compiles every test target there, so an unrelated broken test at the --ref stopped the bench before it measured:
# three exclusive runs died that way on 2026-11-27/28 (launchRun in CloudStartSessionRequest.swift, a compiler crash
# at AgentPaneVideoInfoTests.swift:640), after 3-4 h each in the queue. Same compiler flags and same pinned
# swift-atomics, so the measured code is the same as in the full package.
work=$(mktemp -d "${TMPDIR:-/tmp}/note-stall-bench.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/Sources" "$work/Tests/NoteStallBenchTests"
cp -R "$pkg/Sources/CmuxNextCompat" "$pkg/Sources/CmuxNextHangReports" "$work/Sources/"
# swift-atomics at the CmuxNext package's pin (its Package.resolved lists every package there; only this one is needed).
atomics=$(awk '/"identity" : "swift-atomics"/ { f = 1 } f && /"version"/ { gsub(/[",]/, ""); print $3; exit }' "$pkg/Package.resolved")
[ -n "$atomics" ] || { echo "no swift-atomics pin in $pkg/Package.resolved" >&2; exit 1; }
cat > "$work/Package.swift" <<SWIFT
// swift-tools-version: 6.2
import PackageDescription
let settings: [SwiftSetting] = [ // = daemonSwiftSettings in $pkg/Package.swift
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]
let package = Package(
    name: "NoteStallBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$root/Packages/Shared/CmuxEgress"),
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "$atomics"),
    ],
    targets: [
        .target(name: "CmuxNextCompat", dependencies: [.product(name: "Atomics", package: "swift-atomics")],
                swiftSettings: settings),
        .target(name: "CmuxNextHangReports",
                dependencies: ["CmuxNextCompat", .product(name: "CmuxEgress", package: "CmuxEgress")],
                swiftSettings: settings),
        .testTarget(name: "NoteStallBenchTests", dependencies: ["CmuxNextCompat", "CmuxNextHangReports"],
                    swiftSettings: settings),
    ]
)
SWIFT
bench=$work/Tests/NoteStallBenchTests/NoteStallBench.swift
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

    /// The spinners' join, synchronous: `DispatchGroup.wait` is unavailable in an async function (Swift 6).
    static func joined(_ group: DispatchGroup) -> Bool { group.wait(timeout: .now() + 10) == .success }

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
            #expect(Self.joined(group))
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
  measure_fetch_commit . "$sha" || exit 1
  git show "$sha:$src" > "$work/Sources/CmuxNextHangReports/HangReportCollector.swift" || { echo "no $src at $sha" >&2; exit 1; }
  echo "BENCH-AT $(git rev-parse --short "$sha")"
  # package-test-lane.sh's release suite build: @testable needs -enable-testing, DEBUG stays defined as it was in the
  # full-package runs, and the Xcode 26.6 optimizer's CopyPropagation crash is avoided. CmuxNextHangReports has no #if,
  # so the measured code is the same.
  (cd "$work" && NOTE_STALL_BENCH=1 swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG \
    -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=copy-propagation --filter NoteStallBench)
  echo "load: $(uptime | sed 's/.*load average[s]*: //')"
done
