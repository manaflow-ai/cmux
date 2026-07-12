import CMUXMobileCore
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileDiffTests {
    @Test func hostAdvertisesDiffCapability() {
        #expect(MobileHostService.mobileHostCapabilities.contains("mobile.diff.v1"))
    }

    @Test func scopedAttachTicketAllowsDiffOnlyForItsWorkspace() throws {
        let ticket = try scopedAttachTicket(workspaceID: "workspace")
        let allowed = MobileHostRPCRequest(
            id: "mobile-diff",
            method: "mobile.diff.load",
            params: ["workspace_id": "workspace"],
            auth: MobileHostRPCAuth(attachToken: ticket.authToken, stackAccessToken: nil)
        )
        let rejected = MobileHostRPCRequest(
            id: "mobile-diff-other",
            method: "mobile.diff.load",
            params: ["workspace_id": "other-workspace"],
            auth: MobileHostRPCAuth(attachToken: ticket.authToken, stackAccessToken: nil)
        )

        #expect(MobileHostService.ticketAuthorizationError(ticket: ticket, request: allowed) == nil)
        #expect(MobileHostService.ticketAuthorizationError(ticket: ticket, request: rejected)?.code == "forbidden")
    }

    @Test func loaderIncludesTrackedAndUntrackedChanges() async throws {
        let repository = try makeRepository(named: "working-tree")
        defer { try? FileManager.default.removeItem(at: repository) }

        try Data("before\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit([
            "-c", "user.name=cmux Tests",
            "-c", "user.email=cmux-tests@example.com",
            "commit", "--quiet", "-m", "fixture",
        ], at: repository)
        try Data("after\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: repository.appendingPathComponent("untracked.txt"))

        let document = try await MobileWorkingTreeDiffLoader().load(directory: repository.path, title: "Fixture")
        let patch = try #require(document["patch"] as? String)
        #expect(document["repository_root"] as? String == repository.path)
        #expect(document["title"] as? String == "Fixture")
        #expect(patch.contains("diff --git a/tracked.txt b/tracked.txt"))
        #expect(patch.contains("diff --git a/untracked.txt b/untracked.txt"))
        #expect(patch.contains("+after"))
        #expect(patch.contains("+new"))
    }

    @Test func loaderIgnoresInheritedRepositorySelectionEnvironment() async throws {
        let selectedRepository = try makeRepository(named: "selected-environment")
        let redirectedRepository = try makeRepository(named: "redirected-environment")
        defer {
            try? FileManager.default.removeItem(at: selectedRepository)
            try? FileManager.default.removeItem(at: redirectedRepository)
        }
        try Data("selected\n".utf8).write(to: selectedRepository.appendingPathComponent("selected.txt"))
        try Data("redirected\n".utf8).write(to: redirectedRepository.appendingPathComponent("redirected.txt"))
        let nestedWorkspace = selectedRepository.appendingPathComponent("nested/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedWorkspace, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_DIR"] = redirectedRepository.appendingPathComponent(".git").path
        environment["GIT_WORK_TREE"] = redirectedRepository.path
        environment["GIT_CEILING_DIRECTORIES"] = selectedRepository.appendingPathComponent("nested").path

        let document = try await MobileWorkingTreeDiffLoader(environment: environment)
            .load(directory: nestedWorkspace.path, title: "Fixture")
        let patch = try #require(document["patch"] as? String)

        #expect(document["repository_root"] as? String == selectedRepository.path)
        #expect(patch.contains("selected.txt"))
        #expect(!patch.contains("redirected.txt"))
    }

    @Test func loaderIncludesStagedFilesBeforeFirstCommit() async throws {
        let repository = try makeRepository(named: "unborn")
        defer { try? FileManager.default.removeItem(at: repository) }

        try Data("staged\n".utf8).write(to: repository.appendingPathComponent("staged.txt"))
        try runGit(["add", "staged.txt"], at: repository)
        try Data("edited after staging\n".utf8).write(to: repository.appendingPathComponent("staged.txt"))

        let document = try await MobileWorkingTreeDiffLoader().load(directory: repository.path, title: "Fixture")
        let patch = try #require(document["patch"] as? String)
        #expect(patch.contains("diff --git a/staged.txt b/staged.txt"))
        #expect(patch.components(separatedBy: "diff --git a/staged.txt b/staged.txt").count == 2)
        #expect(patch.contains("+edited after staging"))
        #expect(!patch.contains("+staged"))
    }

    @Test func loaderIncludesFilesInUnbornSHA256Repository() async throws {
        let repository = try makeRepository(named: "unborn-sha256", objectFormat: "sha256")
        defer { try? FileManager.default.removeItem(at: repository) }
        try Data("sha256\n".utf8).write(to: repository.appendingPathComponent("new.txt"))
        try runGit(["add", "new.txt"], at: repository)

        let document = try await MobileWorkingTreeDiffLoader().load(directory: repository.path, title: "Fixture")
        let patch = try #require(document["patch"] as? String)
        #expect(patch.contains("diff --git a/new.txt b/new.txt"))
        #expect(patch.contains("+sha256"))
    }

    @Test func loaderRejectsTruncatedUntrackedFileLists() async throws {
        let repository = try makeRepository(named: "many-files")
        defer { try? FileManager.default.removeItem(at: repository) }
        for index in 0...200 {
            try Data().write(to: repository.appendingPathComponent("untracked-\(index).txt"))
        }

        do {
            _ = try await MobileWorkingTreeDiffLoader().load(directory: repository.path, title: "Fixture")
            Issue.record("Expected too many untracked files to fail")
        } catch let error as MobileWorkingTreeDiffLoadError {
            #expect(error.code == "too_many_files")
        }
    }

    @Test func loaderStopsOversizedPatchCapture() async throws {
        let repository = try makeRepository(named: "oversized")
        defer { try? FileManager.default.removeItem(at: repository) }
        try Data(repeating: 65, count: 7 * 1024 * 1024)
            .write(to: repository.appendingPathComponent("oversized.txt"))

        do {
            _ = try await MobileWorkingTreeDiffLoader().load(directory: repository.path, title: "Fixture")
            Issue.record("Expected oversized patch to fail")
        } catch let error as MobileWorkingTreeDiffLoadError {
            #expect(error.code == "too_large")
        }
    }

    @Test func loaderRejectsPatchWhoseJSONExpansionExceedsFrameLimit() async throws {
        let repository = try makeRepository(named: "json-expanded")
        defer { try? FileManager.default.removeItem(at: repository) }
        try Data(repeating: 92, count: 4_200_000)
            .write(to: repository.appendingPathComponent("backslashes.txt"))

        do {
            _ = try await MobileWorkingTreeDiffLoader().load(directory: repository.path, title: "Fixture")
            Issue.record("Expected JSON-expanded patch to fail")
        } catch let error as MobileWorkingTreeDiffLoadError {
            #expect(error.code == "too_large")
        }
    }

    @Test func loaderSkipsUntrackedFIFOs() async throws {
        let repository = try makeRepository(named: "fifo")
        defer { try? FileManager.default.removeItem(at: repository) }
        let fifoPath = repository.appendingPathComponent("blocking-pipe").path
        #expect(mkfifo(fifoPath, S_IRUSR | S_IWUSR) == 0)

        let document = try await MobileWorkingTreeDiffLoader().load(directory: repository.path, title: "Fixture")
        let patch = try #require(document["patch"] as? String)
        #expect(!patch.contains("blocking-pipe"))
    }

    @Test func processCancellationLatchesBeforeLaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let cancellation = MobileDiffProcessCancellation(process: process)

        cancellation.cancel()

        #expect(!cancellation.beginLaunch())
    }

    private func makeRepository(named name: String, objectFormat: String? = nil) throws -> URL {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mobile-diff-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        var arguments = ["init", "--quiet"]
        if let objectFormat { arguments.append("--object-format=\(objectFormat)") }
        try runGit(arguments, at: repository)
        return repository
    }

    private func scopedAttachTicket(workspaceID: String) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        return try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: "ticket-secret"
        )
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
