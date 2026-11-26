import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineDeleteCoordinatorTests {
    @Test func repeatedDestroyJoinsTheRequestInFlightThenAnswersAlreadyGone() async throws {
        let fixture = MachineDeleteFixture()
        let coordinator = fixture.makeCoordinator()
        let first = Task { try await coordinator.destroy(id: "m1") }
        try await fixture.waitForRequest()
        #expect(coordinator.hiddenMachineIDs == ["m1"] && coordinator.pendingMachineIDs == ["m1"])
        #expect(fixture.detached == ["m1"], "The machine is detached before the request answers")
        #expect(!coordinator.canBegin("m1"))

        // The repeat runs on the main actor without suspending until it awaits the
        // request in flight, so the test resumes only after the repeat has joined it.
        let repeatStarted = AsyncStream<Void>.makeStream()
        let repeated = Task {
            repeatStarted.continuation.yield(())
            return try await coordinator.destroy(id: "m1")
        }
        var started = repeatStarted.stream.makeAsyncIterator()
        _ = try #require(await started.next(), "Expected the repeat to start")
        fixture.answer()
        let firstWasGone = try await first.value
        let repeatedWasGone = try await repeated.value
        #expect(!firstWasGone && !repeatedWasGone, "A repeat joins the request in flight")
        #expect(fixture.requested == ["m1"])
        #expect(fixture.retired == ["m1"])
        #expect(coordinator.hiddenMachineIDs == ["m1"] && coordinator.pendingMachineIDs.isEmpty)

        let confirmedWasGone = try await coordinator.destroy(id: "m1")
        #expect(confirmedWasGone, "A confirmed deletion answers already gone")
        #expect(fixture.requested == ["m1"] && fixture.detached == ["m1"] && fixture.retired == ["m1"])
        #expect(fixture.restored.isEmpty)
    }

    @Test func detachRetiresTheMachinesCreatesBeforeClosingItsWorkspaces() {
        var steps: [String] = []
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        let creates = MachineCreateCoordinator(
            notifier: { _ in },
            notificationCenter: NotificationCenter(),
            cancelCreatedMachine: { steps.append("clean up \($0)") },
            cancelOperation: { _ in steps.append("close card") }
        )
        // The workspace's create has not named the machine yet.
        let workspaceID = UUID()
        let request = MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(workspaceID)
        #expect(creates.start(request, cancellableLaunch: launches.cancellableLaunch))

        MachineDeleteCoordinator.detachLocalPresentations(
            of: "m1",
            workspaceIDs: { steps.append("find \($0)"); return [workspaceID] },
            creates: creates,
            closeWorkspaces: { steps.append("close workspaces \($0) with \(creates.operations.count) creates") },
            closePanes: { steps.append("close panes \($0)") },
            republishSocketReads: { steps.append("republish socket reads") }
        )
        // Closing a workspace first would cancel its create, whose receipt then
        // destroys the machine even when this delete fails. The create's card stays
        // for the whole-workspace close. Socket reads, such as `cmux workspace list`
        // while `cmux vm rm` waits, see the closes before the destroy request returns.
        #expect(steps == [
            "find m1", "close workspaces m1 with 0 creates", "close panes m1", "republish socket reads",
        ])
        #expect(launches.cancellations == 1)
    }

    @Test func retireClosesTheMachinesRegistrationsThenRepublishesSocketReads() {
        var steps: [String] = []
        MachineDeleteCoordinator.retireLocalPresentations(
            of: "m1",
            closeRegistrations: { steps.append("close registrations \($0)") },
            republishSocketReads: { steps.append("republish socket reads") }
        )
        // A workspace or URL pane opened on the machine while its delete was pending
        // closes here. `cmux vm rm` reaches the delete through a worker-lane
        // `vm.destroy` call, which never refreshes socket reads when it returns.
        #expect(steps == ["close registrations m1", "republish socket reads"])
    }

    @Test func createCleanupDetachesOnlyAfterTheTransitionThatRequestedIt() async throws {
        var steps: [String] = []
        let deletions = MachineDeleteCoordinator(
            notificationCenter: NotificationCenter(),
            destroyMachine: { _ in },
            didHide: { steps.append("detach \($0)") },
            didRetire: { _ in },
            didRestore: { _ in }
        )
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        let creates = MachineCreateCoordinator(
            notifier: { _ in },
            notificationCenter: NotificationCenter(),
            cancelCreatedMachine: { steps.append("clean up \($0)"); deletions.beginCleanup($0) },
            cancelOperation: { _ in steps.append("close card") }
        )
        func startCreate(producing machineID: String) -> UUID {
            let workspaceID = UUID()
            let request = MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(workspaceID)
            #expect(creates.start(request, cancellableLaunch: launches.cancellableLaunch))
            launches.progressHandlers.last?("OK machine=\(machineID)\n")
            return workspaceID
        }

        _ = startCreate(producing: "m1")
        creates.cancel(try #require(creates.operations.first).id)
        // Closing the card first unbinds any pane the person added; detaching
        // the machine first would close that workspace whole.
        #expect(steps == ["clean up m1", "close card"])
        #expect(deletions.hiddenMachineIDs == ["m1"], "The machine hides at once")

        steps.removeAll()
        let closingWorkspaceID = startCreate(producing: "m2")
        // A workspace close cancels its creates while the workspace is still listed.
        creates.cancelOperations(forPresentationWorkspace: closingWorkspaceID)
        #expect(steps == ["clean up m2"], "Detaching inside the close would close the workspace again")

        // Each cleanup's `vm.destroy` request reaches the socket after its transition.
        _ = try await deletions.destroy(id: "m1")
        _ = try await deletions.destroy(id: "m2")
        #expect(steps == ["clean up m2", "detach m1", "detach m2"])
    }

    @Test func createCleanupDetachesOnlyOnceItsDestroyRequestStarts() async throws {
        let fixture = MachineDeleteFixture()
        let coordinator = fixture.makeCoordinator()
        coordinator.beginCleanup("m1")
        #expect(coordinator.hiddenMachineIDs == ["m1"], "The machine hides at once")
        // A CLI's exit reaches the app on a later main-actor turn than the cancel.
        await Task { @MainActor in }.value
        coordinator.launchEnded("m1")
        #expect(fixture.detached.isEmpty, "A cleanup whose CLI never reached the socket closes nothing")
        #expect(coordinator.hiddenMachineIDs.isEmpty && fixture.restored == ["m1"])

        coordinator.beginCleanup("m2")
        await Task { @MainActor in }.value
        #expect(fixture.detached.isEmpty)
        let request = Task { try await coordinator.destroy(id: "m2") }
        try await fixture.waitForRequest()
        #expect(fixture.detached == ["m2"], "The cleanup's request detaches the machine")
        fixture.answer()
        let wasGone = try await request.value
        #expect(!wasGone && fixture.requested == ["m2"] && fixture.retired == ["m2"])
    }

    @Test func cleanupJoinedByAnotherRemoveDetachesOnce() async throws {
        let fixture = MachineDeleteFixture()
        let coordinator = fixture.makeCoordinator()
        coordinator.beginCleanup("m1")
        // A terminal's `cmux vm rm` can reach the socket before the cleanup's CLI.
        let terminal = Task { try await coordinator.destroy(id: "m1") }
        try await fixture.waitForRequest()
        #expect(fixture.detached == ["m1"])

        let cleanupStarted = AsyncStream<Void>.makeStream()
        let cleanup = Task {
            cleanupStarted.continuation.yield(())
            return try await coordinator.destroy(id: "m1")
        }
        var started = cleanupStarted.stream.makeAsyncIterator()
        _ = try #require(await started.next(), "Expected the cleanup's request to start")
        fixture.answer()
        let terminalWasGone = try await terminal.value
        let cleanupWasGone = try await cleanup.value
        #expect(!terminalWasGone && !cleanupWasGone, "The cleanup joins the request in flight")
        #expect(fixture.detached == ["m1"] && fixture.requested == ["m1"] && fixture.retired == ["m1"])
    }

    @Test func notFoundRetiresTheMachineAndOtherFailuresRestoreIt() async throws {
        let fixture = MachineDeleteFixture()
        let coordinator = fixture.makeCoordinator()
        let missing = Task { try await coordinator.destroy(id: "gone") }
        try await fixture.waitForRequest()
        fixture.answer(throwing: VMClientError.httpStatus(404, "vm_not_found"))
        let missingWasGone = try await missing.value
        #expect(missingWasGone, "A machine the provider forgot is gone, never an error")
        #expect(fixture.retired == ["gone"])
        #expect(coordinator.hiddenMachineIDs == ["gone"])

        let failing = Task { try await coordinator.destroy(id: "kept") }
        try await fixture.waitForRequest()
        #expect(coordinator.hiddenMachineIDs == ["gone", "kept"])
        fixture.answer(throwing: VMClientError.httpStatus(500, "internal"))
        await #expect(throws: VMClientError.self) { try await failing.value }
        #expect(fixture.retired == ["gone"])
        #expect(fixture.restored == ["kept"], "Creates may keep the machine the failure lists again")
        #expect(coordinator.hiddenMachineIDs == ["gone"] && coordinator.pendingMachineIDs.isEmpty)
        #expect(coordinator.canBegin("kept"), "A failed delete can be retried")
    }

    @Test func launchEndRestoresOnlyADeletionWithoutARequest() async throws {
        let fixture = MachineDeleteFixture()
        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.begin("m1"))
        #expect(!coordinator.begin("m1"), "A second confirm is a no-op")
        coordinator.launchEnded("m1")
        #expect(coordinator.hiddenMachineIDs.isEmpty, "A CLI that never reached the socket restores the row")
        #expect(fixture.requested.isEmpty && fixture.restored == ["m1"])

        #expect(coordinator.begin("m1"))
        let request = Task { try await coordinator.destroy(id: "m1") }
        try await fixture.waitForRequest()
        coordinator.launchEnded("m1")
        #expect(coordinator.hiddenMachineIDs == ["m1"], "The request's outcome decides, not the CLI's exit")
        fixture.answer(throwing: VMClientError.httpStatus(503, "unavailable"))
        await #expect(throws: VMClientError.self) { try await request.value }
        #expect(coordinator.hiddenMachineIDs.isEmpty)
        #expect(fixture.detached == ["m1", "m1"] && fixture.requested == ["m1"] && fixture.retired.isEmpty)
        #expect(fixture.restored == ["m1", "m1"])
    }

    @Test func accountEndForgetsDeletionsAndFencesTheirLateOutcomes() async throws {
        let fixture = MachineDeleteFixture()
        let coordinator = fixture.makeCoordinator()
        let departedFailure = Task { try await coordinator.destroy(id: "m1") }
        try await fixture.waitForRequest()
        let departedSuccess = Task { try await coordinator.destroy(id: "m2") }
        try await fixture.waitForRequest()

        fixture.accountEvents.post(name: .cmuxCloudVMAccessDidEnd, object: nil)
        #expect(coordinator.hiddenMachineIDs.isEmpty && coordinator.pendingMachineIDs.isEmpty)

        let current = Task { try await coordinator.destroy(id: "m1") }
        try await fixture.waitForRequest()
        #expect(fixture.requested == ["m1", "m2", "m1"], "The next account sends its own request")
        fixture.answer(throwing: VMClientError.httpStatus(500, "internal"))
        await #expect(throws: VMClientError.self) { try await departedFailure.value }
        fixture.answer()
        let departedWasGone = try await departedSuccess.value
        #expect(!departedWasGone)
        #expect(coordinator.hiddenMachineIDs == ["m1"], "A departed account's failure never restores the current delete")
        #expect(fixture.retired.isEmpty, "A departed account's success closes nothing")
        #expect(fixture.restored.isEmpty, "A departed account's failure restores nothing")

        fixture.answer()
        let currentWasGone = try await current.value
        #expect(!currentWasGone)
        #expect(fixture.retired == ["m1"])
    }
}

