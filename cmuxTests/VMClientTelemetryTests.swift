import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@Suite
struct VMClientTelemetryTests {
    private func record(
        method: String = "POST",
        route: String = "/api/vm",
        outcome: VMRequestOutcome,
        durationMs: Double = 1234.567,
        trace: VMRequestTraceContext = VMRequestTraceContext(
            traceId: "0af7651916cd43dd8448eb211c80319c",
            spanId: "b7ad6b7169203331",
            clientRequestId: "req-1"
        )
    ) -> VMRequestTelemetryRecord {
        VMRequestTelemetryRecord(method: method, route: route, outcome: outcome, durationMs: durationMs, retryCount: 0, trace: trace)
    }

    @Test("minted trace context is a valid W3C traceparent")
    func mintedTraceContextIsValidTraceparent() {
        let trace = VMRequestTraceContext.mint()
        #expect(trace.traceId.count == 32)
        #expect(trace.spanId.count == 16)
        #expect(trace.traceId.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(trace.traceId != String(repeating: "0", count: 32))
        #expect(trace.traceparent == "00-\(trace.traceId)-\(trace.spanId)-01")
        #expect(trace.headers["traceparent"] == trace.traceparent)
        #expect(trace.headers["X-Cmux-Client-Request-Id"] == trace.clientRequestId)
        #expect(VMRequestTraceContext.mint().traceId != trace.traceId)
    }

