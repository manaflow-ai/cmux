import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCreateWorkingDirectoryTests {
    @Test func expandsHomeDirectory() {
        #expect(TerminalController.v2ExpandedWorkingDirectory("~") == NSHomeDirectory())
    }

    @Test func expandsHomeSubdirectory() {
        #expect(TerminalController.v2ExpandedWorkingDirectory("~/sub/dir") == "\(NSHomeDirectory())/sub/dir")
    }

    @Test func absolutePathPassesThrough() {
        #expect(TerminalController.v2ExpandedWorkingDirectory("/tmp/project") == "/tmp/project")
    }

    @Test func nilAndEmptyReturnNil() {
        #expect(TerminalController.v2ExpandedWorkingDirectory(nil) == nil)
        #expect(TerminalController.v2ExpandedWorkingDirectory(" \n ") == nil)
    }

    @Test func sameOperationIDCreatesOneWorkspaceWithOneInitialAgentCommand() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))
        let operationID = UUID()
        let params: [String: Any] = [
            "operation_id": operationID.uuidString,
            "title": "Idempotent Task",
            "initial_command": "codex \"${CMUX_TASK_PROMPT}\"",
            "initial_env": ["CMUX_TASK_PROMPT": "Fix the composer"],
        ]
        let cache = Self.makeCache()

        let first = TerminalController.shared.v2WorkspaceCreate(
            params: params,
            tabManager: manager,
            idempotencyCache: cache
        )
        let retry = TerminalController.shared.v2WorkspaceCreate(
            params: params,
            tabManager: manager,
            idempotencyCache: cache
        )
        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let createdPanels = created.panels.values.compactMap { $0 as? TerminalPanel }

        #expect(manager.tabs.count == initialWorkspaceIDs.count + 1)
        #expect(createdPanels.count == 1)
        #expect(createdPanels.first?.surface.debugInitialCommand() == "codex \"${CMUX_TASK_PROMPT}\"")
        #expect(Self.workspaceID(from: first) == created.id)
        #expect(Self.workspaceID(from: retry) == created.id)
    }

    @Test func initialAgentCommandPreservesSurroundingWhitespaceThroughTerminalStartup() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))
        let initialCommand = " \nprintf '  preserved  '\n "

        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "initial_command": initialCommand,
        ], tabManager: manager)

        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        #expect(panel.surface.debugInitialCommand() == initialCommand)
    }

    @Test func whitespaceOnlyInitialAgentCommandStartsPlainShell() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))

        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "initial_command": " \n\t ",
        ], tabManager: manager)

        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        #expect(panel.surface.debugInitialCommand() == nil)
    }

    @Test func initialEnvironmentRejectsCStringTruncationAndPreservesEmptyPrompt() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))

        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "initial_env": [
                "CMUX_SOCKET_PATH\u{0}x": "spoofed",
                "BAD=KEY": "value",
                "NUL_VALUE": "a\u{0}b",
                "CMUX_TASK_PROMPT": "",
                "GOOD": "value",
            ],
        ], tabManager: manager)

        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        #expect(panel.surface.respawnInitialEnvironmentOverrides == [
            "CMUX_TASK_PROMPT": "",
            "GOOD": "value",
        ])
    }

    @Test func taskCreateOperationIDSurvivesSnapshotRestoreWithFreshRuntimeWorkspaceID() throws {
        let operationID = UUID()
        let original = Workspace()
        original.taskCreateOperationID = operationID

        let snapshot = original.sessionSnapshot(includeScrollback: false)
        let restored = Workspace()
        _ = restored.restoreSessionSnapshot(snapshot)

        #expect(snapshot.taskCreateOperationID == operationID)
        #expect(restored.taskCreateOperationID == operationID)
        #expect(restored.id != original.id)
    }

    @Test func retryFindsRestoredWorkspaceBeforeFreshCacheWithoutLaunchingCommand() throws {
        let operationID = UUID()
        let sourceManager = TabManager()
        let sourceWorkspace = try #require(sourceManager.selectedWorkspace)
        sourceWorkspace.taskCreateOperationID = operationID
        let snapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        let manager = TabManager()
        manager.restoreSessionSnapshot(snapshot)
        let restored = try #require(manager.selectedWorkspace)
        let initialIDs = Set(manager.tabs.map(\.id))
        let cache = Self.makeCache()

        let result = TerminalController.shared.v2WorkspaceCreate(params: [
            "operation_id": operationID.uuidString,
            "initial_command": "must-not-launch",
        ], tabManager: manager, idempotencyCache: cache)

        #expect(Set(manager.tabs.map(\.id)) == initialIDs)
        #expect(restored.id != sourceWorkspace.id)
        #expect(restored.taskCreateOperationID == operationID)
        #expect(restored.panels.values.compactMap { $0 as? TerminalPanel }
            .allSatisfy { $0.surface.debugInitialCommand() != "must-not-launch" })
        #expect(Self.workspaceID(from: result) == restored.id)
    }

    @Test func retryFromAnotherManagerReturnsOwningWindowWithoutCreatingWorkspaceOrCommand() throws {
        let operationID = UUID()
        let currentManager = TabManager()
        let ownerManager = TabManager()
        let ownerWindowID = UUID()
        let ownerWorkspace = try #require(ownerManager.selectedWorkspace)
        ownerWorkspace.taskCreateOperationID = operationID
        let cache = Self.makeCache()
        cache.record(
            operationID: operationID,
            workspaceID: ownerWorkspace.id
        )
        let currentIDs = Set(currentManager.tabs.map(\.id))
        let ownerIDs = Set(ownerManager.tabs.map(\.id))

        let result = TerminalController.shared.v2WorkspaceCreate(
            params: [
                "operation_id": operationID.uuidString,
                "initial_command": "must-not-launch",
            ],
            tabManager: currentManager,
            taskCreateCandidates: [
                .init(tabManager: currentManager, windowID: UUID()),
                .init(tabManager: ownerManager, windowID: ownerWindowID),
            ],
            idempotencyCache: cache
        )

        #expect(Set(currentManager.tabs.map(\.id)) == currentIDs)
        #expect(Set(ownerManager.tabs.map(\.id)) == ownerIDs)
        #expect(ownerWorkspace.panels.values.compactMap { $0 as? TerminalPanel }
            .allSatisfy { $0.surface.debugInitialCommand() != "must-not-launch" })
        #expect(Self.workspaceID(from: result) == ownerWorkspace.id)
        #expect(Self.windowID(from: result) == ownerWindowID)
    }

    @Test func synchronousControlCreateKeepsWorkingDirectoryAsCwdWithoutFilesystemValidation() throws {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let requestedDirectory = "/missing/control-cwd-\(UUID().uuidString)"

        let result = TerminalController.shared.v2WorkspaceCreate(params: [
            "working_directory": requestedDirectory,
        ], tabManager: manager)
        let createdID = try #require(Self.workspaceID(from: result))
        let created = try #require(manager.tabs.first { $0.id == createdID })

        #expect(Set(manager.tabs.map(\.id)).subtracting(baselineIDs) == [createdID])
        #expect(created.currentDirectory == requestedDirectory)
    }

    @Test func legacyCwdRemainsCompatible() {
        let manager = TabManager()

        let legacyResult = TerminalController.shared.v2WorkspaceCreate(params: [
            "cwd": "relative/legacy-path",
        ], tabManager: manager)

        #expect(Self.workspaceID(from: legacyResult) != nil)
    }

    @Test func mobileHandlerAcceptsExistingWorkingDirectory() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let baselineIDs = Set(manager.tabs.map(\.id))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-task-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "mobile-task-valid-directory",
                method: "workspace.create",
                params: ["working_directory": directory.path],
                auth: nil
            )
        )

        guard case .ok = result else {
            return #expect(Bool(false), "existing absolute directory should be accepted")
        }
        #expect(Set(manager.tabs.map(\.id)).subtracting(baselineIDs).count == 1)
    }

    @Test func mobileHandlerRejectsRelativeFileAndMissingWorkingDirectories() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let baselineIDs = Set(manager.tabs.map(\.id))
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-mobile-task-dir-\(UUID().uuidString)").path
        let regularFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-task-file-\(UUID().uuidString)")
        try Data().write(to: regularFile)
        defer { try? FileManager.default.removeItem(at: regularFile) }

        for invalidPath in ["relative/path", regularFile.path, missing] {
            let result = await TerminalController.shared.mobileHostHandleRPC(
                MobileHostRPCRequest(
                    id: "mobile-task-invalid-directory",
                    method: "workspace.create",
                    params: ["working_directory": invalidPath],
                    auth: nil
                )
            )
            guard case let .failure(error) = result else {
                return #expect(Bool(false), "invalid directory should be rejected")
            }
            #expect(error.code == "invalid_working_directory")
            #expect(error.message == "working_directory must be an absolute existing directory")
            #expect((error.data as? [String: String])?["field"] == "working_directory")
        }
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
    }

    @Test func cancelledMobileValidationCreatesNoWorkspace() async {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let gate = WorkspaceCreateValidationGate()
        let create = Task { @MainActor in
            await TerminalController.shared.v2MobileWorkspaceCreate(
                params: ["working_directory": "/tmp"],
                workingDirectoryValidator: { rawValue, isProvided in
                    await gate.validate(rawValue: rawValue, isProvided: isProvided)
                },
                tabManager: manager
            )
        }
        await gate.waitUntilValidationStarts()

        create.cancel()
        await gate.release()
        _ = await create.value

        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
    }

    @Test func initialAndRetryMobileResponsesBothDecodeAsWorkspaceLists() async throws {
        let manager = TabManager()
        let operationID = UUID()
        let params: [String: Any] = [
            "operation_id": operationID.uuidString,
            "title": "Retry Shape",
        ]
        let cache = Self.makeCache()

        let initial = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: params,
            tabManager: manager,
            idempotencyCache: cache
        )
        let retry = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: params,
            tabManager: manager,
            idempotencyCache: cache
        )
        let initialResponse = try Self.decodeMobileWorkspaceList(initial)
        let retryResponse = try Self.decodeMobileWorkspaceList(retry)

        #expect(initialResponse.createdWorkspaceID != nil)
        #expect(retryResponse.createdWorkspaceID == initialResponse.createdWorkspaceID)
        #expect(retryResponse.workspaces.map(\.id) == initialResponse.workspaces.map(\.id))
    }

    @Test func concurrentMobileRequestsWithSameOperationCreateExactlyOnce() async throws {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let operationID = UUID()
        let gate = ConcurrentWorkspaceCreateValidationGate()
        let params: [String: Any] = [
            "operation_id": operationID.uuidString,
            "working_directory": "/tmp",
            "initial_command": "must-run-once",
        ]
        let cache = Self.makeCache()
        let first = Task { @MainActor in
            await TerminalController.shared.v2MobileWorkspaceCreate(
                params: params,
                workingDirectoryValidator: { rawValue, _ in await gate.validate(rawValue) },
                tabManager: manager,
                idempotencyCache: cache
            )
        }
        let second = Task { @MainActor in
            await TerminalController.shared.v2MobileWorkspaceCreate(
                params: params,
                workingDirectoryValidator: { rawValue, _ in await gate.validate(rawValue) },
                tabManager: manager,
                idempotencyCache: cache
            )
        }
        await gate.waitForStarts(2)

        await gate.releaseAll()
        let concurrentResults = [await first.value, await second.value]
        let successfulResponses = concurrentResults.compactMap { try? Self.decodeMobileWorkspaceList($0) }
        let completedErrors = concurrentResults.compactMap(Self.errorCode(from:))
        let created = try #require(manager.tabs.first { !baselineIDs.contains($0.id) })
        let taskPanel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        let initialCommands = created.panels.values.compactMap { ($0 as? TerminalPanel)?.surface.debugInitialCommand() }
        let startupDeadline = ContinuousClock.now + .seconds(1)
        while taskPanel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0,
              ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attemptsAfterCreation = taskPanel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting()

        #expect(Set(manager.tabs.map(\.id)).subtracting(baselineIDs).count == 1)
        #expect(initialCommands.filter { $0 == "must-run-once" }.count == 1)
        #expect(attemptsAfterCreation > 0)
        #expect(!successfulResponses.isEmpty)
        #expect(successfulResponses.count + completedErrors.count == concurrentResults.count)
        #expect(successfulResponses.allSatisfy { $0.createdWorkspaceID == created.id.uuidString })
        #expect(completedErrors.allSatisfy { $0 == "already_completed" })

        let retry = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: params,
            tabManager: manager,
            idempotencyCache: cache
        )
        let retryResponse = try? Self.decodeMobileWorkspaceList(retry)
        let retryError = Self.errorCode(from: retry)

        #expect(
            retryResponse?.createdWorkspaceID == created.id.uuidString
                || retryError == "already_completed"
        )
        #expect(taskPanel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == attemptsAfterCreation)
    }

    @Test func emptyMobileWorkspaceCreateStaysMetadataOnly() async throws {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))

        let response = try Self.decodeMobileWorkspaceList(
            await TerminalController.shared.v2MobileWorkspaceCreate(
                params: ["title": "Lazy Mobile Workspace"],
                tabManager: manager,
                idempotencyCache: Self.makeCache()
            )
        )
        let created = try #require(manager.tabs.first { !baselineIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)

        #expect(response.createdWorkspaceID == created.id.uuidString)
        #expect(!panel.surface.debugBackgroundSurfaceStartQueuedForTesting())
        #expect(panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
    }

    @Test func idempotencyCacheEvictsSuccessfulResultsInFIFOOrder() {
        let cache = Self.makeCache(capacity: 2)
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let thirdWorkspaceID = UUID()

        cache.record(operationID: firstID, workspaceID: firstWorkspaceID)
        cache.record(operationID: secondID, workspaceID: secondWorkspaceID)
        #expect(cache.workspaceID(for: firstID) == firstWorkspaceID)
        cache.record(operationID: thirdID, workspaceID: thirdWorkspaceID)

        #expect(cache.workspaceID(for: firstID) == nil)
        #expect(cache.workspaceID(for: secondID) == secondWorkspaceID)
        #expect(cache.workspaceID(for: thirdID) == thirdWorkspaceID)
    }

    private static func workspaceID(from result: TerminalController.V2CallResult) -> UUID? {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let rawID = payload["workspace_id"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }

    private static func makeCache(capacity: Int = 256) -> TerminalController.WorkspaceCreateIdempotencyCache {
        TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: capacity,
            persistence: InMemoryWorkspaceCreateIdempotencyStore()
        )
    }

    private static func errorCode(from result: TerminalController.V2CallResult) -> String? {
        guard case .err(let code, _, _) = result else { return nil }
        return code
    }

    private static func windowID(from result: TerminalController.V2CallResult) -> UUID? {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let rawID = payload["window_id"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }

    private static func decodeMobileWorkspaceList(
        _ result: TerminalController.V2CallResult
    ) throws -> DecodedMobileWorkspaceListResponse {
        guard case let .ok(payload) = result else {
            throw MobileWorkspaceListDecodeError.notSuccess
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(DecodedMobileWorkspaceListResponse.self, from: data)
    }
}

private struct DecodedMobileWorkspaceListResponse: Decodable {
    struct Workspace: Decodable {
        let id: String
    }

    let workspaces: [Workspace]
    let createdWorkspaceID: String?

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case createdWorkspaceID = "created_workspace_id"
    }
}

private enum MobileWorkspaceListDecodeError: Error {
    case notSuccess
}

private actor WorkspaceCreateValidationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func validate(
        rawValue: String?,
        isProvided: Bool
    ) async -> TerminalController.WorkspaceCreateWorkingDirectoryValidation {
        started = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return .valid(rawValue ?? "/tmp")
    }

    func waitUntilValidationStarts() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ConcurrentWorkspaceCreateValidationGate {
    private var starts = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func validate(_ rawValue: String?) async -> TerminalController.WorkspaceCreateWorkingDirectoryValidation {
        starts += 1
        resumeStartWaiters()
        await withCheckedContinuation { releaseWaiters.append($0) }
        return .valid(rawValue ?? "/tmp")
    }

    func waitForStarts(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func releaseAll() {
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { starts >= $0.count }
        startWaiters.removeAll { starts >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}
