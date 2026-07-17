import Foundation
import Testing

#if DEBUG
@testable import cmux_DEV
#else
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AgentTerminalStateRuntimeLifecycleTests {
    @Test
    func reinstallWaitsForPriorTeardownAndRepeatedDropIsIdempotent() async {
        let sequencer = AgentTerminalSurfaceTaskSequencer()
        let surfaceID = UUID()
        let events = EventRecorder()
        let teardownGate = AsyncGate()

        sequencer.install(surfaceID: surfaceID) {
            await events.append("first-start")
        }
        await events.waitForCount(1)

        sequencer.drop(surfaceID: surfaceID) {
            await events.append("teardown-start")
            await teardownGate.wait()
            await events.append("teardown-finish")
        }
        sequencer.drop(surfaceID: surfaceID) {
            await events.append("duplicate-teardown")
        }
        await events.waitForCount(2)

        sequencer.install(surfaceID: surfaceID) {
            await events.append("second-start")
        }
        await Task.yield()
        #expect(await events.snapshot() == ["first-start", "teardown-start"])

        await teardownGate.open()
        await events.waitForCount(4)
        #expect(await events.snapshot() == [
            "first-start", "teardown-start", "teardown-finish", "second-start",
        ])
    }
}

private actor EventRecorder {
    private var events: [String] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ event: String) {
        events.append(event)
        let ready = waiters.filter { events.count >= $0.count }
        waiters.removeAll { events.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func snapshot() -> [String] {
        events
    }

    func waitForCount(_ count: Int) async {
        guard events.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
