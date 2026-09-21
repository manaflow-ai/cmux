import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records the alerts the prompter asks it to present and lets the test
/// answer them, standing in for the window sheet.
@MainActor
private final class RecordingSheetPresenter: SurfaceResumeApprovalSheetPresenting {
    private(set) var presented: [(alert: NSAlert, window: NSWindow?)] = []
    private var completions: [@MainActor (NSApplication.ModalResponse?) -> Void] = []
    var hostWindowAvailable = true

    func presentApprovalAlert(
        _ alert: NSAlert,
        preferring window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse?) -> Void
    ) {
        guard hostWindowAvailable else {
            completion(nil)
            return
        }
        presented.append((alert, window))
        completions.append(completion)
    }

    /// Answers the oldest presented alert the way the user would.
    func answer(_ response: NSApplication.ModalResponse) {
        let completion = completions.removeFirst()
        completion(response)
    }
}

/// The prompter is the only owner of "Allow Resume Command?" prompting: the
/// socket lane and the context menu both queue proposals here, and no command
/// ever waits on the user (https://github.com/manaflow-ai/cmux/issues/13369).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SurfaceResumeApprovalPrompterTests {
    private final class Approvals {
        var recorded: [(binding: SurfaceResumeBindingSnapshot, policy: SurfaceResumeApprovalPolicy, prefix: [String]?)] = []
        var applied: [SurfaceResumeApprovalRecord] = []
        /// Commands that already have a decision; mirrors a written record.
        var decidedCommands: Set<String> = []
    }

    private func makeBinding(_ command: String) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(command: command, cwd: "/tmp/project", source: "manual")
    }

    private func makePrompter(
        presenter: RecordingSheetPresenter,
        approvals: Approvals,
        canPrompt: Bool = true
    ) -> SurfaceResumeApprovalPrompter {
        SurfaceResumeApprovalPrompter(
            presenter: presenter,
            canPrompt: canPrompt,
            promptNeeded: { binding in !approvals.decidedCommands.contains(binding.command) },
            approve: { binding, policy, prefix in
                approvals.recorded.append((binding, policy, prefix))
                approvals.decidedCommands.insert(binding.command)
                return SurfaceResumeApprovalRecord(
                    commandPrefix: binding.command.split(separator: " ").map(String.init),
                    cwd: binding.cwd,
                    policy: policy
                )
            }
        )
    }

    private func proposal(
        _ binding: SurfaceResumeBindingSnapshot,
        approvals: Approvals
    ) -> SurfaceResumeApprovalProposal {
        SurfaceResumeApprovalProposal(
            binding: binding,
            preferredWindow: nil,
            apply: { record in approvals.applied.append(record) }
        )
    }

    @Test func enqueueReturnsImmediatelyAndAppliesTheDecisionWhenTheUserAnswers() {
        let presenter = RecordingSheetPresenter()
        let approvals = Approvals()
        let prompter = makePrompter(presenter: presenter, approvals: approvals)
        let binding = makeBinding("tmux attach -t work")

        #expect(prompter.enqueue(proposal(binding, approvals: approvals)))

        // The proposal is on screen, and the caller already has its answer.
        #expect(presenter.presented.count == 1)
        #expect(prompter.pendingProposalCount == 1)
        #expect(approvals.applied.isEmpty)

        presenter.answer(.alertFirstButtonReturn)

        #expect(approvals.recorded.count == 1)
        #expect(approvals.recorded.first?.policy == .auto)
        #expect(approvals.applied.count == 1)
        #expect(approvals.applied.first?.policy == .auto)
        #expect(prompter.pendingProposalCount == 0)
        #expect(prompter.decidedCount == 1)
    }

    @Test func presentsOneSheetAtATimeInArrivalOrder() {
        let presenter = RecordingSheetPresenter()
        let approvals = Approvals()
        let prompter = makePrompter(presenter: presenter, approvals: approvals)

        prompter.enqueue(proposal(makeBinding("claude --resume one"), approvals: approvals))
        prompter.enqueue(proposal(makeBinding("claude --resume two"), approvals: approvals))

        #expect(presenter.presented.count == 1)
        #expect(prompter.pendingProposalCount == 2)

        presenter.answer(.alertSecondButtonReturn)
        #expect(presenter.presented.count == 2)
        #expect(approvals.recorded.map(\.binding.command) == ["claude --resume one"])
        #expect(approvals.recorded.first?.policy == .prompt)

        presenter.answer(.alertThirdButtonReturn)
        #expect(approvals.recorded.map(\.policy) == [.prompt, .manual])
        #expect(prompter.pendingProposalCount == 0)
    }

    @Test func oneDecisionCoversIdenticalProposalsQueuedBehindIt() {
        let presenter = RecordingSheetPresenter()
        let approvals = Approvals()
        let prompter = makePrompter(presenter: presenter, approvals: approvals)
        let binding = makeBinding("codex resume abc")

        // Sixty agents proposing the same command must not produce sixty sheets.
        for _ in 0..<60 {
            prompter.enqueue(proposal(binding, approvals: approvals))
        }
        #expect(presenter.presented.count == 1)

        presenter.answer(.alertFirstButtonReturn)

        #expect(presenter.presented.count == 1)
        #expect(approvals.recorded.count == 1)
        #expect(prompter.pendingProposalCount == 0)
    }

    @Test func skipsProposalsWhenNoWindowCanHostTheSheet() {
        let presenter = RecordingSheetPresenter()
        presenter.hostWindowAvailable = false
        let approvals = Approvals()
        let prompter = makePrompter(presenter: presenter, approvals: approvals)

        #expect(prompter.enqueue(proposal(makeBinding("tmux attach -t work"), approvals: approvals)))

        #expect(presenter.presented.isEmpty)
        #expect(approvals.recorded.isEmpty)
        #expect(approvals.applied.isEmpty)
        #expect(prompter.pendingProposalCount == 0)
        #expect(prompter.unpresentableCount == 1)
    }

    @Test func refusesToQueueWhenThisProcessCannotPrompt() {
        let presenter = RecordingSheetPresenter()
        let approvals = Approvals()
        let prompter = makePrompter(presenter: presenter, approvals: approvals, canPrompt: false)

        #expect(!prompter.enqueue(proposal(makeBinding("tmux attach -t work"), approvals: approvals)))
        #expect(presenter.presented.isEmpty)
        #expect(prompter.pendingProposalCount == 0)
    }

    @Test func mapsAlertButtonsToPoliciesAndHonorsTheSuppressionPrefix() {
        let prefix = ["claude", "--resume"]
        #expect(SurfaceResumeApprovalPrompter.decision(for: .alertFirstButtonReturn, suppressionOn: true, folderScopedPrefix: prefix).policy == .auto)
        #expect(SurfaceResumeApprovalPrompter.decision(for: .alertFirstButtonReturn, suppressionOn: true, folderScopedPrefix: prefix).commandPrefix == prefix)
        #expect(SurfaceResumeApprovalPrompter.decision(for: .alertSecondButtonReturn, suppressionOn: false, folderScopedPrefix: prefix).policy == .prompt)
        #expect(SurfaceResumeApprovalPrompter.decision(for: .alertSecondButtonReturn, suppressionOn: false, folderScopedPrefix: prefix).commandPrefix == nil)
        #expect(SurfaceResumeApprovalPrompter.decision(for: .alertThirdButtonReturn, suppressionOn: true, folderScopedPrefix: nil).policy == .manual)
    }

    @Test func alertOffersAutoAskAndManualForALocalProposal() {
        let alert = SurfaceResumeApprovalPrompter.makeAlert(for: makeBinding("claude --resume abc123"))

        #expect(alert.alert.buttons.count == 3)
        #expect(alert.alert.showsSuppressionButton)
        #expect(alert.folderScopedPrefix == ["claude", "--resume"])
    }
}
