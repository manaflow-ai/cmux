import Foundation
import Testing

@testable import CmuxMobileTerminal

/// Ordering contract for the viewport report scheduler: sends are serialized
/// in submission order, superseded reports are never sent, and an echo is
/// applied only while its report is still the newest — the pure form of the
/// keyboard open/close race behind the "extra space at the top" letterbox bug
/// (see `TerminalViewportSpacingTests`).
@MainActor
private final class SchedulerProbe {
    private(set) var sent: [UInt64] = []
    private(set) var applied: [(id: UInt64, rows: Int?)] = []
    private var gates: [UInt64: CheckedContinuation<TerminalViewportReportScheduler.EffectiveGrid?, Never>] = [:]
    private(set) lazy var scheduler = TerminalViewportReportScheduler(
        send: { [weak self] report in
            guard let self else { return nil }
            self.sent.append(report.id)
            return await withCheckedContinuation { continuation in
                self.gates[report.id] = continuation
            }
        },
        apply: { [weak self] report, effective in
            self?.applied.append((id: report.id, rows: effective?.rows))
        }
    )

    func submit(id: UInt64, columns: Int = 40, rows: Int) {
        scheduler.submit(.init(id: id, columns: columns, rows: rows))
    }

    /// Resolve the in-flight RPC for `id` with an effective grid (or a drop).
    func resolve(id: UInt64, rows: Int?) {
        guard let continuation = gates.removeValue(forKey: id) else {
            Issue.record("no in-flight send for report \(id)")
            return
        }
        continuation.resume(returning: rows.map { (columns: 40, rows: $0) })
    }

    /// Cooperatively spin until `condition` holds (all work is main-actor, so
    /// yielding is enough to advance the scheduler's drain task).
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
@Suite("TerminalViewportReportScheduler ordering")
struct TerminalViewportReportSchedulerTests {
    @Test("a report superseded while another is in flight is sent next and only its echo applies")
    func staleEchoDroppedNewerSent() async {
        let probe = SchedulerProbe()

        // Keyboard opens: report 1 goes out and its RPC hangs.
        probe.submit(id: 1, rows: 30)
        #expect(await probe.waitUntil { probe.sent == [1] })

        // Keyboard closes while report 1 is still in flight.
        probe.submit(id: 2, rows: 55)

        // Report 1's echo finally lands — but report 2 superseded it, so the
        // echo must be discarded, not applied.
        probe.resolve(id: 1, rows: 30)
        #expect(await probe.waitUntil { probe.sent == [1, 2] })
        #expect(probe.applied.isEmpty, "stale echo for report 1 was applied: \(probe.applied)")

        // Report 2's echo applies normally.
        probe.resolve(id: 2, rows: 55)
        #expect(await probe.waitUntil { probe.applied.count == 1 })
        #expect(probe.applied.first?.id == 2)
        #expect(probe.applied.first?.rows == 55)
    }

    @Test("a report superseded before its send starts is never sent")
    func supersededBeforeSendSkipped() async {
        let probe = SchedulerProbe()

        // Two reports land in the same main-actor turn (keyboard open
        // immediately followed by close): only the newest ever hits the wire.
        probe.submit(id: 1, rows: 30)
        probe.submit(id: 2, rows: 55)
        #expect(await probe.waitUntil { probe.sent.count == 1 })
        #expect(probe.sent == [2])

        probe.resolve(id: 2, rows: 55)
        #expect(await probe.waitUntil { probe.applied.count == 1 })
        #expect(probe.applied.first?.id == 2)
    }

    @Test("settled sequential reports each send and apply in order")
    func sequentialReportsApplyInOrder() async {
        let probe = SchedulerProbe()

        probe.submit(id: 1, rows: 30)
        #expect(await probe.waitUntil { probe.sent == [1] })
        probe.resolve(id: 1, rows: 30)
        #expect(await probe.waitUntil { probe.applied.count == 1 })

        probe.submit(id: 2, rows: 55)
        #expect(await probe.waitUntil { probe.sent == [1, 2] })
        probe.resolve(id: 2, rows: 55)
        #expect(await probe.waitUntil { probe.applied.count == 2 })

        #expect(probe.applied.map(\.id) == [1, 2])
        #expect(probe.applied.map(\.rows) == [30, 55])
    }

    @Test("a dropped RPC still delivers a nil echo so the caller can retry")
    func nilEchoDelivered() async {
        let probe = SchedulerProbe()

        probe.submit(id: 1, rows: 55)
        #expect(await probe.waitUntil { probe.sent == [1] })
        probe.resolve(id: 1, rows: nil)
        #expect(await probe.waitUntil { probe.applied.count == 1 })
        #expect(probe.applied.first?.id == 1)
        #expect(probe.applied.first?.rows == nil)
    }

    @Test("cancel during an in-flight send never applies its echo")
    func cancelStopsApplication() async {
        let probe = SchedulerProbe()

        // Report 1 is in flight when the owner detaches (cancel). Its echo
        // resolving afterwards must not reach apply.
        probe.submit(id: 1, rows: 55)
        #expect(await probe.waitUntil { probe.sent == [1] })
        probe.scheduler.cancel()
        probe.resolve(id: 1, rows: 55)
        for _ in 0..<200 { await Task.yield() }
        #expect(probe.applied.isEmpty, "echo applied after cancel: \(probe.applied)")

        // The scheduler stays usable after cancel: a new submit drains again.
        probe.submit(id: 2, rows: 60)
        #expect(await probe.waitUntil { probe.sent == [1, 2] })
        probe.resolve(id: 2, rows: 60)
        #expect(await probe.waitUntil { probe.applied.count == 1 })
        #expect(probe.applied.first?.id == 2)
    }
}
