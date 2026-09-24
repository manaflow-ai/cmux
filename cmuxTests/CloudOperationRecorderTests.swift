import CmuxAuthRuntime
import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@MainActor
struct CloudOperationRecorderTests {
    @Test("Placement receipts distinguish acceptance from permanent rejection", arguments: [202, 400])
    func placementUploaderReceipt(status: Int) async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("queue.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlacementReceiptURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let uploader = CloudTelemetryUploader(
            auth: fixture.auth,
            baseURL: try #require(URL(string: "https://receipt-\(status).test")),
            client: CloudTelemetryClient.current(info: [:], flavor: .dev),
            session: session,
            queueURL: queueURL
        )
        let identity = try #require(fixture.auth.authenticatedSessionIdentity)
        let recorder = CloudOperationRecorder(uploader: uploader, identity: { identity })
        let operation = recorder.begin(.open)
        await PlacementReceiptURLProtocol.resetCapture(status: status)
        await recorder.finish(operation, error: CmuxTuiSurfaceProvider.ProviderError.remotePlacementUnavailable("fixture-machine"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var acknowledged = false
        while ContinuousClock.now < deadline {
            let data = try Data(contentsOf: queueURL)
            let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            if entries.isEmpty, await PlacementReceiptURLProtocol.captured(status: status) != nil {
                acknowledged = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(acknowledged)
        let captured = try #require(await PlacementReceiptURLProtocol.captured(status: status))
        #expect(captured.failure == "placement")
        #expect(captured.traceID == operation.traceID)
        #expect(captured.operationID == operation.operationID.uuidString.lowercased())
        #expect(await uploader.droppedCount == (status == 400 ? 1 : 0))
        await uploader.clearForSignOut()
    }

    @Test func authenticationFailuresKeepTheirTelemetryClassification() async throws {
        let identity = AuthenticatedSessionIdentity(generation: 1, accountID: "synthetic")
        let sink = CapturedCloudDiagnostics()
        let recorder = CloudOperationRecorder(uploader: sink, identity: { identity })
        let scenarios: [(AuthError, CloudDiagnosticFailure, CloudTelemetrySpan.Outcome)] = [
            (.timedOut, .timeout, .timeout),
            (.networkError, .sessionRefresh, .failure),
            (.cancelled, .cancelled, .cancelled),
            (.unauthorized, .authentication, .failure)
        ]
        for (error, failure, outcome) in scenarios {
            let root = recorder.begin(.list)
            let auth = recorder.beginChild(of: root, phase: .authentication, attempt: 0, file: #fileID, line: #line)
            await recorder.finish(auth, error: error)
            let span = try #require(await sink.spans.last)
            #expect(span.failure == failure)
            #expect(span.outcome == outcome)
            await recorder.finish(root)
        }
        #expect(CloudDiagnosticFailure.sessionRefresh.label == CloudDiagnosticFailure.network.label)
    }

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

    @Test func terminalCreationDiagnosticsRetainFailureAndRetryIdentity() async throws {
        let recorder = CloudOperationRecorder()
        let finished = AsyncStream<Void>.makeStream()
        var completions = finished.stream.makeAsyncIterator()
        var attempts = 0
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("test"), kind: .terminal, key: "term_test"),
            title: "", detail: nil, lifecycle: .launching, agent: nil,
            remoteWorkspace: nil, port: nil, url: nil
        )
        let coordinator = CloudTerminalCreationCoordinator(
            create: {
                attempts += 1
                if attempts == 1 { throw CloudDiagnosticFailure.network }
                return resource
            },
            project: { resource in
                (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onFailure: { _ in finished.continuation.yield(()) },
            onSuccess: { finished.continuation.yield(()) },
            operations: recorder
        )
        coordinator.start()
        _ = await completions.next()
        #expect(recorder.operations.first?.outcome == .failure)
        #expect(recorder.operations.first?.failure == .network)
        coordinator.retry()
        _ = await completions.next()
        #expect(recorder.operations.count == 2)
        #expect(recorder.operations.last?.outcome == .success)
        #expect(recorder.operations.first?.id != recorder.operations.last?.id)
        #expect(recorder.operations.allSatisfy { $0.durationMs != nil })
    }

    @Test func completedOperationsDoNotLeaveActivityChrome() async {
        let recorder = CloudOperationRecorder()
        #expect(recorder.operations.filter(\.isVisibleInMachinesPanel).isEmpty)
        let root = recorder.begin(.open)
        #expect(recorder.operations.filter(\.isVisibleInMachinesPanel).count == 1)
        await recorder.finish(root)
        #expect(recorder.operations.first?.durationMs != nil)
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
        #expect(report.contains("total_duration_ms="))
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

    @Test func cliTransferFailureProducesCopyableCorrelatedSpans() async throws {
        let sink = CapturedCloudDiagnostics()
        let identity = AuthenticatedSessionIdentity(generation: 1, accountID: "test-account")
        let recorder = CloudOperationRecorder(uploader: sink, identity: { identity })
        let reference = try #require(await recorder.recordFileTransferFailure(phase: .file, failure: .process, errorNumber: 255))
        let operation = try #require(recorder.operations.last)
        #expect(operation.needsAttention)
        #expect(operation.copyableError.contains(reference))
        let spans = await sink.spans
        #expect(spans.count == 2)
        #expect(Set(spans.map(\.traceId)).count == 1)
        #expect(spans.first?.phase == .file)
        #expect(spans.first?.errorNumber == 255)
        #expect(spans.allSatisfy { $0.operation == .file && $0.failure == .process })
    }

    @Test func signedOutCLIReportDoesNotRecordOrExport() async {
        let sink = CapturedCloudDiagnostics()
        let recorder = CloudOperationRecorder(uploader: sink)
        #expect(await recorder.recordFileTransferFailure(phase: .request, failure: .network, errorNumber: nil) == nil)
        #expect(recorder.operations.isEmpty)
        #expect(await sink.spans.isEmpty)
    }

    @Test func metadataSeparatesNightlyFromItsBackend() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45", "CMUXCommit": "abcdef123"]
        #expect(CloudTelemetryClient.current(info: info, flavor: .nightly).channel == "nightly")
        #expect(CloudTelemetryClient.current(info: info, flavor: .rc).channel == "rc")
        #expect(CloudTelemetryClient.current(info: info, flavor: .stable).channel == "production")
        #expect(CloudTelemetryClient.current(info: info, flavor: .dev).channel == "dev")
        #expect(CloudTelemetryClient.current(info: info, flavor: .nightly).revision == "abcdef123")
        #expect(CloudTelemetryClient.current(info: info, flavor: .dev, environment: ["CMUX_TAG": "pr-123-cloud"]).tag == "pr-123-cloud")
    }

    @Test func machineUsageFailuresKeepTheirActionableCategories() {
        #expect(CloudDiagnosticFailure.classify(MachineUsageClientError.notSignedIn) == .authentication)
        #expect(CloudDiagnosticFailure.classify(MachineUsageClientError.sessionRefreshFailed) == .sessionRefresh)
        #expect(CloudDiagnosticFailure.classify(MachineUsageClientError.backendUnreachable(url: "https://cmux.test", detail: "timeout")) == .network)
        #expect(CloudDiagnosticFailure.classify(MachineUsageClientError.httpStatus(503, "")) == .server)
        #expect(CloudDiagnosticFailure.classify(MachineUsageClientError.malformedResponse("bad")) == .response)
    }
}

private actor CapturedCloudDiagnostics: CloudTelemetrySending {
    private(set) var spans: [CloudTelemetrySpan] = []
    func enqueue(_ span: CloudTelemetrySpan, identity: AuthenticatedSessionIdentity) { spans.append(span) }
    func clearForSignOut() { spans.removeAll() }
}

/// The parsed immutable span crosses to the capture actor before any receipt is delivered.
/// URLProtocol callbacks can arrive off-actor; mutable capture state stays actor-isolated.
private final class PlacementReceiptURLProtocol: URLProtocol, @unchecked Sendable {
    fileprivate struct UploadedSpan: Sendable {
        let failure: String
        let traceID: String
        let operationID: String
    }

    private actor Capture {
        private var values: [Int: UploadedSpan] = [:]

        func reset(status: Int) {
            values.removeValue(forKey: status)
        }

        func record(status: Int, span: UploadedSpan) {
            values[status] = span
        }

        func value(status: Int) -> UploadedSpan? {
            return values[status]
        }
    }

    private static let capture = Capture()
    fileprivate static func resetCapture(status: Int) async { await capture.reset(status: status) }
    fileprivate static func captured(status: Int) async -> UploadedSpan? { await capture.value(status: status) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            guard let batch = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let spans = batch["spans"] as? [[String: Any]], spans.count == 1,
                  let span = spans.first, let eventID = span["eventId"] as? String,
                  span["failure"] as? String == "placement",
                  let operationID = span["operationId"] as? String, !operationID.isEmpty,
                  (span["traceId"] as? String)?.count == 32,
                  (span["spanId"] as? String)?.count == 16 else {
                throw URLError(.cannotDecodeContentData)
            }
            let status = request.url?.host == "receipt-202.test" ? 202 : 400
            let uploaded = UploadedSpan(
                failure: span["failure"] as? String ?? "",
                traceID: span["traceId"] as? String ?? "",
                operationID: operationID
            )
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            let receipt = try JSONSerialization.data(withJSONObject: ["eventIds": [eventID]])
            Task {
                await Self.capture.record(status: status, span: uploaded)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: receipt)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
#endif
