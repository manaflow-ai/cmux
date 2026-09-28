import Darwin
import Foundation
import Testing

/// `set-meta-block`, `clear-meta-block` and `list-meta-blocks` forward to the
/// v1 `report_meta_block` family. The markdown travels raw after ` -- ` with
/// newlines escaped, because the socket protocol is one command per line.
@Suite(.serialized)
struct CLIMetaBlockCommandTests {
    @Test func setMetaBlockSendsInlineMarkdownRaw() throws {
        let run = try Self.run(["set-meta-block", "agent", "**claude** · opus · 42% ctx"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.output))
        #expect(run.result.output == "OK\n")
        #expect(run.lines == ["report_meta_block agent -- **claude** · opus · 42% ctx"])
    }

    @Test func setMetaBlockJoinsMarkdownWordsAfterSeparator() throws {
        let run = try Self.run(["set-meta-block", "agent", "--", "--flag-looking", "text"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.output))
        #expect(run.lines == ["report_meta_block agent -- --flag-looking text"])
    }

    @Test func setMetaBlockReadsMultilineMarkdownFromStdinDash() throws {
        let run = try Self.run(
            ["set-meta-block", "agent", "-"],
            stdin: "**claude** · opus\n- 42% ctx\n- `main`\n"
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.output))
        #expect(run.lines == [#"report_meta_block agent -- **claude** · opus\n- 42% ctx\n- `main`"#])
    }

    @Test func setMetaBlockReadsPipedStdinWhenMarkdownIsOmitted() throws {
        let run = try Self.run(
            ["set-meta-block", "agent"],
            stdin: "line one\r\nline two\n\n"
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.output))
        #expect(run.lines == [#"report_meta_block agent -- line one\nline two"#])
    }

    @Test func setMetaBlockForwardsPriority() throws {
        let run = try Self.run(["set-meta-block", "agent", "--priority", "40", "hello", "world"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.output))
        #expect(run.lines == ["report_meta_block agent --priority=40 -- hello world"])
    }

    @Test func setMetaBlockRejectsNonIntegerPriorityBeforeSending() throws {
        let run = try Self.run(["set-meta-block", "agent", "--priority", "high", "hello"], waitForServer: false)

        #expect(run.result.status == 1, Comment(rawValue: run.result.output))
        #expect(run.result.output.contains("--priority must be an integer"), Comment(rawValue: run.result.output))
        #expect(run.lines.isEmpty)
    }

    @Test func setMetaBlockRejectsEmptyStdinBeforeSending() throws {
        let run = try Self.run(["set-meta-block", "agent", "-"], stdin: "\n  \n", waitForServer: false)

        #expect(run.result.status == 1, Comment(rawValue: run.result.output))
        #expect(run.result.output.contains("set-meta-block requires markdown"), Comment(rawValue: run.result.output))
        #expect(run.lines.isEmpty)
    }

    @Test func setMetaBlockResolvesWorkspaceRef() throws {
        let run = try Self.run([
            "set-meta-block", "agent", "--workspace", Self.workspaceRef, "--priority=5", "hi",
        ])

        #expect(run.result.status == 0, Comment(rawValue: run.result.output))
        #expect(run.lines.count == 2, Comment(rawValue: run.lines.joined(separator: "\n")))
        #expect(run.lines.last == "report_meta_block agent --priority=5 --tab=\(Self.workspaceID) -- hi")
        #expect(try run.requestMethods() == ["workspace.list"])
    }

    @Test func clearMetaBlockResolvesWorkspaceRef() throws {
        let run = try Self.run(["clear-meta-block", "agent", "--workspace", Self.workspaceRef])

        #expect(run.result.status == 0, Comment(rawValue: run.result.output))
        #expect(run.result.output == "OK\n")
        #expect(run.lines.last == "clear_meta_block agent --tab=\(Self.workspaceID)")
    }

    @Test func listMetaBlocksPrintsTheSocketListing() throws {
        let run = try Self.run(["list-meta-blocks", "--workspace", Self.workspaceRef])

        #expect(run.result.status == 0, Comment(rawValue: run.result.output))
        #expect(run.result.output == "\(Self.listing)\n")
        #expect(run.lines.last == "list_meta_blocks --tab=\(Self.workspaceID)")
    }

    // MARK: - Harness

    private struct Run {
        let result: ProcessResult
        let lines: [String]
        let server: CLIWindowCommandMockServer

        func requestMethods() throws -> [String] {
            try server.requestObjects().compactMap { $0["method"] as? String }
        }
    }

    private static func run(
        _ arguments: [String],
        stdin: String? = nil,
        waitForServer: Bool = true
    ) throws -> Run {
        let socketPath = makeSocketPath()
        let server = try CLIWindowCommandMockServer(
            socketPath: socketPath,
            targetWindowID: windowID,
            targetWindowRef: windowRef,
            workspaces: [(id: workspaceID, ref: workspaceRef)],
            v1Replies: [
                "report_meta_block": "OK",
                "clear_meta_block": "OK",
                "list_meta_blocks": listing,
            ]
        )
        server.start()
        defer { server.stop() }

        let result = try runCLI(arguments: arguments, stdin: stdin, socketPath: socketPath)
        if waitForServer {
            #expect(server.waitUntilFinished(timeout: 5))
        }
        #expect(!result.timedOut, Comment(rawValue: result.output))
        return Run(result: result, lines: server.receivedLinesSnapshot(), server: server)
    }

    private static func runCLI(arguments: [String], stdin: String?, socketPath: String) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self))
        process.arguments = arguments
        process.environment = cliEnvironment(socketPath: socketPath)
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let inputPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if let inputPipe, let stdin {
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try inputPipe.fileHandleForWriting.close()
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
            output: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
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

    private static func makeSocketPath() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-meta-\(suffix).sock")
            .path
    }

    private static let windowID = "22222222-2222-2222-2222-222222222222"
    private static let windowRef = "window:2"
    private static let workspaceID = "44444444-4444-4444-4444-444444444444"
    private static let workspaceRef = "workspace:2"
    private static let listing = #"agent=**claude** · opus\n- 42% ctx priority=40"#

    private final class BundleToken {}

    private struct ProcessResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }
}
