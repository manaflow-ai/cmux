import CmuxAuthRuntime
import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@MainActor
struct CloudOperationRecorderTests {
    @Test func alertLabelsAndScrollableDetailsOfferCopyError() throws {
        for text in ["Cloud could not connect.", String(repeating: "Cloud connection failed\n", count: 100)] {
            let alert = NSAlert()
            alert.messageText = "Cloud error"
            CmuxAlertContent.scrollingAll(text).apply(to: alert, visibleFrame: NSRect(x: 0, y: 0, width: 1024, height: 768))
            CloudErrorCopy.install(in: alert, text: text)
            defer { alert.window.close() }
            let root = try #require(alert.window.contentView)
            var pending = [root]
            var textViewCount = 0
            while let view = pending.popLast() {
                if view is NSTextField || view is NSTextView {
                    textViewCount += 1
                    #expect(view.menu?.items.first?.title == CloudErrorCopy.title)
                }
                pending.append(contentsOf: view.subviews)
            }
            #expect(textViewCount > 0)
        }
    }

    @Test func longMultilineErrorsCopyWithoutTruncation() throws {
        let text = "Cloud error\n" + String(repeating: "診断情報 connection failed\n", count: 300) + "trace=00112233445566778899aabbccddeeff"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let menu = CloudErrorCopy.menu(text, pasteboard: pasteboard)
        let item = try #require(menu.items.first)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(pasteboard.string(forType: .string) == text)
    }

    @Test func completedOperationsDoNotLeaveActivityChrome() async {
        let recorder = CloudOperationRecorder()
        #expect(recorder.operations.filter(\.isVisibleInMachinesPanel).isEmpty)
        let root = recorder.begin(.open)
        #expect(recorder.operations.filter(\.isVisibleInMachinesPanel).count == 1)
        await recorder.finish(root)
        #expect(recorder.operations.filter(\.isVisibleInMachinesPanel).isEmpty)
        let failed = recorder.begin(.connect)
        await recorder.finish(failed, error: CloudDiagnosticFailure.network)
        #expect(recorder.operations.filter(\.isVisibleInMachinesPanel).map(\.id) == [failed.operationID])
    }

    @Test func copyErrorMenuCopiesFullFailureWithTraceAndFailedStep() async throws {
        let recorder = CloudOperationRecorder()
        let root = recorder.begin(.open)
        let child = recorder.beginChild(of: root, phase: .request, attempt: 1)
        await recorder.finish(child, httpStatus: 503)
        await recorder.finish(root, error: CloudDiagnosticFailure.server)
        let operation = try #require(recorder.operations.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let menu = CloudErrorCopy.menu(operation.copyableError, pasteboard: pasteboard)
        let item = try #require(menu.items.first)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied == operation.copyableError)
        #expect(copied.contains(root.traceID))
        #expect(copied.contains(child.spanID))
        #expect(copied.contains(CloudOperationPhase.request.label))
        #expect(copied.contains(CloudDiagnosticFailure.server.label))
    }

    @Test func diagnosticsRetainRecoveredErrorsAndBuildIdentity() async throws {
        let recorder = CloudOperationRecorder()
        let root = recorder.begin(.open)
        let child = recorder.beginChild(of: root, phase: .request, attempt: 1)
        await recorder.finish(child, httpStatus: 503)
        await recorder.finish(root)
        let client = CloudTelemetryClient.current(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45", "CMUXCommit": "abcdef123"], flavor: .nightly)
        let report = CloudDiagnosticReport.text(operations: recorder.operations, client: client)
        #expect(report.contains("nightly"))
        #expect(report.contains("abcdef123"))
        #expect(report.contains("1.2.3"))
        #expect(report.contains("45"))
        #expect(report.contains("server"))
        #expect(report.contains(root.traceID))
        #expect(recorder.operations.filter(\.isVisibleInMachinesPanel).isEmpty)
    }

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