    @Test("client identity headers name the app, version, build and channel")
    func clientIdentityHeaders() {
        let headers = VMClientTelemetry.clientIdentityHeaders(
            infoDictionary: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "456"],
            channel: "nightly"
        )
        #expect(headers == [
            "X-Cmux-Client": "cmux-mac",
            "X-Cmux-Channel": "nightly",
            "X-Cmux-App-Version": "1.2.3",
            "X-Cmux-App-Build": "456",
        ])
    }

    @Test("machine ids normalize to {id} but fixed sub-resources do not")
    func normalizedRoute() {
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm") == "/api/vm")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/abc-123") == "/api/vm/{id}")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/abc-123/exec") == "/api/vm/{id}/exec")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/abc-123/cmux-remote/approve") == "/api/vm/{id}/cmux-remote/approve")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/base/open") == "/api/vm/base/open")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/tunnel?x=1") == "/api/vm/tunnel")
        #expect(VMClientTelemetry.normalizedRoute(path: "/api/vm/leases/revoke") == "/api/vm/leases/revoke")
    }

    @Test("polled reads succeed silently, user-waited operations and every failure reach PostHog")
    func postHogCaptureDecision() {
        let listOk = record(method: "GET", route: "/api/vm", outcome: .response(status: 200, errorCode: nil, serverTraceId: nil))
        #expect(VMClientTelemetry.isPolledOperation(method: "GET", route: "/api/vm"))
        #expect(!VMClientTelemetry.shouldCaptureToPostHog(listOk))

        let statusOk = record(method: "GET", route: "/api/vm/{id}", outcome: .response(status: 200, errorCode: nil, serverTraceId: nil))
        #expect(!VMClientTelemetry.shouldCaptureToPostHog(statusOk))

        let listFailed = record(method: "GET", route: "/api/vm", outcome: .response(status: 503, errorCode: "vm_cloud_state_unavailable", serverTraceId: "t"))
        #expect(VMClientTelemetry.shouldCaptureToPostHog(listFailed))

        let createOk = record(outcome: .response(status: 200, errorCode: nil, serverTraceId: "t"))
        #expect(VMClientTelemetry.shouldCaptureToPostHog(createOk))

        let attachOk = record(route: "/api/vm/{id}/attach-endpoint", outcome: .response(status: 200, errorCode: nil, serverTraceId: "t"))
        #expect(VMClientTelemetry.shouldCaptureToPostHog(attachOk))
    }

    @Test("severity: 5xx and transport failures are errors, 4xx warnings, local preconditions nothing")
    func sentrySeverity() {
        #expect(VMClientTelemetry.sentrySeverity(record(outcome: .response(status: 502, errorCode: "vm_cloud_service_unavailable", serverTraceId: nil))) == .error)
        #expect(VMClientTelemetry.sentrySeverity(record(outcome: .response(status: 409, errorCode: "vm_billing_team_required", serverTraceId: nil))) == .warning)
        #expect(VMClientTelemetry.sentrySeverity(record(outcome: .response(status: 200, errorCode: nil, serverTraceId: nil))) == nil)
        #expect(VMClientTelemetry.sentrySeverity(record(outcome: .transportFailure(kind: .backendUnreachable, detail: "x"))) == .error)
        #expect(VMClientTelemetry.sentrySeverity(record(outcome: .transportFailure(kind: .notSignedIn, detail: ""))) == nil)
        #expect(VMClientTelemetry.sentrySeverity(record(outcome: .transportFailure(kind: .cancelled, detail: ""))) == nil)
    }

    @Test("PostHog properties carry the server trace id, code, status, latency and channel")
    func postHogProperties() {
        let failed = record(outcome: .response(status: 503, errorCode: "vm_image_config_error", serverTraceId: "server-trace"))
        let properties = VMClientTelemetry.postHogProperties(failed, channel: "nightly")
        #expect(properties["operation"] as? String == "POST /api/vm")
        #expect(properties["status"] as? Int == 503)
        #expect(properties["error_code"] as? String == "vm_image_config_error")
        #expect(properties["operator_fault"] as? Bool == true)
        #expect(properties["trace_id"] as? String == "server-trace")
        #expect(properties["client_trace_id"] as? String == "0af7651916cd43dd8448eb211c80319c")
        #expect(properties["client_request_id"] as? String == "req-1")
        #expect(properties["duration_ms"] as? Double == 1234.57)
        #expect(properties["channel"] as? String == "nightly")
        #expect(properties["success"] as? Bool == false)

        let unreachable = record(outcome: .transportFailure(kind: .backendUnreachable, detail: "https://x: timed out"))
        let unreachableProperties = VMClientTelemetry.postHogProperties(unreachable, channel: "stable")
        // No server answer: the client trace id is the reference.
        #expect(unreachableProperties["trace_id"] as? String == "0af7651916cd43dd8448eb211c80319c")
        #expect(unreachableProperties["error_code"] as? String == "backend_unreachable")
        #expect(unreachableProperties["transport_failure"] as? String == "backend_unreachable")
        #expect(unreachableProperties["status"] == nil)
        // The raw detail never reaches PostHog; Sentry gets a bounded copy.
        #expect(unreachableProperties["detail"] == nil)
        #expect(VMClientTelemetry.sentryData(unreachable)["detail"] as? String == "https://x: timed out")
    }

    @Test("failures are throttled per operation and code; successes never are")
    func throttling() {
        let clock = ManualClock()
        let captured = CaptureLog()
        let telemetry = VMClientTelemetry(
            capturePostHog: { event, properties in captured.postHog.append((event, properties)) },
            captureSentry: { message, severity, _ in captured.sentry.append((message, severity)) },
            addBreadcrumb: { _, _ in captured.breadcrumbs += 1 },
            now: { clock.now },
            channel: "dev"
        )
        let failure = record(outcome: .response(status: 503, errorCode: "vm_cloud_state_unavailable", serverTraceId: "t1"))
        telemetry.record(failure)
        telemetry.record(failure)
        #expect(captured.postHog.count == 1)
        #expect(captured.sentry.count == 1)
        #expect(captured.sentry.first?.1 == .error)
        #expect(captured.breadcrumbs == 2)

        // A different code on the same operation is a different failure.
        telemetry.record(record(outcome: .response(status: 409, errorCode: "vm_billing_team_required", serverTraceId: "t2")))
        #expect(captured.postHog.count == 2)
        #expect(captured.sentry.count == 2)
        #expect(captured.sentry.last?.1 == .warning)

        clock.now = clock.now.addingTimeInterval(VMClientTelemetry.postHogFailureThrottle)
        telemetry.record(failure)
        #expect(captured.postHog.count == 3)
        #expect(captured.sentry.count == 2, "Sentry window is longer than the PostHog window")

        clock.now = clock.now.addingTimeInterval(VMClientTelemetry.sentryFailureThrottle)
        telemetry.record(failure)
        #expect(captured.sentry.count == 3)

        let success = record(outcome: .response(status: 200, errorCode: nil, serverTraceId: "t3"))
        telemetry.record(success)
        telemetry.record(success)
        #expect(captured.postHog.count == 6, "successes are never throttled")
        #expect(captured.postHog.last?.0 == VMClientTelemetry.postHogEvent)
    }

    @Test("the reference line carries the server trace id")
    func referenceLine() {
        #expect(cloudVMReferenceLine(traceId: "abc123").contains("abc123"))
    }
}

private final class ManualClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private final class CaptureLog: @unchecked Sendable {
    var postHog: [(String, [String: Any])] = []
    var sentry: [(String, VMRequestFailureSeverity)] = []
    var breadcrumbs = 0
}
#endif
