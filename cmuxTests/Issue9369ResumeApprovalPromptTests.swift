import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Issue #9369: the `surface.resume.set` approval prompt used to run
/// `NSAlert.runModal()` inside the socket main-actor hop, so unrelated
/// `surface.resume.get` / `.clear` requests queued behind the alert until they
/// timed out. These tests drive the pending-approval lifecycle synchronously
/// on the main actor (no run loop, no sleeps): while a prompt is open, every
/// coordinator call returns immediately, duplicate sets stay pending instead
/// of stacking a second modal, a clear cancels the prompt, and the decision is
/// handed to the retried set exactly once.
@MainActor
@Suite struct Issue9369ResumeApprovalPromptTests {
    private typealias Coordinator = SurfaceResumeApprovalPromptCoordinator

    private final class PromptRecorder {
        private(set) var presentedCount = 0
        private(set) var cancelledCount = 0
        private(set) var decisions: [Coordinator.Decision] = []
        private var completion: (@MainActor (Coordinator.Decision?) -> Void)?

        @MainActor
        func presenter(_ completion: @escaping @MainActor (Coordinator.Decision?) -> Void) -> @MainActor () -> Void {
            presentedCount += 1
            self.completion = completion
            return { self.cancelledCount += 1 }
        }

        @MainActor
        func answer(_ decision: Coordinator.Decision?) {
            let completion = self.completion
            self.completion = nil
            completion?(decision)
        }

        @MainActor
        func recordDecision(_ decision: Coordinator.Decision) {
            decisions.append(decision)
        }
    }

    private func makeKey(
        surfaceID: UUID = UUID(),
        command: String = "tmux attach -t work"
    ) -> Coordinator.RequestKey {
        Coordinator.RequestKey(
            surfaceID: surfaceID,
            binding: SurfaceResumeBindingSnapshot(command: command, cwd: "/tmp/project")
        )
    }

    @Test func openPromptNeverBlocksAndDuplicateSetsShareIt() {
        let coordinator = Coordinator()
        let recorder = PromptRecorder()
        let key = makeKey()

        let first = coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        }
        #expect(first == .pending)
        #expect(recorder.presentedCount == 1)
        #expect(coordinator.hasPendingPrompt(surfaceID: key.surfaceID))

        // A duplicate set (retry) while the prompt is open joins it instead of
        // presenting a second modal; a set for another surface is rejected as
        // pending too — the single slot stays owned by the open prompt.
        let retry = coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        }
        let otherSurface = coordinator.begin(key: makeKey(), presenter: recorder.presenter) {
            recorder.recordDecision($0)
        }
        #expect(retry == .pending)
        #expect(otherSurface == .pending)
        #expect(recorder.presentedCount == 1)

        // get/clear-style reads run on their own synchronous path; the only
        // coordinator touchpoint while a prompt is open completes inline.
        #expect(!coordinator.hasPendingPrompt(surfaceID: UUID()))
    }

    @Test func decisionCompletesPendingSetAndHandsOffToOneRetry() {
        let coordinator = Coordinator()
        let recorder = PromptRecorder()
        let key = makeKey()
        let decision = Coordinator.Decision(policy: .auto, commandPrefix: ["tmux"])

        #expect(coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        } == .pending)

        recorder.answer(decision)
        #expect(recorder.decisions == [decision], "the pending set completes when the user answers")
        #expect(!coordinator.hasPendingPrompt(surfaceID: key.surfaceID))

        // The retried set consumes the decision exactly once and never
        // re-presents the prompt for it.
        let retry = coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        }
        #expect(retry == .decided(decision))
        #expect(recorder.presentedCount == 1)

        // With the decision consumed, the same request prompts afresh.
        #expect(coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        } == .pending)
        #expect(recorder.presentedCount == 2)
    }

    @Test func clearCancelsPendingApprovalWithoutApplyingIt() {
        let coordinator = Coordinator()
        let recorder = PromptRecorder()
        let key = makeKey()

        #expect(coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        } == .pending)

        // resume.clear for an unrelated surface leaves the prompt alone.
        coordinator.cancelPending(surfaceID: UUID())
        #expect(recorder.cancelledCount == 0)
        #expect(coordinator.hasPendingPrompt(surfaceID: key.surfaceID))

        // resume.clear for the prompting surface dismisses it; the sheet's
        // late no-decision callback is a no-op, and nothing was applied.
        coordinator.cancelPending(surfaceID: key.surfaceID)
        #expect(recorder.cancelledCount == 1)
        #expect(!coordinator.hasPendingPrompt(surfaceID: key.surfaceID))
        recorder.answer(nil)
        #expect(recorder.decisions.isEmpty)

        // The slot is free again for the next set.
        #expect(coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        } == .pending)
        #expect(recorder.presentedCount == 2)
    }

    @Test func clearDropsAnUnconsumedDecisionForItsSurface() {
        let coordinator = Coordinator()
        let recorder = PromptRecorder()
        let key = makeKey()
        let decision = Coordinator.Decision(policy: .prompt, commandPrefix: nil)

        #expect(coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        } == .pending)
        recorder.answer(decision)

        coordinator.cancelPending(surfaceID: key.surfaceID)

        // The cleared surface's stale decision must not complete a later set.
        #expect(coordinator.begin(key: key, presenter: recorder.presenter) {
            recorder.recordDecision($0)
        } == .pending)
        #expect(recorder.presentedCount == 2)
    }

    @Test func synchronousDecisionResolvesTheInitiatingSet() {
        let coordinator = Coordinator()
        let decision = Coordinator.Decision(policy: .manual, commandPrefix: nil)
        var applied: [Coordinator.Decision] = []

        // A presenter that answers before returning (no run loop involved)
        // resolves the initiating set in the same call.
        let outcome = coordinator.begin(
            key: makeKey(),
            presenter: { completion in
                completion(decision)
                return {}
            },
            onDecision: { applied.append($0) }
        )
        #expect(outcome == .decided(decision))
        #expect(applied == [decision])
    }
}
