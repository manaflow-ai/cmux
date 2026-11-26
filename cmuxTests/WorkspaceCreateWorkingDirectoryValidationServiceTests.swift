import Darwin
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
    }
    @Test func canonicallyEquivalentPathsUseDistinctByteExactProbes() async {
        let composed = "/tmp/caf\u{00E9}"
        let decomposed = "/tmp/cafe\u{0301}"
        #expect(composed == decomposed && !Data(composed.utf8).elementsEqual(Data(decomposed.utf8)))
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 2,
            externalCapacity: 1,
            maximumPendingWaiters: 64,
            laneClassifier: { _ in .local },
            probe: { path, lane in await probe.run(path: path, lane: lane) },
            sleepUntilDeadline: { _ in await deadlines.suspendUntilFired() }
        )
        let first = Task { await service.validate(rawValue: composed, isProvided: true) }
        let second = Task { await service.validate(rawValue: decomposed, isProvided: true) }
        await probe.waitForCount(2)
        await probe.complete(path: composed, isDirectory: true)
        await probe.complete(path: decomposed, isDirectory: false)
        #expect(await first.value == .valid(composed))
        #expect(await second.value == .invalid)
    }
    @Test func pendingLimitRejectsNewPathsAndRecoversAfterAWaiterFinishes() async {
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 1,
            maximumPendingWaiters: 2,
            laneClassifier: { _ in .local },
            probe: { path, lane in await probe.run(path: path, lane: lane) },
            sleepUntilDeadline: { _ in await deadlines.suspendUntilFired() }
        )
        let active = Task { await service.validate(rawValue: "/tmp/active", isProvided: true) }
        await probe.waitForCount(1)
        let queued = Task { await service.validate(rawValue: "/tmp/queued", isProvided: true) }
        await deadlines.waitForCount(2)

        #expect(await service.validate(rawValue: "/tmp/rejected", isProvided: true) == .busy)
        #expect(await deadlines.count == 2)
        #expect(await probe.count == 1)

        await probe.complete(path: "/tmp/active", isDirectory: true)
        #expect(await active.value == .valid("/tmp/active"))
        await probe.waitForCount(2)
        await probe.complete(path: "/tmp/queued", isDirectory: true)
        #expect(await queued.value == .valid("/tmp/queued"))

        let recovered = Task { await service.validate(rawValue: "/tmp/recovered", isProvided: true) }
        await probe.waitForCount(3)
        await probe.complete(path: "/tmp/recovered", isDirectory: true)
        #expect(await recovered.value == .valid("/tmp/recovered"))
    }

    @Test func pendingLimitAlsoBoundsSamePathWaiters() async {
        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 1,
            maximumPendingWaiters: 2,
            laneClassifier: { _ in .local },
            probe: { path, lane in await probe.run(path: path, lane: lane) },
            sleepUntilDeadline: { _ in await deadlines.suspendUntilFired() }
        )
        let first = Task { await service.validate(rawValue: "/tmp/shared", isProvided: true) }
        let second = Task { await service.validate(rawValue: "/tmp/shared", isProvided: true) }
        await probe.waitForCount(1)
        await deadlines.waitForCount(2)

        #expect(await service.validate(rawValue: "/tmp/shared", isProvided: true) == .busy)
        #expect(await deadlines.count == 2)
        #expect(await probe.count == 1)

        await probe.complete(path: "/tmp/shared", isDirectory: true)
        #expect(await first.value == .valid("/tmp/shared"))
        #expect(await second.value == .valid("/tmp/shared"))
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
    }

    @Test func anySymlinkedComponentUsesExternalProbeLane() throws {
        let root = Self.nonSymlinkedTemporaryDirectory
            .appendingPathComponent("cmux-symlink-lane-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let linkedChild = link.appendingPathComponent("child", isDirectory: true).path

        #expect(TerminalController.v2WorkingDirectoryProbeLane(linkedChild) == .external)
    }

    @Test func symlinkAndExternalWedgesCannotOccupyReservedLocalLane() async throws {
        let root = Self.nonSymlinkedTemporaryDirectory
            .appendingPathComponent("cmux-symlink-capacity-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let local = root.appendingPathComponent("local", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedPath = link.appendingPathComponent("wedged", isDirectory: true).path
        let externalPath = "/external/second-wedge"
        let linkedLane = TerminalController.v2WorkingDirectoryProbeLane(linkedPath)
        guard linkedLane == .external else {
            return #expect(Bool(false), "a symlinked component must not enter the local lane")
        }
        guard TerminalController.v2WorkingDirectoryProbeLane(local.path) == .local else {
            return #expect(Bool(false), "the real local fixture must use the reserved local lane")
        }

        let probe = ControlledDirectoryProbe()
        let deadlines = ControlledValidationDeadlines()
        let service = TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 2,
            maximumPendingWaiters: 64,
            laneClassifier: { path in
                path == externalPath
                    ? .external
                    : TerminalController.v2WorkingDirectoryProbeLane(path)
            },
            probe: { path, lane in await probe.run(path: path, lane: lane) },
            sleepUntilDeadline: { _ in await deadlines.suspendUntilFired() }
        )
        let linked = Task { await service.validate(rawValue: linkedPath, isProvided: true) }
        let external = Task { await service.validate(rawValue: externalPath, isProvided: true) }
        await probe.waitForCount(2)
        await deadlines.waitForCount(2)
        await deadlines.fireAll()
        #expect(await linked.value == .timedOut)
        #expect(await external.value == .timedOut)

        let localValidation = Task { await service.validate(rawValue: local.path, isProvided: true) }
        await probe.waitForCount(3)
        #expect(await probe.lane(for: linkedPath) == .external)
        #expect(await probe.lane(for: externalPath) == .external)
        #expect(await probe.lane(for: local.path) == .local)
        await probe.complete(path: local.path, isDirectory: true)
        #expect(await localValidation.value == .valid(local.path))
        await probe.complete(path: linkedPath, isDirectory: true)
        await probe.complete(path: externalPath, isDirectory: true)
    }

    @Test func localProbeDoesNotFollowSymlinkCreatedAfterClassification() async throws {
        let root = Self.nonSymlinkedTemporaryDirectory
            .appendingPathComponent("cmux-symlink-race-\(UUID().uuidString)", isDirectory: true)
        let candidate = root.appendingPathComponent("candidate", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        #expect(TerminalController.v2WorkingDirectoryProbeLane(candidate.path) == .local)

        let deadlines = ControlledValidationDeadlines()
        let lanes = ChosenProbeLaneRecorder()
        let service = TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 2,
            maximumPendingWaiters: 64,
            laneClassifier: { path in
                let lane = TerminalController.v2WorkingDirectoryProbeLane(path)
                _ = path.withCString { Darwin.rmdir($0) }
                _ = target.path.withCString { destination in
                    path.withCString { Darwin.symlink(destination, $0) }
                }
                return lane
            },
            probe: { path, lane in
                await lanes.record(lane)
                return await TerminalController.v2ProbeWorkingDirectory(path, lane: lane)
            },
            sleepUntilDeadline: { _ in await deadlines.suspendUntilFired() }
        )

        let result = await service.validate(rawValue: candidate.path, isProvided: true)

        #expect(result == .invalid)
        #expect(await lanes.values == [.local])
        #expect(TerminalController.v2WorkingDirectoryProbeLane(candidate.path) == .external)
    }

    @Test func concurrentClassificationsAndLocalProbesRemainConsistent() async throws {
        let root = Self.nonSymlinkedTemporaryDirectory
            .appendingPathComponent("cmux-mount-snapshot-\(UUID().uuidString)", isDirectory: true)
        let paths = (0..<8).map {
            root.appendingPathComponent("directory-\($0)", isDirectory: true).path
        }
        defer { try? FileManager.default.removeItem(at: root) }
        for path in paths {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let failureCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<64 {
                for path in paths {
                    group.addTask {
                        let lane = TerminalController.v2WorkingDirectoryProbeLane(path)
                        let isDirectory = await TerminalController.v2ProbeWorkingDirectory(
                            path,
                            lane: .local
                        )
                        return lane != .local || !isDirectory
                    }
                }
            }
            return await group.reduce(into: 0) { failures, failed in
                failures += failed ? 1 : 0
            }
        }

        #expect(failureCount == 0)
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
        #expect(await probe.count == 1)
        await probe.complete(path: "/tmp/shared", isDirectory: true)
        #expect(await remaining.value == .valid("/tmp/shared"))

        let next = Task { await service.validate(rawValue: "/tmp/next", isProvided: true) }
        await probe.waitForCount(2)
        await probe.complete(path: "/tmp/next", isDirectory: true)
        #expect(await next.value == .valid("/tmp/next"))
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
        await probe.complete(path: "/tmp/race", isDirectory: true)

        let next = Task { await service.validate(rawValue: "/tmp/after-race", isProvided: true) }
        await probe.waitForCount(2)
        await probe.complete(path: "/tmp/after-race", isDirectory: true)
        #expect(await next.value == .valid("/tmp/after-race"))
    }

    private static func service(
        probe: ControlledDirectoryProbe,
        deadlines: ControlledValidationDeadlines
    ) -> TerminalController.WorkspaceCreateWorkingDirectoryValidationService {
        TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 2,
            maximumPendingWaiters: 64,
            laneClassifier: { path in path.hasPrefix("/external/") ? .external : .local },
            probe: { path, lane in await probe.run(path: path, lane: lane) },
            sleepUntilDeadline: { _ in await deadlines.suspendUntilFired() }
        )
    }

    private static var nonSymlinkedTemporaryDirectory: URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        if temporaryPath == "/var" || temporaryPath.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private\(temporaryPath)", isDirectory: true)
        }
        if temporaryPath == "/tmp" || temporaryPath.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private\(temporaryPath)", isDirectory: true)
        }
        return URL(fileURLWithPath: temporaryPath, isDirectory: true)
    }

    private static func errorCode(from result: TerminalController.V2CallResult) -> String? {
        guard case let .err(code, _, _) = result else { return nil }
        return code
    }
}

