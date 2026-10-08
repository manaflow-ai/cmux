@testable import CmuxiOSSSHCore
import CmuxMobileWire
import Foundation
import Testing

@Suite struct SSHTmuxLifecycleOwnerTests {
    private let epoch = SSHTmuxServerEpoch(serverPID: 42, serverStart: 1_793_331_200)!

    private actor Store: SSHTmuxLifecycleRecordStore {
        var records: [String: SSHTmuxLifecycleRecord] = [:]

        func record(for idempotencyKey: String) async throws -> SSHTmuxLifecycleRecord? {
            records[idempotencyKey]
        }

        func reserve(_ record: SSHTmuxLifecycleRecord) async throws -> SSHTmuxLifecycleRecord? {
            if let existing = records[record.idempotencyKey] { return existing }
            records[record.idempotencyKey] = record
            return nil
        }

        func put(_ record: SSHTmuxLifecycleRecord) async throws {
            records[record.idempotencyKey] = record
        }

        func phase(for key: String) -> SSHTmuxLifecycleRecord.Phase? { records[key]?.phase }
    }

    private actor Executor: SSHTmuxLifecycleExecutor {
        var calls = 0
        var shouldFail = false
        let result: SSHTmuxLifecycleExecution

        init(result: SSHTmuxLifecycleExecution) {
            self.result = result
        }

        func execute(_ mutation: SSHTmuxLifecycleMutation) async throws -> SSHTmuxLifecycleExecution {
            calls += 1
            if shouldFail {
                shouldFail = false
                throw SSHTmuxLifecycleOwnerError.malformedRecord
            }
            return result
        }

        func callCount() -> Int { calls }
        func failNext() { shouldFail = true }
    }

    private actor BlockingExecutor: SSHTmuxLifecycleExecutor {
        let result: SSHTmuxLifecycleExecution
        var calls = 0
        var released = false
        var waiter: CheckedContinuation<Void, Never>?

        init(result: SSHTmuxLifecycleExecution) {
            self.result = result
        }

        func execute(_ mutation: SSHTmuxLifecycleMutation) async throws -> SSHTmuxLifecycleExecution {
            calls += 1
            if !released {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiter = continuation
                }
            }
            return result
        }

        func waitUntilCalled() async {
            while calls == 0 { await Task.yield() }
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }

        func callCount() -> Int { calls }
    }

    private func mutation() -> SSHTmuxLifecycleMutation {
        .renameWindow(server: epoch, windowID: "@12", name: "renamed")
    }

    @Test func appliedRecordReplaysWithoutExecutingAgain() async throws {
        let store = Store()
        let execution = try #require(SSHTmuxLifecycleExecution(value: .object(["window_id": .string("@12")]), revision: "r-1"))
        let executor = Executor(result: execution)
        let owner = SSHTmuxLifecycleOwnerAdapter(store: store, executor: executor)

        let first = try await owner.submit(mutation(), idempotencyKey: "rename-1")
        let replay = try await owner.submit(mutation(), idempotencyKey: "rename-1")

        #expect(!first.replayed)
        #expect(replay.replayed)
        #expect(replay.value == execution.value)
        #expect(replay.revision == execution.revision)
        #expect(await executor.callCount() == 1)
        #expect(await store.phase(for: "rename-1") == .applied)
    }

    @Test func reusingAKeyForAnotherMutationIsRefused() async throws {
        let store = Store()
        let execution = try #require(SSHTmuxLifecycleExecution(value: .null, revision: "r-1"))
        let executor = Executor(result: execution)
        let owner = SSHTmuxLifecycleOwnerAdapter(store: store, executor: executor)

        _ = try await owner.submit(mutation(), idempotencyKey: "rename-2")
        let changed = SSHTmuxLifecycleMutation.renameWindow(server: epoch, windowID: "@12", name: "other")
        #expect(throws: SSHTmuxLifecycleOwnerError.idempotencyConflict) {
            try await owner.submit(changed, idempotencyKey: "rename-2")
        }
        #expect(await executor.callCount() == 1)
    }

    @Test func executorFailureLeavesAnIndeterminateReplayBarrier() async throws {
        let store = Store()
        let execution = try #require(SSHTmuxLifecycleExecution(value: .null, revision: "r-1"))
        let executor = Executor(result: execution)
        await executor.failNext()
        let owner = SSHTmuxLifecycleOwnerAdapter(store: store, executor: executor)

        #expect(throws: SSHTmuxLifecycleOwnerError.malformedRecord) {
            try await owner.submit(mutation(), idempotencyKey: "rename-3")
        }
        #expect(await store.phase(for: "rename-3") == .pending)
        #expect(throws: SSHTmuxLifecycleOwnerError.indeterminate) {
            try await owner.submit(mutation(), idempotencyKey: "rename-3")
        }
        #expect(await executor.callCount() == 1)
    }

    @Test func atomicReservationPreventsTwoOwnersExecutingTheSameKey() async throws {
        let store = Store()
        let execution = try #require(SSHTmuxLifecycleExecution(value: .null, revision: "r-race"))
        let executor = BlockingExecutor(result: execution)
        let firstOwner = SSHTmuxLifecycleOwnerAdapter(store: store, executor: executor)
        let secondOwner = SSHTmuxLifecycleOwnerAdapter(store: store, executor: executor)
        let first = Task { try await firstOwner.submit(mutation(), idempotencyKey: "rename-race") }

        await executor.waitUntilCalled()
        #expect(throws: SSHTmuxLifecycleOwnerError.indeterminate) {
            try await secondOwner.submit(mutation(), idempotencyKey: "rename-race")
        }
        await executor.release()
        _ = try await first.value
        #expect(await executor.callCount() == 1)
    }

    @Test func invalidInputNeverCreatesARecordOrCallsExecutor() async throws {
        let store = Store()
        let execution = try #require(SSHTmuxLifecycleExecution(value: .null, revision: "r-1"))
        let executor = Executor(result: execution)
        let owner = SSHTmuxLifecycleOwnerAdapter(store: store, executor: executor)

        #expect(throws: SSHTmuxLifecycleOwnerError.invalidRequest) {
            try await owner.submit(mutation(), idempotencyKey: "has space")
        }
        #expect(await store.phase(for: "has space") == nil)
        #expect(await executor.callCount() == 0)
    }
}
