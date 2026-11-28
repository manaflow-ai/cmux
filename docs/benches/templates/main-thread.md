# Main thread: a budgeted bench at realistic scale

**Proves:** the change keeps the main actor's work per frame, row or call bounded at Leo/Lawrence scale (1,100
workspaces, 10,789 sidebar rows, 100k transcript rows, a 160 KB cmux.json, 20 streaming chats), and that cost
does not grow with the input. cmux#59531 (a 160 KB encode per sidebar row, 2-6 s hangs) is the case it catches.

**The minimal check:**
1. Build the fixture at scale and at 1/10 or 1/100 of it, in the test.
2. Time the main-actor path (not the whole app): samples, p95.
3. Assert an absolute budget (frame: 8 ms at 120 Hz; a one-off action: 100 ms) AND a ratio: p95 at scale within
   1.2-2x of p95 small. The ratio catches O(n) per row even on a fast machine.
4. Print one JSON line (`name`, `p95`, `unit`, `ratio`) so `cmux-bench --import` can ledger it.
5. Register the suite in `docs/benches/coverage-map.md` and its area in `docs/benches/relevance-map.toml`.

```swift
import Testing
@testable import CmuxNextSidebar

@MainActor
@Suite struct SidebarFlushBench {
    static func p95(_ v: [UInt64]) -> UInt64 { v.sorted()[min(v.count - 1, v.count * 95 / 100)] }

    func flushSamples(rows: Int, rounds: Int = 30) -> [UInt64] {
        let model = SidebarModel(fixture: .workspaces(rows, chiefs: 5, settingsBytes: 160_000))
        return (0..<rounds).map { _ in
            let t = DispatchTime.now().uptimeNanoseconds
            model.flush()                                  // the main-actor path under test
            return DispatchTime.now().uptimeNanoseconds - t
        }
    }

    @Test func flushIsFlatAtScale() {
        let small = Self.p95(flushSamples(rows: 110)), big = Self.p95(flushSamples(rows: 1_100))
        print(#"{"name":"sidebar.flush","small_p95":\#(small),"p95":\#(big),"unit":"ns"}"#)
        #expect(big < 250_000_000, "flush p95 \(big) ns at 1,100 rows (budget 250 ms)")
        #expect(Double(big) / Double(max(small, 1)) <= 2.0, "flush grows with rows: \(small) -> \(big) ns")
    }
}
```

Copy from: `Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests/AcpmuxChatRowsBench.swift` (100k rows, ratio <= 1.2).
Rendering and main-thread findings go to the Chrome-model RFD lane (fs-agent-lane-4/chrome-model-rfd).
