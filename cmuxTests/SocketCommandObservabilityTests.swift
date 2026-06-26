import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SocketCommandObservabilityTests {
    @Test func parsesV2MethodPeerAndWorkerLane() {
        let command = SocketCommandObservability.command(
            for: #"{"jsonrpc":"2.0","id":1,"method":"browser.eval","params":{}}"#,
            peerPid: 1234
        )

        #expect(command.protocolName == .v2)
        #expect(command.method == "browser.eval")
        #expect(command.peerPid == pid_t(1234))
        #expect(command.executionLane == .socketWorker)
    }

    @Test func parsesV1PingAsWorkerAndOtherV1AsMainActor() {
        let ping = SocketCommandObservability.command(for: "ping", peerPid: nil)
        let send = SocketCommandObservability.command(for: "send echo hi", peerPid: nil)

        #expect(ping.protocolName == .v1)
        #expect(ping.method == "ping")
        #expect(ping.executionLane == .socketWorker)
        #expect(send.protocolName == .v1)
        #expect(send.method == "send")
        #expect(send.executionLane == .mainActor)
    }

    @Test func sanitizesUntrustedCommandNamesForLogs() {
        let command = SocketCommandObservability.command(
            for: #"{"method":"browser eval\nsecret","params":{}}"#,
            peerPid: nil
        )

        #expect(command.method == "browser_eval_secret")
    }

    @Test func extractsV2MethodWithoutDependingOnFieldOrder() {
        let command = SocketCommandObservability.command(
            for: #"{"params":{"script":"({method:'not this one'})"},"method":"browser.eval","id":7}"#,
            peerPid: nil
        )

        #expect(command.protocolName == .v2)
        #expect(command.method == "browser.eval")
        #expect(command.executionLane == .socketWorker)
    }

    @Test func completionEmitsOnlyAtSlowThresholdByDefault() throws {
        let command = SocketCommandObservability.command(for: "list_workspaces", peerPid: 42)

        let fast = SocketCommandObservability.completion(
            for: command,
            startedAt: 1_000,
            finishedAt: 50_001_000,
            response: "OK"
        )
        #expect(fast == nil)

        let slow = try #require(SocketCommandObservability.completion(
            for: command,
            startedAt: 1_000,
            finishedAt: 125_001_000,
            response: "OK",
            completionThread: .worker
        ))
        #expect(slow.status == .ok)
        #expect(slow.durationNanoseconds == 125_000_000)
        #expect(slow.responseByteCount == 2)
        #expect(slow.completionThread == .worker)
    }

    @Test func responseStatusClassifiesV1AndV2Errors() {
        #expect(SocketCommandObservability.responseStatus(response: nil) == .noResponse)
        #expect(SocketCommandObservability.responseStatus(response: "ERROR: bad") == .error)
        #expect(SocketCommandObservability.responseStatus(response: #"{"ok":false,"error":{"code":"bad"}}"#) == .error)
        #expect(SocketCommandObservability.responseStatus(response: #"{"ok":true,"result":{}}"#) == .ok)
    }

    @Test func mainThreadSampleExcerptKeepsOnlyMainThreadCallGraph() throws {
        let sample = """
        Analysis of sampling cmux (pid 123)
        ----

        Call graph:
            5 Thread_100   DispatchQueue_1: com.apple.main-thread  (serial)
              5 start  (in dyld)
                5 v2BrowserEval  (in cmux)
                  5 CFRunLoopRunSpecific  (in CoreFoundation)
            5 Thread_101   DispatchQueue_2: socket-worker  (serial)
              5 read  (in libsystem_kernel.dylib)

        Total number in stack (recursive counted multiple, when >=5):
        """

        let excerpt = try #require(SocketCommandObservability.mainThreadSampleExcerpt(from: sample))
        #expect(excerpt.contains("com.apple.main-thread"))
        #expect(excerpt.contains("v2BrowserEval"))
        #expect(!excerpt.contains("socket-worker"))
    }
}
