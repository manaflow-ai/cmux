import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Opening the find bar after a find-window jump, loading the full history first
/// when the match is older than the attach seed.
@MainActor
@Suite struct RemoteTmuxFindWindowJumperTests {
    @Test func aMatchInsideTheAttachSeedOpensSearchAtOnce() {
        let jumper = RemoteTmuxFindWindowJumper()
        var opened = 0
        jumper.jump(
            loadsFullHistoryFirst: false,
            reseed: {
                Issue.record("nothing to load")
                return .failed
            },
            isStillTarget: { true },
            openSearch: { opened += 1 }
        )
        #expect(opened == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aNewerJumpWinsOverOneStillLoading() async {
        let jumper = RemoteTmuxFindWindowJumper()
        let load = LoadGate()
        var opened: [String] = []
        let first = jumper.jump(
            loadsFullHistoryFirst: true,
            reseed: { await load.wait() },
            isStillTarget: { true },
            openSearch: { opened.append("first") }
        )
        await load.started()

        jumper.jump(loadsFullHistoryFirst: false, reseed: { .failed }, isStillTarget: { true }, openSearch: {
            opened.append("second")
        })
        load.release(.loaded(historyRows: 10, truncated: false))
        await first?.value

        #expect(opened == ["second"])
    }

    @Test(.timeLimit(.minutes(1))) func aTargetThatLostFocusWhileLoadingGetsNoFindBar() async {
        let jumper = RemoteTmuxFindWindowJumper()
        let load = LoadGate()
        var stillTarget = true
        var opened = 0
        let jump = jumper.jump(
            loadsFullHistoryFirst: true,
            reseed: { await load.wait() },
            isStillTarget: { stillTarget },
            openSearch: { opened += 1 }
        )
        await load.started()

        stillTarget = false
        load.release(.loaded(historyRows: 10, truncated: false))
        await jump?.value

        #expect(opened == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aFailedLoadStillOpensTheFindBar() async {
        let jumper = RemoteTmuxFindWindowJumper()
        var opened = 0
        let jump = jumper.jump(
            loadsFullHistoryFirst: true,
            reseed: { .failed },
            isStillTarget: { true },
            openSearch: { opened += 1 }
        )
        await jump?.value

        // The find bar's own full-history button shows the failure and can retry.
        #expect(opened == 1)
    }
}

/// Holds a full-history load until the test releases it.
@MainActor
private final class LoadGate {
    private var continuation: CheckedContinuation<RemoteTmuxFullHistorySeedOutcome, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> RemoteTmuxFullHistorySeedOutcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedWaiters.forEach { $0.resume() }
            startedWaiters = []
        }
    }

    func started() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release(_ outcome: RemoteTmuxFullHistorySeedOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
