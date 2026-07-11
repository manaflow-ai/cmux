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

    @Test func idempotencyCacheEvictsSuccessfulResultsInFIFOOrder() {
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(capacity: 2)
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        var runCounts: [UUID: Int] = [:]

        func resolve(_ id: UUID) {
            _ = cache.resolve(operationID: id) {
                runCounts[id, default: 0] += 1
                return .ok(["id": id.uuidString])
            }
        }

        resolve(firstID)
        resolve(secondID)
        resolve(firstID)
        resolve(thirdID)
        resolve(firstID)

        #expect(runCounts[firstID] == 2)
        #expect(runCounts[secondID] == 1)
        #expect(runCounts[thirdID] == 1)
    }

    @Test func failedOperationIsRetriedInsteadOfCached() {
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(capacity: 2)
        let operationID = UUID()
        var runCount = 0

        for _ in 0..<2 {
            _ = cache.resolve(operationID: operationID) {
                runCount += 1
                return .err(code: "unavailable", message: "try again", data: nil)
            }
        }

        #expect(runCount == 2)
    }

    private static func workspaceID(from result: TerminalController.V2CallResult) -> UUID? {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let rawID = payload["workspace_id"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }
}