/// Records the adapter's effects and holds each destroy request open until the test answers it.
@MainActor
private final class MachineDeleteFixture {
    let accountEvents = NotificationCenter()
    private(set) var requested: [String] = []
    private(set) var detached: [String] = []
    private(set) var retired: [String] = []
    private(set) var restored: [String] = []
    private var openRequests: [CheckedContinuation<Void, Error>] = []
    private let requestsSent = AsyncStream<Void>.makeStream()

    func makeCoordinator() -> MachineDeleteCoordinator {
        MachineDeleteCoordinator(
            notificationCenter: accountEvents,
            destroyMachine: { [unowned self] machineID in
                self.requested.append(machineID)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.openRequests.append(continuation)
                    self.requestsSent.continuation.yield(())
                }
            },
            didHide: { [unowned self] in self.detached.append($0) },
            didRetire: { [unowned self] in self.retired.append($0) },
            didRestore: { [unowned self] in self.restored.append($0) }
        )
    }

    /// Resumes after the next destroy request is sent and held open.
    func waitForRequest() async throws {
        var iterator = requestsSent.stream.makeAsyncIterator()
        _ = try #require(await iterator.next(), "Expected a destroy request")
    }

    /// Answers the oldest open destroy request.
    /// - Parameter error: The provider error, or nil for success.
    func answer(throwing error: Error? = nil) {
        guard !openRequests.isEmpty else {
            Issue.record("Expected an open destroy request")
            return
        }
        let request = openRequests.removeFirst()
        if let error {
            request.resume(throwing: error)
        } else {
            request.resume()
        }
    }
}
