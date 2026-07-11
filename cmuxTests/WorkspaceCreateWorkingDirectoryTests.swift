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

        let first = TerminalController.shared.v2WorkspaceCreate(params: params, tabManager: manager)
        let retry = TerminalController.shared.v2WorkspaceCreate(params: params, tabManager: manager)
        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let createdPanels = created.panels.values.compactMap { $0 as? TerminalPanel }

        #expect(manager.tabs.count == initialWorkspaceIDs.count + 1)
        #expect(createdPanels.count == 1)
        #expect(createdPanels.first?.surface.debugInitialCommand() == "codex \"${CMUX_TASK_PROMPT}\"")
        #expect(Self.workspaceID(from: first) == created.id)
        #expect(Self.workspaceID(from: retry) == created.id)
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

        let result = TerminalController.shared.v2WorkspaceCreate(params: [
            "operation_id": operationID.uuidString,
            "initial_command": "must-not-launch",
        ], tabManager: manager)

        #expect(Set(manager.tabs.map(\.id)) == initialIDs)
        #expect(restored.id != sourceWorkspace.id)
        #expect(restored.taskCreateOperationID == operationID)
        #expect(restored.panels.values.compactMap { $0 as? TerminalPanel }
            .allSatisfy { $0.surface.debugInitialCommand() != "must-not-launch" })
        #expect(Self.workspaceID(from: result) == restored.id)
    }

    @Test func composerWorkingDirectoryRequiresAbsoluteExistingDirectory() throws {
        let manager = TabManager()
        let baselineCount = manager.tabs.count
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-task-dir-\(UUID().uuidString)").path
        let regularFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-file-\(UUID().uuidString)")
        try Data().write(to: regularFile)
        defer { try? FileManager.default.removeItem(at: regularFile) }

        for invalidPath in ["relative/path", missing, regularFile.path] {
            let result = TerminalController.shared.v2WorkspaceCreate(params: [
                "working_directory": invalidPath,
            ], tabManager: manager)
            #expect(Self.errorCode(from: result) == "invalid_params")
        }
        #expect(manager.tabs.count == baselineCount)
    }

    @Test func composerWorkingDirectoryAcceptsExistingDirectoryAndLegacyCwdRemainsCompatible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TabManager()

        let composerResult = TerminalController.shared.v2WorkspaceCreate(params: [
            "working_directory": directory.path,
        ], tabManager: manager)
        let legacyResult = TerminalController.shared.v2WorkspaceCreate(params: [
            "cwd": "relative/legacy-path",
        ], tabManager: manager)

        #expect(Self.workspaceID(from: composerResult) != nil)
        #expect(Self.workspaceID(from: legacyResult) != nil)
    }

    @Test func idempotencyCacheEvictsSuccessfulResultsInFIFOOrder() {
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(capacity: 2)
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

    private static func errorCode(from result: TerminalController.V2CallResult) -> String? {
        guard case .err(let code, _, _) = result else { return nil }
        return code
    }
}
