import Foundation

@_silgen_name("task_local_test_legacy_checks")
private func legacyCheckCount() -> UInt32

@main
struct CloudTaskLocalProbe {
    static func main() async throws {
        try await nestedSuccess()
        try await failureRestoresParent()
        try await cancellationRestoresParent()
        try await concurrentOperationsStaySeparate()
        if ProcessInfo.processInfo.environment["CMUX_TEST_LEGACY_TASK_LOCAL"] != nil {
            precondition(legacyCheckCount() > 0, "The regression must execute the legacy branch")
        }
        print("PASS: 4 Cloud task-local lifecycle scenarios")
    }

    @MainActor
    private static func nestedSuccess() async throws {
        let recorder = CloudOperationRecorder()
        precondition(CloudOperationContext.current == nil)
        let output: [String: String] = try await recorder.perform(.list) {
            let root = try current()
            let output = try await root.withPhase(.request) {
                let child = try current()
                precondition(child.operationID == root.operationID)
                precondition(child.parentSpanID == root.spanID)
                // Resume through another actor while retaining the same context.
                let span = await ContextReader().spanID()
                precondition(span == child.spanID)
                let cleared = await CloudOperationContext.withCurrent(nil) {
                    CloudOperationContext.current == nil
                }
                precondition(cleared)
                precondition(CloudOperationContext.current?.spanID == child.spanID)
                return ["span": child.spanID]
            }
            precondition(CloudOperationContext.current?.spanID == root.spanID)
            return output
        }
        precondition(output["span"] != nil)
        precondition(CloudOperationContext.current == nil)
        precondition(recorder.operations.count == 1)
        precondition(recorder.operations[0].outcome == .success)
        precondition(recorder.operations[0].steps[0].outcome == .success)
    }

    @MainActor
    private static func failureRestoresParent() async throws {
        let recorder = CloudOperationRecorder()
        do {
            try await recorder.perform(.open) {
                let root = try current()
                do {
                    try await root.withPhase(.connect) {
                        precondition(CloudOperationContext.current?.parentSpanID == root.spanID)
                        throw CloudDiagnosticFailure.network
                    }
                } catch {
                    precondition(CloudOperationContext.current?.spanID == root.spanID)
                    throw error
                }
            }
            preconditionFailure("The original error must escape")
        } catch CloudDiagnosticFailure.network {}
        precondition(CloudOperationContext.current == nil)
        precondition(recorder.operations[0].outcome == .failure)
        precondition(recorder.operations[0].steps[0].failure == .network)
    }

    @MainActor
    private static func cancellationRestoresParent() async throws {
        let recorder = CloudOperationRecorder()
        let entered = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { precondition(CloudOperationContext.current == nil) }
            try await recorder.perform(.open) {
                try await CloudOperationContext.phase(.connect) {
                    entered.continuation.yield(())
                    for await _ in resume.stream {}
                    try Task.checkCancellation()
                }
            }
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        resume.continuation.finish()
        entered.continuation.finish()
        do {
            try await task.value
            preconditionFailure("Cancellation must reach the existing task")
        } catch is CancellationError {}
        precondition(recorder.operations[0].outcome == .cancelled)
        precondition(recorder.operations[0].steps[0].outcome == .cancelled)
        precondition(CloudOperationContext.current == nil)
    }

    @MainActor
    private static func concurrentOperationsStaySeparate() async throws {
        let recorder = CloudOperationRecorder()
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await recorder.perform(.list) {
                        let root = try current()
                        let span = await ContextReader().spanID()
                        precondition(span == root.spanID)
                        return root.operationID
                    }
                }
            }
            var ids = Set<UUID>()
            for try await id in group { ids.insert(id) }
            return ids
        }
        precondition(ids.count == 16)
        precondition(recorder.operations.allSatisfy { $0.outcome == .success })
        precondition(CloudOperationContext.current == nil)
    }

    private static func current() throws -> CloudOperationContext {
        guard let context = CloudOperationContext.current else {
            throw CloudDiagnosticFailure.unknown
        }
        return context
    }
}

private actor ContextReader {
    func spanID() -> String? { CloudOperationContext.current?.spanID }
}
