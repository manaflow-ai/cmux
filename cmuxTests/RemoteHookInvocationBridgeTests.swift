import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@Suite
struct RemoteHookInvocationBridgeTests {
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
        } catch let error as RemoteHookInvocationBridge.BridgeError {
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
        } catch let error as RemoteHookInvocationBridge.BridgeError {
            #expect(error.code == "timed_out")
        }
        #expect(!process.isRunning)
    }
}
#endif
