import CmuxAuthRuntime
import Testing
@testable import CmuxiOSAccount

/// Settings > Delete Account: confirmation, progress, failure with retry,
/// and sign-out only after the account is gone.
@MainActor
@Suite struct AccountDeletionModelTests {
    @Test func deleteAsksFirstAndCancelChangesNothing() {
        let probe = Probe()
        let model = probe.model()

        model.requestDeletion()
        #expect(model.phase == .confirming)
        #expect(model.isConfirming)

        model.cancel()
        #expect(model.phase == .idle)
        #expect(probe.deletes == 0)
        #expect(probe.signOuts == 0)
    }

    @Test func confirmingLeavesTheConfirmationAtOnceAndShowsProgress() async {
        let probe = Probe()
        let model = probe.model()
        model.requestDeletion()

        let task = model.confirm()
        // Before the request runs: the alert's binding already reads false.
        #expect(model.phase == .deleting)
        #expect(!model.isConfirming)
        #expect(model.isDeleting)
        await task?.value

        #expect(model.phase == .deleted)
        #expect(probe.deletes == 1)
        #expect(probe.signOuts == 1)
    }

    @Test func confirmWithoutTheConfirmationDoesNothing() async {
        let probe = Probe()
        let model = probe.model()

        #expect(model.confirm() == nil)
        #expect(model.phase == .idle)
        #expect(probe.deletes == 0)
    }

    @Test func aSecondDeleteTapWhileDeletingIsIgnored() async {
        let probe = Probe()
        let model = probe.model()
        model.requestDeletion()
        let task = model.confirm()

        model.requestDeletion()
        #expect(model.phase == .deleting)
        #expect(model.confirm() == nil)
        await task?.value
        #expect(probe.deletes == 1)
    }

    @Test(arguments: [
        (AccountDeletionRequestError.localTransportFailure, AccountDeletionFailure.offline),
        (.timedOut, .unconfirmed),
        (.completionUnknown, .unconfirmed),
        (.stackDeleteIncomplete, .unconfirmed),
        (.unauthorized, .sessionExpired),
        (.rejected(statusCode: 500), .refused),
        (.invalidResponse, .refused),
    ])
    func aFailureStaysSignedInAndSaysWhy(error: AccountDeletionRequestError, expected: AccountDeletionFailure) async {
        let probe = Probe(failures: [error])
        let model = probe.model()
        model.requestDeletion()

        await model.confirm()?.value

        #expect(model.phase == .failed(expected))
        #expect(model.failure == expected)
        #expect(!model.isDeleting)
        #expect(probe.signOuts == 0)
        #expect(!expected.message.isEmpty)
    }

    @Test func anUnknownErrorIsARefusal() {
        struct Other: Error {}
        #expect(AccountDeletionFailure(Other()) == .refused)
    }

    @Test func retryDeletesWithoutAskingAgainAndSignsOut() async {
        let probe = Probe(failures: [AccountDeletionRequestError.localTransportFailure])
        let model = probe.model()
        model.requestDeletion()
        await model.confirm()?.value
        #expect(model.phase == .failed(.offline))

        let task = model.retry()
        #expect(model.phase == .deleting)
        await task?.value

        #expect(model.phase == .deleted)
        #expect(probe.deletes == 2)
        #expect(probe.signOuts == 1)
    }

    @Test func retryWithoutAFailureDoesNothing() {
        let probe = Probe()
        let model = probe.model()

        #expect(model.retry() == nil)
        #expect(model.phase == .idle)
    }

    @Test func deleteAfterAFailureAsksAgain() async {
        let probe = Probe(failures: [AccountDeletionRequestError.rejected(statusCode: 500)])
        let model = probe.model()
        model.requestDeletion()
        await model.confirm()?.value

        model.requestDeletion()
        #expect(model.phase == .confirming)
        model.cancel()
        #expect(model.phase == .idle)
    }

    @Test func signOutRunsAfterTheDeleteReturns() async {
        let probe = Probe()
        let model = probe.model()
        model.requestDeletion()

        await model.confirm()?.value

        #expect(probe.order == ["delete", "signOut"])
    }
}

/// Records the injected request and sign-out; throws the queued failures first.
@MainActor
private final class Probe {
    private var failures: [any Error]
    private(set) var order: [String] = []
    var deletes: Int { order.filter { $0 == "delete" }.count }
    var signOuts: Int { order.filter { $0 == "signOut" }.count }

    init(failures: [any Error] = []) {
        self.failures = failures
    }

    func model() -> AccountDeletionModel {
        AccountDeletionModel(
            delete: { [self] in
                order.append("delete")
                if !failures.isEmpty { throw failures.removeFirst() }
            },
            signOut: { [self] in order.append("signOut") }
        )
    }
}
