import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIWindowHandleRoutingTests {
    @Test func closeWindowResolvesTypedHandleBeforeLegacyMutation() throws {
        try assertTypedHandleRoutes(
            command: "close-window",
            expectedMutationLine: "close_window \(Self.targetWindowID)"
        )
    }

    @Test func focusWindowResolvesTypedHandleBeforeLegacyMutation() throws {
        try assertTypedHandleRoutes(
            command: "focus-window",
            expectedMutationLine: "focus_window \(Self.targetWindowID)"
        )
    }

    @Test func closeWindowPreservesLegacyNotFoundError() throws {
        let socketPath = Self.makeSocketPath("missing")
        let server = try CLIWindowCommandMockServer(
            socketPath: socketPath,
            targetWindowID: Self.targetWindowID,
            targetWindowRef: Self.targetWindowRef
        )
        server.start()
        defer { server.stop() }

        let result = try Self.runCLI(
            arguments: ["close-window", "--window", Self.missingWindowID],
            socketPath: socketPath
        )

        #expect(server.waitUntilFinished(timeout: 5))
        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 1, Comment(rawValue: result.output))
        #expect(result.output == "Error: ERROR: Window not found\n")
        #expect(server.receivedLinesSnapshot() == ["close_window \(Self.missingWindowID)"])
    }

    @Test func closeWindowRejectsMalformedTypedHandleBeforeMutation() throws {
        let socketPath = Self.makeSocketPath("invalid")
        let server = try CLIWindowCommandMockServer(
            socketPath: socketPath,
            targetWindowID: Self.targetWindowID,
            targetWindowRef: Self.targetWindowRef
        )
        server.start()
        defer { server.stop() }

        let result = try Self.runCLI(
            arguments: ["close-window", "--window", "window:not-a-number"],
            socketPath: socketPath
        )

        #expect(server.waitUntilFinished(timeout: 5))
        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 1, Comment(rawValue: result.output))
        #expect(
            result.output.contains(
                "Invalid window handle: window:not-a-number (expected UUID, ref like window:1, or index)"
            ),
            Comment(rawValue: result.output)
        )
        #expect(server.receivedLinesSnapshot().isEmpty)
    }

    private func assertTypedHandleRoutes(command: String, expectedMutationLine: String) throws {
        let socketPath = Self.makeSocketPath(command)
        let server = try CLIWindowCommandMockServer(
            socketPath: socketPath,
            targetWindowID: Self.targetWindowID,
            targetWindowRef: Self.targetWindowRef
        )
        server.start()
        defer { server.stop() }

        let result = try Self.runCLI(
            arguments: [command, "--window", Self.targetWindowRef],
            socketPath: socketPath
        )

        #expect(server.waitUntilFinished(timeout: 5))
        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "OK")

        let receivedLines = server.receivedLinesSnapshot()
        #expect(receivedLines.count == 2)
        #expect(receivedLines.last == expectedMutationLine)
        let requests = try server.requestObjects()
        #expect(requests.compactMap { $0["method"] as? String } == ["window.list"])
    }

    private static func runCLI(arguments: [String], socketPath: String) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: try bundledCLIPath())
        process.arguments = arguments
        process.environment = cliEnvironment(socketPath: socketPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exited.signal()
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, output: String(describing: error), timedOut: false)
        }

        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }

        return ProcessResult(
            status: process.terminationStatus,
            output: String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            timedOut: timedOut
        )
    }

    private static func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
    }

    private static func cliEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"
        return environment
    }

    private static func makeSocketPath(_ label: String) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-window-\(label.prefix(5))-\(suffix).sock")
            .path
    }

    private static let targetWindowID = "22222222-2222-2222-2222-222222222222"
    private static let targetWindowRef = "window:2"
    private static let missingWindowID = "33333333-3333-3333-3333-333333333333"

    private final class BundleToken {}

    private struct ProcessResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }
}
