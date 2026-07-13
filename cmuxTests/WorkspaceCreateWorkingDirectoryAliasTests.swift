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

    private static func productionClassifierService(
        probe: ImmediateAliasDirectoryProbe,
        deadlines: ControlledAliasValidationDeadlines
    ) -> TerminalController.WorkspaceCreateWorkingDirectoryValidationService {
        TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 2,
            laneClassifier: { TerminalController.v2WorkingDirectoryProbeLane($0) },
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
