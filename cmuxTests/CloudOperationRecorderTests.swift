import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@MainActor
struct CloudOperationRecorderTests {
    @Test func concurrentOperationsKeepIndependentState() async {
        let recorder = CloudOperationRecorder()
        let first = recorder.begin(.create)
        let second = recorder.begin(.open)
        await recorder.finish(first, error: CloudDiagnosticFailure.network)
        #expect(recorder.operations.first(where: { $0.id == first.operationID })?.needsAttention == true)
        #expect(recorder.operations.first(where: { $0.id == second.operationID })?.isRunning == true)
        await recorder.finish(second)
        #expect(recorder.operations.first?.needsAttention == true, "Another operation completing must not clear this failure")
    }

    @Test func everyFailureIsExportedWithoutIncidentThrottling() async {
        let sink = CapturedCloudDiagnostics()
        let identity = AuthenticatedSessionIdentity(generation: 1, accountID: "test-account")
        let recorder = CloudOperationRecorder(uploader: sink, identity: { identity })
        for _ in 0..<3 {
            let operation = recorder.begin(.connect)
            await recorder.finish(operation, error: CloudDiagnosticFailure.network)
            await recorder.finish(operation, error: CloudDiagnosticFailure.network)
        }
        let spans = await sink.spans
        #expect(spans.count == 3, "Each failure is retained, and repeated finalization is ignored")
        #expect(Set(spans.map(\.eventId)).count == 3)
        #expect(spans.allSatisfy { $0.failure == .network })
    }

    @Test func retriesKeepTheirFailuresAndShareTheOperationTrace() async {
        let sink = CapturedCloudDiagnostics()
        let identity = AuthenticatedSessionIdentity(generation: 1, accountID: "test-account")
        let recorder = CloudOperationRecorder(uploader: sink, identity: { identity })
        let root = recorder.begin(.create)
        let first = recorder.beginChild(of: root, phase: .request, attempt: 1)
        await recorder.finish(first, httpStatus: 503)
        let second = recorder.beginChild(of: root, phase: .request, attempt: 2)
        await recorder.finish(second, httpStatus: 200)
        await recorder.finish(root)
        let spans = await sink.spans
        #expect(Set(spans.map(\.traceId)) == [root.traceID])
        #expect(Set(spans.map(\.spanId)).count == 3)
        #expect(spans[0].parentSpanId == root.spanID)
        #expect(spans[0].outcome == .failure)
        #expect(spans[1].attempt == 2)
        #expect(recorder.operations.first?.needsAttention == false, "A recovered retry is preserved in details without claiming the operation failed")
    }

    @Test func signOutPreventsLateResultsFromRestoringOperations() async {
        let recorder = CloudOperationRecorder()
        let root = recorder.begin(.open)
        recorder.reset()
        await recorder.finish(root, error: CloudDiagnosticFailure.server)
        #expect(recorder.operations.isEmpty)
        #expect(recorder.reference(operationID: root.operationID.uuidString.lowercased(), traceID: root.traceID, spanID: root.spanID) == nil)
    }

    @Test func metadataSeparatesNightlyFromItsBackend() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45", "CMUXCommit": "abcdef123"]
        #expect(CloudTelemetryClient.current(info: info, flavor: .nightly).channel == "nightly")
        #expect(CloudTelemetryClient.current(info: info, flavor: .stable).channel == "production")
        #expect(CloudTelemetryClient.current(info: info, flavor: .dev).channel == "dev")
        #expect(CloudTelemetryClient.current(info: info, flavor: .nightly).revision == "abcdef123")
    }
}

private actor CapturedCloudDiagnostics: CloudTelemetrySending {
    private(set) var spans: [CloudTelemetrySpan] = []
    func enqueue(_ span: CloudTelemetrySpan, identity: AuthenticatedSessionIdentity) { spans.append(span) }
    func clearForSignOut() { spans.removeAll() }
}
#endif
