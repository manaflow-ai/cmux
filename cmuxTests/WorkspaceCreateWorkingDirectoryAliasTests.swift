import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCreateWorkingDirectoryAliasTests {
    @Test func missingDotDotExistingPathIsRejectedBeforeProbe() async throws {
        let root = Self.nonSymlinkedTemporaryDirectory
            .appendingPathComponent("cmux-dot-component-\(UUID().uuidString)", isDirectory: true)
        let existing = root.appendingPathComponent("existing", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let requestedPath = root.path + "/missing/../existing"
        let probe = ImmediateAliasDirectoryProbe()
        let deadlines = ControlledAliasValidationDeadlines()
        let service = Self.productionClassifierService(probe: probe, deadlines: deadlines)

        let result = await service.validate(rawValue: requestedPath, isProvided: true)

        #expect(result == .invalid)
        #expect(await probe.paths.isEmpty)
    }

    @Test func symlinkDotDotDirectoryIsRejectedWithoutUsingLocalLane() async throws {
        let root = Self.nonSymlinkedTemporaryDirectory
            .appendingPathComponent("cmux-symlink-dot-component-\(UUID().uuidString)", isDirectory: true)
        let localDirectory = root.appendingPathComponent("directory", isDirectory: true)
        let redirectedParent = root.appendingPathComponent("redirected", isDirectory: true)
        let linkTarget = redirectedParent.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linkTarget)
        let requestedPath = link.path + "/../directory"
        let probe = ImmediateAliasDirectoryProbe()
        let deadlines = ControlledAliasValidationDeadlines()
        let service = Self.productionClassifierService(probe: probe, deadlines: deadlines)

        let result = await service.validate(rawValue: requestedPath, isProvided: true)

        #expect(TerminalController.v2WorkingDirectoryProbeLane(requestedPath) == .external)
        #expect(result == .invalid)
        #expect(await probe.paths.isEmpty)
    }

    @Test func repeatedAndTrailingSeparatorsPreserveExactValidatedPath() async throws {
        let root = Self.nonSymlinkedTemporaryDirectory
            .appendingPathComponent("cmux-repeated-separator-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requestedPath = root.path + "//directory//"
        let probe = ImmediateAliasDirectoryProbe()
        let deadlines = ControlledAliasValidationDeadlines()
        let service = Self.productionClassifierService(probe: probe, deadlines: deadlines)

        let result = await service.validate(rawValue: requestedPath, isProvided: true)

        #expect(result == .valid(requestedPath))
        #expect(await probe.paths == [requestedPath])
    }

    @Test func caseFoldedMountMatchingIsConservativelyExternal() {
        let root = TerminalController.WorkspaceCreateMountEntry(path: "/", isLocal: true)
        let externalVolume = TerminalController.WorkspaceCreateMountEntry(
            path: "/Volumes/External",
            isLocal: false
        )

        #expect(TerminalController.v2WorkingDirectoryMountIsLocal(
            path: "/volumes/external/project",
            mounts: [root, externalVolume]
        ) == false)

        let local = TerminalController.WorkspaceCreateMountEntry(
            path: "/Volumes/Shared",
            isLocal: true
        )
        let externalShared = TerminalController.WorkspaceCreateMountEntry(
            path: "/volumes/shared",
            isLocal: false
        )
        for mounts in [[local, externalShared], [externalShared, local]] {
            #expect(TerminalController.v2WorkingDirectoryMountIsLocal(
                path: "/VOLUMES/SHARED/project",
                mounts: mounts
            ) == false)
        }
    }

    @Test func mobileCreateAcceptsExistingLegacyCwdAlias() async throws {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-task-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["cwd": directory.path],
            tabManager: manager
        )

        let created = try #require(manager.tabs.first { !baselineIDs.contains($0.id) })
        #expect(Self.errorCode(from: result) == nil)
        #expect(created.currentDirectory == directory.path)
    }

    @Test func mobileCreateRejectsDotComponentInLegacyCwdAlias() async {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))

        let result = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["cwd": "/tmp/../tmp"],
            tabManager: manager
        )

        #expect(Self.errorCode(from: result) == "invalid_working_directory")
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
    }

    @Test func mobileCreateRoutesLegacyCwdSymlinkThroughValidator() async throws {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-task-cwd-link-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["cwd": link.path],
            workingDirectoryValidator: { rawValue, isProvided in
                guard isProvided, rawValue == link.path else { return .notProvided }
                return .invalid
            },
            tabManager: manager
        )

        #expect(Self.errorCode(from: result) == "invalid_working_directory")
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
    }

    @Test func mobileCreatePropagatesLegacyCwdValidationTimeout() async {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let cwd = "/external/wedged-cwd"

        let result = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["cwd": cwd],
            workingDirectoryValidator: { rawValue, isProvided in
                guard isProvided, rawValue == cwd else { return .notProvided }
                return .timedOut
            },
            tabManager: manager
        )

        #expect(Self.errorCode(from: result) == "request_timeout")
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
    }

    @Test func mobileCreateRejectsBusyWorkingDirectoryValidationWithoutCreatingWorkspace() async {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))

        let result = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["working_directory": "/tmp/overloaded"],
            workingDirectoryValidator: { _, _ in .busy },
            tabManager: manager
        )

        #expect(Self.errorCode(from: result) == "busy")
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
    }

    @Test func mobileWorkingDirectoryTakesPrecedenceOverInvalidCwdAlias() async throws {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let preferred = "/validated/preferred"

        let result = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: [
                "working_directory": preferred,
                "cwd": 42,
            ],
            workingDirectoryValidator: { rawValue, isProvided in
                guard isProvided, rawValue == preferred else { return .invalid }
                return .valid(preferred)
            },
            tabManager: manager
        )

        let created = try #require(manager.tabs.first { !baselineIDs.contains($0.id) })
        #expect(Self.errorCode(from: result) == nil)
        #expect(created.currentDirectory == preferred)
    }

    @Test func mobileCreatePreservesNonStringCwdTypeError() async {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))

        let result = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["cwd": 42],
            tabManager: manager
        )

        #expect(Self.errorCode(from: result) == "invalid_params")
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
    }

    private static func productionClassifierService(
        probe: ImmediateAliasDirectoryProbe,
        deadlines: ControlledAliasValidationDeadlines
    ) -> TerminalController.WorkspaceCreateWorkingDirectoryValidationService {
        TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 2,
            maximumPendingWaiters: 64,
            laneClassifier: { TerminalController.v2WorkingDirectoryProbeLane($0) },
            probe: { path, lane in await probe.run(path: path, lane: lane) },
            sleepUntilDeadline: { _ in await deadlines.suspendUntilFired() }
        )
    }

    private static func errorCode(from result: TerminalController.V2CallResult) -> String? {
        guard case let .err(code, _, _) = result else { return nil }
        return code
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
}

private actor ImmediateAliasDirectoryProbe {
    private(set) var paths: [String] = []

    func run(
        path: String,
        lane _: TerminalController.WorkspaceCreateWorkingDirectoryValidationService.ProbeLane
    ) -> Bool {
        paths.append(path)
        return true
    }
}

private actor ControlledAliasValidationDeadlines {
    private var suspended: [UUID: CheckedContinuation<Void, Never>] = [:]

    func suspendUntilFired() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { suspended[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        suspended.removeValue(forKey: id)?.resume()
    }
}
