import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct MachineDeleteCoordinatorTests {
    @Test func repeatedDestroyJoinsTheRequestInFlightThenAnswersAlreadyGone() async throws {
        let fixture = MachineDeleteFixture()
        let coordinator = fixture.makeCoordinator()
        let first = Task { try await coordinator.destroy(id: "m1") }
        try await fixture.waitForRequest()
        #expect(coordinator.hiddenMachineIDs == ["m1"] && coordinator.pendingMachineIDs == ["m1"])
        #expect(fixture.detached == ["m1"], "The machine is detached before the request answers")
        #expect(!coordinator.canBegin("m1"))

        let repeated = Task { try await coordinator.destroy(id: "m1") }
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
        #expect(fixture.requested.isEmpty)

        #expect(coordinator.begin("m1"))
        let request = Task { try await coordinator.destroy(id: "m1") }
        try await fixture.waitForRequest()
        coordinator.launchEnded("m1")
        #expect(coordinator.hiddenMachineIDs == ["m1"], "The request's outcome decides, not the CLI's exit")
        fixture.answer(throwing: VMClientError.httpStatus(503, "unavailable"))
        await #expect(throws: VMClientError.self) { try await request.value }
        #expect(coordinator.hiddenMachineIDs.isEmpty)
        #expect(fixture.detached == ["m1", "m1"] && fixture.requested == ["m1"] && fixture.retired.isEmpty)
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
            didRetire: { [unowned self] in self.retired.append($0) }
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
        let request = openRequests.removeFirst()
        if let error {
            request.resume(throwing: error)
        } else {
            request.resume()
        }
    }
}