private actor ControlledDirectoryProbe {
    private(set) var count = 0
    private var lanesByPath: [Data: TerminalController.WorkspaceCreateWorkingDirectoryValidationService.ProbeLane] = [:]
    private var activeContinuations: [Data: CheckedContinuation<Bool, Never>] = [:]
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func run(
        path: String,
        lane: TerminalController.WorkspaceCreateWorkingDirectoryValidationService.ProbeLane
    ) async -> Bool {
        count += 1
        let pathID = Data(path.utf8)
        lanesByPath[pathID] = lane
        resumeCountWaiters()
        return await withCheckedContinuation { activeContinuations[pathID] = $0 }
    }

    func lane(
        for path: String
    ) -> TerminalController.WorkspaceCreateWorkingDirectoryValidationService.ProbeLane? {
        lanesByPath[Data(path.utf8)]
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func complete(path: String, isDirectory: Bool) {
        activeContinuations.removeValue(forKey: Data(path.utf8))?.resume(returning: isDirectory)
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { count >= $0.count }
        countWaiters.removeAll { count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}

private actor ChosenProbeLaneRecorder {
    private(set) var values: [TerminalController.WorkspaceCreateWorkingDirectoryValidationService.ProbeLane] = []

    func record(_ lane: TerminalController.WorkspaceCreateWorkingDirectoryValidationService.ProbeLane) {
        values.append(lane)
    }
}

private actor ControlledValidationDeadlines {
    private var totalCount = 0
    private var suspended: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var count: Int { totalCount }

    func suspendUntilFired() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                totalCount += 1
                suspended[id] = continuation
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
        let continuations = Array(suspended.values)
        suspended.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func cancel(id: UUID) {
        suspended.removeValue(forKey: id)?.resume()
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { totalCount >= $0.count }
        countWaiters.removeAll { totalCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}
