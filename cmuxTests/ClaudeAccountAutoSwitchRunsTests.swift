import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The automatic switch's per-pane runs: one at a time per pane, each a stored task that a
/// closed pane or the coordinator going away cancels, and whose state clears however it ends.
@MainActor
struct ClaudeAccountAutoSwitchRunsTests {
    private let panelId = UUID(uuidString: "6A1C2F7E-3B1D-4E55-9F0A-0C2B7D4E8F11")!
    private let otherPanelId = UUID(uuidString: "0D7C6F8B-2E64-4C1B-9A55-6B1F2C3D4E5F")!

    /// A run's operation: it waits until its stream finishes or its task is cancelled, then
    /// records which.
    @MainActor
    private final class Operation {
        let stream: AsyncStream<Void>
        let continuation: AsyncStream<Void>.Continuation
        private(set) var ended = false
        private(set) var sawCancellation = false

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        }

        func run() async {
            for await _ in stream {}
            sawCancellation = Task.isCancelled
            ended = true
        }
    }

    @Test func aPaneRunsOneSwitchAtATime() async throws {
        let runs = ClaudeAccountAutoSwitchRuns()
        let first = Operation()
        let second = Operation()
        let other = Operation()

        let task = try #require(runs.start(panelId: panelId) { await first.run() })
        #expect(runs.start(panelId: panelId) { await second.run() } == nil)
        let otherTask = try #require(runs.start(panelId: otherPanelId) { await other.run() })

        first.continuation.finish()
        other.continuation.finish()
        await task.value
        await otherTask.value
        #expect(first.ended && other.ended)
        #expect(!second.ended)
        #expect(runs.isEmpty)
        let again = try #require(runs.start(panelId: panelId) { await second.run() })
        second.continuation.finish()
        await again.value
        #expect(second.ended)
    }

    @Test func aFinishedRunForgetsItsPaneAndItsEvents() async throws {
        let runs = ClaudeAccountAutoSwitchRuns()
        let operation = Operation()
        let event = ClaudeAccountAutoSwitchRuns.Event(kind: .sessionStarted, sessionId: "s", occurredAtMs: 1)

        runs.record(event, panelId: panelId)
        #expect(runs.events(panelId: panelId).isEmpty)
        let task = try #require(runs.start(panelId: panelId) { await operation.run() })
        runs.record(event, panelId: panelId)
        runs.record(event, panelId: otherPanelId)
        #expect(runs.isRunning(panelId: panelId))
        #expect(runs.events(panelId: panelId) == [event])
        #expect(runs.events(panelId: otherPanelId).isEmpty)

        operation.continuation.finish()
        await task.value
        #expect(!operation.sawCancellation)
        #expect(!runs.isRunning(panelId: panelId))
        #expect(runs.events(panelId: panelId).isEmpty)
    }

    @Test func cancellingARunEndsItAndClearsItsState() async throws {
        let runs = ClaudeAccountAutoSwitchRuns()
        let operation = Operation()
        let task = try #require(runs.start(panelId: panelId) { await operation.run() })
        runs.record(ClaudeAccountAutoSwitchRuns.Event(kind: .sessionStarted, sessionId: "s", occurredAtMs: 1), panelId: panelId)

        runs.cancel(panelId: panelId)
        // The cancelled run keeps its pane until it has unwound, so two never overlap.
        #expect(runs.isRunning(panelId: panelId))
        #expect(runs.start(panelId: panelId) { } == nil)

        // Ends the wait even if the cancel did not, so a failure reports instead of hanging.
        operation.continuation.finish()
        await task.value
        #expect(operation.sawCancellation)
        #expect(!runs.isRunning(panelId: panelId))
        #expect(runs.events(panelId: panelId).isEmpty)
        #expect(runs.isEmpty)
    }

    @Test func cancellingAPaneWithoutARunChangesNothing() async throws {
        let runs = ClaudeAccountAutoSwitchRuns()
        let operation = Operation()
        let task = try #require(runs.start(panelId: panelId) { await operation.run() })

        runs.cancel(panelId: otherPanelId)

        operation.continuation.finish()
        await task.value
        #expect(!operation.sawCancellation)
    }

    /// The coordinator learns of a close only through the pane: closing it must cancel the run
    /// the shared coordinator holds for it.
    @Test func closingThePaneCancelsItsAutomaticSwitch() async throws {
        let workspace = Workspace()
        let first = try #require(workspace.focusedTerminalPanel)
        let closing = try #require(workspace.newTerminalSplit(from: first.id, orientation: .horizontal, focus: false))
        let runs = ClaudeAccountAutoSwitchCoordinator.shared.runs
        let operation = Operation()
        let task = try #require(runs.start(panelId: closing.id) { await operation.run() })

        #expect(workspace.closePanel(closing.id, force: true))

        // Ends the wait even if the close did not cancel it, so a failure reports instead of hanging.
        operation.continuation.finish()
        await task.value
        #expect(operation.sawCancellation)
        #expect(!runs.isRunning(panelId: closing.id))
    }

    @Test func releasingTheRunsCancelsTheirTasks() async throws {
        var runs: ClaudeAccountAutoSwitchRuns? = ClaudeAccountAutoSwitchRuns()
        let operation = Operation()
        let task = try #require(runs?.start(panelId: panelId) { await operation.run() })

        runs = nil

        operation.continuation.finish()
        await task.value
        #expect(operation.sawCancellation)
    }
}
