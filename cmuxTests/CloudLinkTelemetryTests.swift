import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

struct CloudLinkTelemetryTests {
    @Test("token query values are redacted from routes and stderr text")
    func redactsTokenQueryValues() {
        let route = "wss://happy-fox-cmux.preview.bl.run/v1/link?bl_preview_token=dbbfe6ecdcb6cde040f0ec3c9cddc536"
        #expect(CloudLinkTelemetry.redactSecrets(route)
            == "wss://happy-fox-cmux.preview.bl.run/v1/link?bl_preview_token=REDACTED")

        let stderr = "connect failed for wss://h/v1/link?bl_preview_token=abc123&x=1 · retrying"
        let redacted = CloudLinkTelemetry.redactSecrets(stderr)
        #expect(!redacted.contains("abc123"))
        #expect(redacted.contains("&x=1"))

        let mixedCase = "https://h/p?Access_Token=secret&plain=keep"
        let mixedRedacted = CloudLinkTelemetry.redactSecrets(mixedCase)
        #expect(!mixedRedacted.contains("secret"))
        #expect(mixedRedacted.contains("plain=keep"))

        #expect(CloudLinkTelemetry.redactSecrets("no secrets here") == "no secrets here")
    }

    @Test("errors map to the pipeline stage they came from")
    func stagesFollowErrorTypes() {
        #expect(CloudLinkTelemetry.stage(for: VMClientError.httpStatus(429, "rate_limited")) == "attach_endpoint")
        #expect(CloudLinkTelemetry.stage(for: CloudMachineLink.LinkError.timedOut) == "socket_wait")
        #expect(CloudLinkTelemetry.stage(for: CloudMachineLink.LinkError.spawnFailed("nope")) == "spawn")
        #expect(CloudLinkTelemetry.stage(for: CloudMachineLink.LinkError.exited(status: 1, output: "boom")) == "link_exit")
        #expect(CloudLinkTelemetry.stage(for: CloudMachineLinkManager.ManagerError.clientMissing) == "client_missing")
        #expect(CloudLinkTelemetry.stage(for: CloudMachineLinkManager.ManagerError.retryLater("backing off")) == "retry_backoff")
        #expect(CloudLinkTelemetry.stage(for: CocoaError(.fileNoSuchFile)) == "other")
    }

    @Test("error classes group HTTP statuses and typed failures")
    func errorClassesGroupFailures() {
        #expect(CloudLinkTelemetry.errorClass(for: VMClientError.httpStatus(429, "rate_limited")) == "http_429")
        #expect(CloudLinkTelemetry.errorClass(for: VMClientError.notSignedIn) == "not_signed_in")
        #expect(CloudLinkTelemetry.errorClass(for: VMClientError.backendUnreachable(url: "http://x", detail: "d")) == "backend_unreachable")
        #expect(CloudLinkTelemetry.errorClass(for: CloudMachineLink.LinkError.timedOut) == "timeout")
        #expect(CloudLinkTelemetry.errorClass(for: CancellationError()) == "cancelled")
    }

    @Test("capture throttle allows one send per key per interval")
    func throttleAllowsOneSendPerInterval() {
        let throttle = CloudLinkCaptureThrottle(interval: 300)
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(throttle.shouldSend(key: "vm-1|socket_wait", now: start))
        #expect(!throttle.shouldSend(key: "vm-1|socket_wait", now: start.addingTimeInterval(299)))
        #expect(throttle.shouldSend(key: "vm-1|attach_endpoint", now: start))
        #expect(throttle.shouldSend(key: "vm-2|socket_wait", now: start))
        #expect(throttle.shouldSend(key: "vm-1|socket_wait", now: start.addingTimeInterval(301)))
        #expect(!throttle.shouldSend(key: "vm-1|socket_wait", now: start.addingTimeInterval(302)))
    }

    @Test("machine correlation identifiers are launch-scoped and do not expose the input")
    func machineCorrelationIdentifiersDoNotExposeMachineIDs() {
        let secret = "vm-with-private-user-data"
        let first = CloudLinkTelemetry.machineCorrelationID(secret)
        #expect(first != secret)
        #expect(first.count == 20)
        #expect(first == CloudLinkTelemetry.machineCorrelationID(secret))
        #expect(first != CloudLinkTelemetry.machineCorrelationID("another-machine"))
    }
}
#endif
