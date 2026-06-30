import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SocketCommandObservabilityTests {
    private let observability = SocketCommandObservability()

    @Test func parsesV2MethodPeerAndWorkerLane() {
        let command = observability.command(
            for: #"{"jsonrpc":"2.0","id":1,"method":"browser.eval","params":{}}"#,
            peerPid: 1234
        )

        #expect(command.protocolName == .v2)
        #expect(command.method == "browser.eval")
        #expect(command.peerPid == pid_t(1234))
        #expect(command.executionLane == .socketWorker)
    }

    @Test func parsesV1PingAsWorkerAndOtherV1AsMainActor() {
        let ping = observability.command(for: "ping", peerPid: nil)
        let send = observability.command(for: "send echo hi", peerPid: nil)

        #expect(ping.protocolName == .v1)
        #expect(ping.method == "ping")
        #expect(ping.executionLane == .socketWorker)
        #expect(send.protocolName == .v1)
        #expect(send.method == "send")
        #expect(send.executionLane == .mainActor)
    }

    @Test func sanitizesUntrustedCommandNamesForLogs() {
        let command = observability.command(
            for: #"{"method":"browser eval\nsecret","params":{}}"#,
            peerPid: nil
        )

        #expect(command.method == "browser_eval_secret")
    }

    @Test func extractsV2MethodWithoutDependingOnFieldOrder() {
        let command = observability.command(
            for: #"{"params":{"script":"({method:'not this one'})"},"method":"browser.eval","id":7}"#,
            peerPid: nil
        )

        #expect(command.protocolName == .v2)
        #expect(command.method == "browser.eval")
        #expect(command.executionLane == .socketWorker)
    }

    @Test func completionEmitsOnlyAtSlowThresholdByDefault() throws {
        let command = observability.command(for: "list_workspaces", peerPid: 42)

        let fast = observability.completion(
            for: command,
            startedAt: 1_000,
            finishedAt: 50_001_000,
            response: "OK"
        )
        #expect(fast == nil)

        let slow = try #require(observability.completion(
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
        #expect(observability.responseStatus(response: nil) == .noResponse)
        #expect(observability.responseStatus(response: "ERROR: bad") == .error)
        #expect(observability.responseStatus(response: #"{"ok":false,"error":{"code":"bad"}}"#) == .error)
        #expect(observability.responseStatus(response: #"{"ok":true,"result":{}}"#) == .ok)
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

        let excerpt = try #require(observability.mainThreadSampleExcerpt(from: sample))
        #expect(excerpt.contains("com.apple.main-thread"))
        #expect(excerpt.contains("v2BrowserEval"))
        #expect(!excerpt.contains("socket-worker"))
    }

    @Test func watchdogSampleCoordinatorCoalescesConcurrentCaptures() async {
        let coordinator = WatchdogSampleCoordinator()

        // First watchdog claims the single sampler slot.
        #expect(await coordinator.beginCaptureIfIdle())
        // A second watchdog firing during the same stall must coalesce instead of
        // spawning another `/usr/bin/sample`.
        #expect(await coordinator.beginCaptureIfIdle() == false)

        // After the in-flight capture finishes the slot is reusable for a later stall.
        await coordinator.endCapture()
        #expect(await coordinator.beginCaptureIfIdle())
    }
}
