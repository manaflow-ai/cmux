import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@Suite
struct RemoteHookInvocationBridgeTests {
    @Test("transfer dispatch releases cancelled and executed slots")
    func transferDispatchReleasesSlots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RemoteHookInvocationBridge(transferRoot: root)
        let invocation = RemoteHookInvocation(
            arguments: ["omp", "session-start"],
            environment: [:],
            input: Data()
        )
        let transferIDs = try (0 ..< bridge.maximumConcurrentTransfers).map { _ in
            try bridge.beginTransfer(invocation)
        }

        guard case .success(let cancelResponse) = bridge.handle(
            method: "hooks.invoke.cancel",
            params: ["transfer_id": transferIDs[0]],
            localSocketPath: ""
        ) else {
            Issue.record("expected cancellation dispatch to succeed")
            return
        }
        #expect(cancelResponse["cancelled"] as? Bool == true)
        _ = try bridge.beginTransfer(invocation)

        _ = bridge.handle(
            method: "hooks.invoke.execute",
            params: ["transfer_id": transferIDs[1]],
            localSocketPath: root.appendingPathComponent("missing.sock").path
        )
        _ = try bridge.beginTransfer(invocation)
        do {
            _ = try bridge.beginTransfer(invocation)
            Issue.record("expected all transfer slots to remain occupied")
        } catch let error as RemoteHookInvocationBridgeError {
            #expect(error.code == "resource_exhausted")
        }
    }

    @Test("cancellation releases staged transfers but not claimed work")
    func cancellationRespectsTransferOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RemoteHookInvocationBridge(transferRoot: root)
        let invocation = RemoteHookInvocation(
            arguments: ["omp", "session-start"],
            environment: [:],
            input: Data()
        )
        var transferIDs = try (0 ..< bridge.maximumConcurrentTransfers).map { _ in
            try bridge.beginTransfer(invocation)
        }

        #expect(try bridge.cancelTransfer(transferIDs[0]))
        transferIDs[0] = try bridge.beginTransfer(invocation)
        _ = try bridge.takeTransfer(transferIDs[1])
        #expect(try !bridge.cancelTransfer(transferIDs[1]))
        do {
            _ = try bridge.beginTransfer(invocation)
            Issue.record("expected claimed transfer to retain its slot")
        } catch let error as RemoteHookInvocationBridgeError {
            #expect(error.code == "resource_exhausted")
        }
        bridge.releaseTransfer(transferIDs[1])
    }

    @Test("claimed hook transfers retain their concurrency slot")
    func claimedTransferRetainsConcurrencySlot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RemoteHookInvocationBridge(transferRoot: root)
        let invocation = RemoteHookInvocation(
            arguments: ["omp", "session-start"],
            environment: [:],
            input: Data()
        )
        let transferIDs = try (0 ..< bridge.maximumConcurrentTransfers).map { _ in
            try bridge.beginTransfer(invocation)
        }

        _ = try bridge.takeTransfer(transferIDs[0])
        do {
            _ = try bridge.beginTransfer(invocation)
            Issue.record("expected claimed transfer to retain its slot")
        } catch let error as RemoteHookInvocationBridgeError {
            #expect(error.code == "resource_exhausted")
        }
    }

    @Test("chunked hook payloads enforce the direct invocation input limit")
    func chunkedHookInputLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RemoteHookInvocationBridge(transferRoot: root)
        let transferID = try bridge.beginTransfer(RemoteHookInvocation(
            arguments: ["omp", "session-start"],
            environment: [:],
            input: Data()
        ))
        try bridge.append(
            Data(repeating: 0x61, count: (8 * 1024 * 1024) + 1),
            toTransfer: transferID
        )

        do {
            _ = try bridge.takeTransfer(transferID)
            Issue.record("expected chunked hook input limit failure")
        } catch let error as RemoteHookInvocationBridgeError {
            #expect(error.code == "invalid_params")
        }
    }

    @Test("staged hook transfers have a fixed concurrency bound")
    func stagedTransferConcurrencyBound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RemoteHookInvocationBridge(transferRoot: root)
        let params: [String: Any] = [
            "arguments": ["omp", "session-start"],
            "environment": ["CMUX_WORKSPACE_ID": "workspace:1"],
        ]

        for _ in 0 ..< bridge.maximumConcurrentTransfers {
            guard case .success(let response) = bridge.handle(
                method: "hooks.invoke.begin",
                params: params,
                localSocketPath: ""
            ) else {
                Issue.record("expected transfer slot")
                return
            }
            #expect(response["transfer_id"] as? String != nil)
        }

        guard case .failure(let error) = bridge.handle(
            method: "hooks.invoke.begin",
            params: params,
            localSocketPath: ""
        ) else {
            Issue.record("expected transfer limit failure")
            return
        }
        #expect(error.code == "resource_exhausted")
    }

    @Test("hook subprocess output is terminated at the byte limit")
    func subprocessOutputLimit() throws {
        let bridge = RemoteHookInvocationBridge()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.arguments = ["remote-hook-output"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        do {
            _ = try bridge.captureProcessOutput(
                process,
                outputPipe: outputPipe,
                errorPipe: errorPipe,
                timeout: 2,
                maximumBytes: 4 * 1024
            )
            Issue.record("expected output limit failure")
        } catch let error as RemoteHookInvocationBridgeError {
            #expect(error.code == "resource_exhausted")
        }
        #expect(!process.isRunning)
    }

    @Test("hook subprocesses are terminated at the deadline")
    func subprocessTimeout() throws {
        let bridge = RemoteHookInvocationBridge()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        do {
            _ = try bridge.captureProcessOutput(
                process,
                outputPipe: outputPipe,
                errorPipe: errorPipe,
                timeout: 0.05,
                maximumBytes: 4 * 1024
            )
            Issue.record("expected timeout failure")
        } catch let error as RemoteHookInvocationBridgeError {
            #expect(error.code == "timed_out")
        }
        #expect(!process.isRunning)
    }
}
#endif
