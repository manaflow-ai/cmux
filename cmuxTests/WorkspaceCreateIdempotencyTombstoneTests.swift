import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCreateIdempotencyTombstoneTests {
    @Test func mobileRetryAfterClosedWorkspaceReturnsCurrentListWithoutCreatingOrLaunching() async throws {
        let defaults = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.defaultsSuiteName(defaults)) }
        let cache = Self.cache(defaults: defaults)
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let operationID = UUID()

        let initial = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["operation_id": operationID.uuidString],
            tabManager: manager,
            idempotencyCache: cache
        )
        let createdID = try #require(UUID(uuidString: try Self.decode(initial).createdWorkspaceID ?? ""))
        #expect(cache.completionProvenance(for: operationID) == .currentProcess)
        manager.closeWorkspace(try #require(manager.tabs.first { $0.id == createdID }))

        let retry = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: [
                "operation_id": operationID.uuidString,
                "initial_command": "must-not-launch",
            ],
            tabManager: manager,
            idempotencyCache: cache
        )
        let decoded = try Self.decode(retry)

        #expect(decoded.createdWorkspaceID == nil)
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
        #expect(Self.containsInitialCommand("must-not-launch", in: manager) == false)
    }

    @Test func crashBeforeWorkspaceSnapshotDoesNotLetRestoredTombstoneLoseTask() async throws {
        let defaults = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.defaultsSuiteName(defaults)) }
        let operationID = UUID()
        let manager = TabManager()
        let initialCache = Self.cache(defaults: defaults)

        let initial = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["operation_id": operationID.uuidString],
            tabManager: manager,
            idempotencyCache: initialCache
        )
        let createdID = try #require(UUID(uuidString: try Self.decode(initial).createdWorkspaceID ?? ""))
        manager.closeWorkspace(try #require(manager.tabs.first { $0.id == createdID }))

        let restoredCache = Self.cache(defaults: defaults)
        #expect(restoredCache.completionProvenance(for: operationID) == .restored)
        let baselineIDs = Set(manager.tabs.map(\.id))
        let retry = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: [
                "operation_id": operationID.uuidString,
                "initial_command": "must-not-launch-after-restart",
            ],
            tabManager: manager,
            idempotencyCache: restoredCache
        )

        let retriedID = try #require(try Self.decode(retry).createdWorkspaceID)
        #expect(UUID(uuidString: retriedID).map { !baselineIDs.contains($0) } == true)
        #expect(Set(manager.tabs.map(\.id)).subtracting(baselineIDs).count == 1)
        #expect(Self.containsInitialCommand("must-not-launch-after-restart", in: manager))
        #expect(restoredCache.completionProvenance(for: operationID) == .currentProcess)
    }

    @Test func synchronousRetryAfterClosedWorkspaceReturnsStableCompletedError() throws {
        let defaults = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.defaultsSuiteName(defaults)) }
        let cache = Self.cache(defaults: defaults)
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let operationID = UUID()

        let initial = TerminalController.shared.v2WorkspaceCreate(
            params: ["operation_id": operationID.uuidString],
            tabManager: manager,
            idempotencyCache: cache
        )
        let createdID = try #require(Self.workspaceID(initial))
        manager.closeWorkspace(try #require(manager.tabs.first { $0.id == createdID }))
        let retry = TerminalController.shared.v2WorkspaceCreate(
            params: [
                "operation_id": operationID.uuidString,
                "initial_command": "must-not-launch",
            ],
            tabManager: manager,
            idempotencyCache: cache
        )

        #expect(Self.errorCode(retry) == "already_completed")
        #expect(Set(manager.tabs.map(\.id)) == baselineIDs)
        #expect(Self.containsInitialCommand("must-not-launch", in: manager) == false)
    }

    @Test func restoredWorkspaceReconcilesStartupTombstoneBeforeRetry() async throws {
        let defaults = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.defaultsSuiteName(defaults)) }
        let operationID = UUID()
        let sourceManager = TabManager()
        let sourceCache = Self.cache(defaults: defaults)

        _ = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["operation_id": operationID.uuidString],
            tabManager: sourceManager,
            idempotencyCache: sourceCache
        )
        let snapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        let restoredCache = Self.cache(defaults: defaults)
        #expect(restoredCache.completionProvenance(for: operationID) == .restored)
        let restoredManager = TabManager()
        restoredManager.restoreSessionSnapshot(
            snapshot,
            workspaceCreateIdempotencyCache: restoredCache
        )
        let restoredWorkspace = try #require(
            restoredManager.tabs.first { $0.taskCreateOperationID == operationID }
        )
        #expect(restoredCache.completionProvenance(for: operationID) == .currentProcess)
        restoredManager.closeWorkspace(restoredWorkspace)
        let baselineIDs = Set(restoredManager.tabs.map(\.id))

        let retry = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: [
                "operation_id": operationID.uuidString,
                "initial_command": "must-not-launch-after-restore",
            ],
            tabManager: restoredManager,
            idempotencyCache: restoredCache
        )

        #expect(try Self.decode(retry).createdWorkspaceID == nil)
        #expect(Set(restoredManager.tabs.map(\.id)) == baselineIDs)
        #expect(Self.containsInitialCommand("must-not-launch-after-restore", in: restoredManager) == false)
        #expect(restoredCache.completionProvenance(for: operationID) == .currentProcess)
    }

    @Test func tombstoneFIFOIsBoundedAndPersistsAcrossCacheInstances() {
        let defaults = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: Self.defaultsSuiteName(defaults)) }
        let key = "tests.completed.\(UUID().uuidString)"
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 2,
            defaults: defaults,
            persistenceKey: key
        )

        cache.record(operationID: first, workspaceID: UUID())
        cache.record(operationID: second, workspaceID: UUID())
        cache.record(operationID: third, workspaceID: UUID())

        #expect(cache.containsCompletedOperation(first) == false)
        #expect(cache.containsCompletedOperation(second))
        #expect(cache.containsCompletedOperation(third))
        #expect(cache.completionProvenance(for: second) == .currentProcess)
        #expect(cache.completionProvenance(for: third) == .currentProcess)
        let restored = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 2,
            defaults: defaults,
            persistenceKey: key
        )
        #expect(restored.containsCompletedOperation(first) == false)
        #expect(restored.containsCompletedOperation(second))
        #expect(restored.containsCompletedOperation(third))
        #expect(restored.completionProvenance(for: second) == .restored)
        #expect(restored.completionProvenance(for: third) == .restored)
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WorkspaceCreateIdempotencyTombstoneTests.\(UUID().uuidString)")!
    }

    private static func cache(defaults: UserDefaults) -> TerminalController.WorkspaceCreateIdempotencyCache {
        TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 256,
            defaults: defaults,
            persistenceKey: "tests.completed"
        )
    }

    private static func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.volatileDomainNames.first { $0.hasPrefix("WorkspaceCreateIdempotencyTombstoneTests.") } ?? ""
    }

    private static func containsInitialCommand(_ command: String, in manager: TabManager) -> Bool {
        manager.tabs.contains { workspace in
            workspace.panels.values.compactMap { $0 as? TerminalPanel }
                .contains { $0.surface.debugInitialCommand() == command }
        }
    }

    private static func workspaceID(_ result: TerminalController.V2CallResult) -> UUID? {
        guard case let .ok(rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let rawID = payload["workspace_id"] as? String else { return nil }
        return UUID(uuidString: rawID)
    }

    private static func errorCode(_ result: TerminalController.V2CallResult) -> String? {
        guard case let .err(code, _, _) = result else { return nil }
        return code
    }

    private static func decode(_ result: TerminalController.V2CallResult) throws -> TombstoneWorkspaceList {
        guard case let .ok(payload) = result else { throw TombstoneDecodeError.notSuccess }
        return try JSONDecoder().decode(
            TombstoneWorkspaceList.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }
}

private struct TombstoneWorkspaceList: Decodable {
    let createdWorkspaceID: String?

    private enum CodingKeys: String, CodingKey {
        case createdWorkspaceID = "created_workspace_id"
    }
}

private enum TombstoneDecodeError: Error {
    case notSuccess
}
