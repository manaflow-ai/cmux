import Foundation
import Testing

@Suite(.serialized)
final class CLIBrowserEvalOutputTests {
    private struct Case {
        let name: String
        let wireValue: String
        let expectedOutput: String
    }

    // https://github.com/manaflow-ai/cmux/issues/8055
    @Test("browser eval preserves scalar values in text output")
    func browserEvalPreservesScalarValues() throws {
        let cases = [
            Case(name: "integer zero", wireValue: "0", expectedOutput: "0"),
            Case(name: "floating-point zero", wireValue: "0.0", expectedOutput: "0"),
            Case(name: "integer one", wireValue: "1", expectedOutput: "1"),
            Case(name: "floating-point one", wireValue: "1.0", expectedOutput: "1"),
            Case(name: "false", wireValue: "false", expectedOutput: "false"),
            Case(name: "true", wireValue: "true", expectedOutput: "true"),
            Case(name: "empty string", wireValue: "\"\"", expectedOutput: ""),
            Case(name: "null", wireValue: "null", expectedOutput: "null"),
            Case(
                name: "undefined envelope",
                wireValue: #"{"__cmux_t":"undefined","__cmux_v":null}"#,
                expectedOutput: "undefined"
            ),
        ]

        for testCase in cases {
            try assertBrowserEvalOutput(testCase)
        }
    }

    @Test("browser value formatter distinguishes booleans from every numeric representation")
    func browserValueFormatterPreservesFoundationScalarTypes() {
        let formatter = BrowserValueTextFormatter()

        #expect(formatter.string(from: NSNumber(value: false)) == "false")
        #expect(formatter.string(from: NSNumber(value: true)) == "true")
        #expect(formatter.string(from: NSNumber(value: 0)) == "0")
        #expect(formatter.string(from: NSNumber(value: 0.0)) == "0")
        #expect(formatter.string(from: NSNumber(value: 1)) == "1")
        #expect(formatter.string(from: NSNumber(value: 1.0)) == "1")
        #expect(formatter.string(from: NSNumber(value: Double.nan)) == "NaN")
        #expect(formatter.string(from: NSNumber(value: Double.infinity)) == "Infinity")
        #expect(formatter.string(from: NSNumber(value: -Double.infinity)) == "-Infinity")
        #expect(formatter.string(from: "") == "")
        #expect(formatter.string(from: NSNull()) == "null")
        #expect(formatter.string(from: [Any]()) == "[]")
        #expect(formatter.string(from: [String: Any]()) == "{}")
    }

    private struct BrowserReadCase {
        let name: String
        let arguments: [String]
        let responses: [String]
        let expectedFragments: [String]
    }

    @Test("browser read commands render payloads in text output")
    func browserReadCommandsRenderPayloadsInTextOutput() throws {
        let cases = [
            BrowserReadCase(
                name: "identify",
                arguments: ["browser", "surface:1", "identify"],
                responses: [
                    #"{"id":null,"ok":true,"result":{"workspace_ref":"workspace:7","focused":{"surface_ref":"surface:1"}}}"#,
                    #"{"id":null,"ok":true,"result":{"url":"https://example.com"}}"#,
                    #"{"id":null,"ok":true,"result":{"title":"Example"}}"#,
                ],
                expectedFragments: ["workspace:7", "Example"]
            ),
            BrowserReadCase(
                name: "cookies default get",
                arguments: ["browser", "surface:1", "cookies"],
                responses: [
                    #"{"id":null,"ok":true,"result":{"surface_ref":"surface:1","cookies":[{"name":"session","value":"abc"}]}}"#,
                ],
                expectedFragments: ["session", "abc"]
            ),
            BrowserReadCase(
                name: "cookies empty result",
                arguments: ["browser", "surface:1", "cookies", "get", "--name", "missing"],
                responses: [
                    #"{"id":null,"ok":true,"result":{"surface_ref":"surface:1","cookies":[]}}"#,
                ],
                expectedFragments: ["[]"]
            ),
            BrowserReadCase(
                name: "storage default get",
                arguments: ["browser", "surface:1", "storage", "local", "get"],
                responses: [
                    #"{"id":null,"ok":true,"result":{"type":"local","key":null,"value":{"theme":"dark"}}}"#,
                ],
                expectedFragments: ["theme", "dark"]
            ),
            BrowserReadCase(
                name: "tab default list",
                arguments: ["browser", "surface:1", "tab"],
                responses: [
                    #"{"id":null,"ok":true,"result":{"surface_ref":"surface:1","tabs":[{"ref":"surface:2","title":"Second"}]}}"#,
                ],
                expectedFragments: ["surface:2", "Second"]
            ),
        ]

        for testCase in cases {
            try assertBrowserReadOutput(testCase)
        }
    }

    private func assertBrowserEvalOutput(_ testCase: Case) throws {
        let socketPath = "/tmp/cmux-eval-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"id":null,"ok":true,"result":{"value":\#(testCase.wireValue)}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = try runProcess(
            executablePath: BundledCLITestSupport.bundledCLIPath(for: Self.self),
            arguments: ["browser", UUID().uuidString, "eval", "0"],
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: "\(testCase.name): \(result.output)"))
        #expect(result.status == 0, Comment(rawValue: "\(testCase.name): \(result.output)"))
        #expect(
            result.output == testCase.expectedOutput + "\n",
            Comment(rawValue: "\(testCase.name): \(result.output.debugDescription)")
        )
    }

    private func assertBrowserReadOutput(_ testCase: BrowserReadCase) throws {
        let socketPath = "/tmp/cmux-browser-read-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, responses: testCase.responses)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = try runProcess(
            executablePath: BundledCLITestSupport.bundledCLIPath(for: Self.self),
            arguments: testCase.arguments,
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: "\(testCase.name): \(result.output)"))
        #expect(result.status == 0, Comment(rawValue: "\(testCase.name): \(result.output)"))
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output != "OK", Comment(rawValue: "\(testCase.name): \(result.output.debugDescription)"))
        for fragment in testCase.expectedFragments {
            #expect(
                output.contains(fragment),
                Comment(rawValue: "\(testCase.name) missing \(fragment.debugDescription): \(output.debugDescription)")
            )
        }
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String, timedOut: Bool) {
        let process = Process()
        let outputPipe = Pipe()
        let exited = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            status: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
