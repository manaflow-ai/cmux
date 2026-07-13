import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCreateWorkingDirectoryValidationServiceTests {
    @Test func samePathWaitersShareOneProbe() async {
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = Self.service(probe: probe, deadlines: deadlines)
        let first = Task { await service.validate(rawValue: "/tmp/shared", isProvided: true) }
        let second = Task { await service.validate(rawValue: "/tmp/shared", isProvided: true) }
        await probe.waitForCount(1)

        #expect(await probe.count == 1)
        await probe.complete(path: "/tmp/shared", isDirectory: true)
        #expect(await first.value == .valid("/tmp/shared"))
        #expect(await second.value == .valid("/tmp/shared"))
        await service.waitUntilIdleForTesting()
        #expect(await service.waiterCountForTesting() == 0)
    }

    @Test func validationTimeoutCreatesNoWorkspaceAndMapsToRequestTimeout() async {
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = Self.service(probe: probe, deadlines: deadlines)
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let create = Task { @MainActor in
            await TerminalController.shared.v2MobileWorkspaceCreate(
                params: ["working_directory": "/tmp/wedged"],
                workingDirectoryValidator: { rawValue, isProvided in
                    await service.validate(rawValue: rawValue, isProvided: isProvided)
                },
                tabManager: manager
            )
        }
        await probe.waitForCount(1)
        await deadlines.waitForCount(1)

        await deadlines.fireAll()
        let result = await create.value

        #expect(Self.errorCode(from: result) == "request_timeout")
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
        await probe.complete(path: "/tmp/wedged", isDirectory: true)
        await service.waitUntilIdleForTesting()
    }

    @Test func oneWedgedProbeLeavesSecondSlotAvailableAndSamePathRemainsCoalesced() async {
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = Self.service(probe: probe, deadlines: deadlines)
        let first = Task { await service.validate(rawValue: "/external/wedged", isProvided: true) }
        await probe.waitForCount(1)
        await deadlines.waitForCount(1)
        await deadlines.fireAll()
        #expect(await first.value == .timedOut)

        let samePath = Task { await service.validate(rawValue: "/external/wedged", isProvided: true) }
        let differentPath = Task { await service.validate(rawValue: "/external/different", isProvided: true) }
        await deadlines.waitForCount(3)
        await probe.waitForCount(2)
        #expect(await probe.count == 2)
        await probe.complete(path: "/external/different", isDirectory: true)
        #expect(await differentPath.value == .valid("/external/different"))
        await deadlines.fireAll()
        #expect(await samePath.value == .timedOut)
        #expect(await probe.count == 2)

        await probe.complete(path: "/external/wedged", isDirectory: true)
        await service.waitUntilIdleForTesting()
    }

    @Test func twoWedgedExternalProbesPreserveLocalLaneAndEnforceExternalCap() async {
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = Self.service(probe: probe, deadlines: deadlines)
        let first = Task { await service.validate(rawValue: "/external/first-wedge", isProvided: true) }
        let second = Task { await service.validate(rawValue: "/external/second-wedge", isProvided: true) }
        await probe.waitForCount(2)
        await deadlines.waitForCount(2)
        await deadlines.fireAll()
        #expect(await first.value == .timedOut)
        #expect(await second.value == .timedOut)

        let third = Task { await service.validate(rawValue: "/external/third", isProvided: true) }
        let local = Task { await service.validate(rawValue: "/Users/test/project", isProvided: true) }
        await deadlines.waitForCount(4)
        await probe.waitForCount(3)
        #expect(await probe.count == 3)
        await probe.complete(path: "/Users/test/project", isDirectory: true)
        #expect(await local.value == .valid("/Users/test/project"))
        await deadlines.fireAll()
        #expect(await third.value == .timedOut)

        let repeated = Task { await service.validate(rawValue: "/external/first-wedge", isProvided: true) }
        await deadlines.waitForCount(5)
        #expect(await probe.count == 3)
        await deadlines.fireAll()
        #expect(await repeated.value == .timedOut)
        #expect(await probe.count == 3)

        await probe.complete(path: "/external/first-wedge", isDirectory: true)
        let recovered = Task { await service.validate(rawValue: "/external/recovered", isProvided: true) }
        await probe.waitForCount(4)
        #expect(await probe.count == 4)
        await probe.complete(path: "/external/recovered", isDirectory: true)
        #expect(await recovered.value == .valid("/external/recovered"))
        await probe.complete(path: "/external/second-wedge", isDirectory: true)
        await service.waitUntilIdleForTesting()
    }

    @Test func cancellingOneCoalescedWaiterDoesNotCancelProbeOrOtherWaiter() async {
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = Self.service(probe: probe, deadlines: deadlines)
        let cancelled = Task { await service.validate(rawValue: "/tmp/shared", isProvided: true) }
        let remaining = Task { await service.validate(rawValue: "/tmp/shared", isProvided: true) }
        await probe.waitForCount(1)
        await deadlines.waitForCount(2)

        cancelled.cancel()
        #expect(await cancelled.value == .cancelled)
        #expect(await service.waiterCountForTesting() == 1)
        #expect(await probe.count == 1)
        await probe.complete(path: "/tmp/shared", isDirectory: true)
        #expect(await remaining.value == .valid("/tmp/shared"))
        await service.waitUntilIdleForTesting()
        #expect(await service.waiterCountForTesting() == 0)
    }

    @Test func cancellationRacingDeadlineResumesWaiterExactlyOnceAndCleansUp() async {
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = Self.service(probe: probe, deadlines: deadlines)
        let validation = Task { await service.validate(rawValue: "/tmp/race", isProvided: true) }
        await probe.waitForCount(1)
        await deadlines.waitForCount(1)

        validation.cancel()
        await deadlines.fireAll()
        let result = await validation.value

        #expect(result == .cancelled || result == .timedOut)
        #expect(await service.waiterCountForTesting() == 0)
        await probe.complete(path: "/tmp/race", isDirectory: true)
        await service.waitUntilIdleForTesting()
        #expect(await service.waiterCountForTesting() == 0)
    }

    private static func service(
        probe: ControlledDirectoryProbe,
        deadlines: ControlledValidationDeadlines
    ) -> TerminalController.WorkspaceCreateWorkingDirectoryValidationService {
        TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 2,
            laneClassifier: { path in path.hasPrefix("/external/") ? .external : .local },
            probe: { path in await probe.run(path: path) },
            sleepUntilDeadline: { _ in await deadlines.sleep() }
        )
    }

    private static func errorCode(from result: TerminalController.V2CallResult) -> String? {
        guard case let .err(code, _, _) = result else { return nil }
        return code
    }
}

private actor ControlledDirectoryProbe {
    private(set) var count = 0
    private var activeContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func run(path: String) async -> Bool {
        count += 1
        resumeCountWaiters()
        return await withCheckedContinuation { activeContinuations[path] = $0 }
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func complete(path: String, isDirectory: Bool) {
        activeContinuations.removeValue(forKey: path)?.resume(returning: isDirectory)
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { count >= $0.count }
        countWaiters.removeAll { count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}

private actor ControlledValidationDeadlines {
    private var totalCount = 0
    private var sleepers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                totalCount += 1
                sleepers[id] = continuation
                resumeCountWaiters()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitForCount(_ expected: Int) async {
        if totalCount >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func fireAll() {
        let continuations = Array(sleepers.values)
        sleepers.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func cancel(id: UUID) {
        sleepers.removeValue(forKey: id)?.resume()
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { totalCount >= $0.count }
        countWaiters.removeAll { totalCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}
