import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The full paste worker re-executes the app binary, and on a loaded machine
/// that exec alone can outlast the paste deadline (#18819). These tests drive
/// the real worker client and process supervision with a scripted worker.
@Suite("Paste worker startup and the preparation deadline", .serialized, .timeLimit(.minutes(1)))
struct TerminalPasteWorkerStartupDeadlineTests {
    @Test("a worker whose startup outlasts the deadline still completes")
    func slowWorkerStartupDoesNotConsumePreparationDeadline() async throws {
        let worker = try ScriptedPasteWorker(
            startupDelay: "3",
            afterReady: "cp \"$RESPONSE\" \"$3/response.json\"",
            response: .terminal(.insertText("pasted after a slow start"))
        )
        defer { worker.remove() }
        let service = worker.service(deadline: .seconds(2))

        let outcome = await service.prepareReportingFailure(
            request: TerminalPasteboardReadRequest(
                pasteboardName: "cmux-slow-worker-start-\(UUID())",
                changeCount: 0
            ),
            mode: .paste
        )

        #expect(outcome.failure == nil)
        #expect(outcome.content == .insertText("pasted after a slow start"))
    }

    @Test("a started worker that stalls is still killed at the deadline")
    func stalledStartedWorkerStillTimesOut() async throws {
        let worker = try ScriptedPasteWorker(
            startupDelay: "0",
            afterReady: "sleep 30",
            response: .terminal(.insertText("never delivered"))
        )
        defer { worker.remove() }
        // Longer than the bound below: only the readiness restart can end
        // this paste within it.
        let service = worker.service(
            deadline: .seconds(1),
            workerStartupAllowance: .seconds(30)
        )
        let started = ContinuousClock.now

        let outcome = await service.prepareReportingFailure(
            request: TerminalPasteboardReadRequest(
                pasteboardName: "cmux-stalled-worker-\(UUID())",
                changeCount: 0
            ),
            mode: .paste
        )

        #expect(outcome.failure == .deadlineExceeded)
        #expect(outcome.content == .reject)
        #expect(started.duration(to: .now) < .seconds(20))
    }

    @Test("a worker that never finishes starting is killed at the startup allowance")
    func hungWorkerStartupIsBounded() async throws {
        let worker = try ScriptedPasteWorker(
            startupDelay: "30",
            afterReady: "cp \"$RESPONSE\" \"$3/response.json\"",
            response: .terminal(.insertText("never delivered"))
        )
        defer { worker.remove() }
        let service = worker.service(
            deadline: .seconds(1),
            workerStartupAllowance: .seconds(2)
        )
        let started = ContinuousClock.now

        let outcome = await service.prepareReportingFailure(
            request: TerminalPasteboardReadRequest(
                pasteboardName: "cmux-hung-worker-start-\(UUID())",
                changeCount: 0
            ),
            mode: .paste
        )

        #expect(outcome.failure == .deadlineExceeded)
        #expect(outcome.content == .reject)
        #expect(started.duration(to: .now) < .seconds(20))
    }
}

/// A shell script standing in for `cmux --cmux-paste-preparation-worker`.
/// It sleeps to simulate exec and app-image load, prints the startup byte the
/// real worker prints once it is running, then runs `afterReady`.
struct ScriptedPasteWorker {
    let directory: URL
    let executableURL: URL

    init(
        startupDelay: String,
        afterReady: String,
        response: TerminalPastePreparationResult
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scripted-paste-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let responseURL = directory.appendingPathComponent("response.json")
        try JSONEncoder().encode(
            TerminalPastePreparationWorkerResponse(
                result: response,
                textPayload: nil,
                ownedTemporaryImageNames: []
            )
        ).write(to: responseURL)
        executableURL = directory.appendingPathComponent("worker.sh")
        let script = """
        #!/bin/sh
        RESPONSE='\(responseURL.path)'
        sleep \(startupDelay)
        printf r
        exec >/dev/null
        \(afterReady)
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func service(
        deadline: Duration,
        workerStartupAllowance: Duration = TerminalImageTransferPreparationService
            .defaultWorkerStartupAllowance
    ) -> TerminalImageTransferPreparationService {
        let pasteboardService = TerminalPasteboardService()
        let client = TerminalPastePreparationWorkerClient(
            executableURL: executableURL,
            pasteboardService: pasteboardService,
            plainTextExecutableURL: nil
        )
        return TerminalImageTransferPreparationService(
            deadline: deadline,
            workerStartupAllowance: workerStartupAllowance,
            operation: { request in try await client.prepare(request) },
            cleanup: { result in
                result.cleanupTransferredTemporaryFiles(using: pasteboardService)
            },
            failureSignal: { _ in }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
