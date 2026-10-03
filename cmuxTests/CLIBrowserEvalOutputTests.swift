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

    @Test("browser cookies set forwards the HttpOnly flag")
    func browserCookiesSetForwardsHTTPOnly() throws {
        let socketPath = "/tmp/cmux-cookies-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"id":null,"ok":true,"result":{"set":1}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let surfaceID = UUID().uuidString

        let result = try runProcess(
            executablePath: BundledCLITestSupport.bundledCLIPath(for: Self.self),
            arguments: [
                "browser", surfaceID, "cookies", "set", "session", "secret",
                "--url", "https://example.test/", "--http-only",
            ],
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let request = try #require(responder.receivedRequests.first)
        let requestData = try #require(request.data(using: .utf8))
        let requestObject = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(requestObject["method"] as? String == "browser.cookies.set")
        let params = try #require(requestObject["params"] as? [String: Any])
        #expect(params["surface_id"] as? String == surfaceID)
        #expect(params["httpOnly"] as? Bool == true)
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

    @Test("browser value formatter sanitizes nested JSON format characters")
    func browserValueFormatterSanitizesNestedJSONFormatCharacters() {
        let formatter = BrowserValueTextFormatter()
        let value: [String: Any] = [
            "items": [["message": "before\u{202E}after"]],
        ]

        let output = formatter.string(from: value)

        #expect(output.contains("before�after"))
        #expect(!output.contains("\u{202E}"))
        #expect(output.contains("\n"))
    }

    @Test("browser value formatter preserves distinct sanitized dictionary keys")
    func browserValueFormatterPreservesDistinctSanitizedDictionaryKeys() {
        let formatter = BrowserValueTextFormatter()
        let value: [String: Any] = [
            "a\u{202E}": "first",
            "a\u{2066}": "second",
            "a\\u{202E}": "literal escape",
        ]

        let output = formatter.string(from: value)

        #expect(output.contains("first"))
        #expect(output.contains("second"))
        #expect(output.contains("literal escape"))
        #expect(!output.contains("\u{202E}"))
        #expect(!output.contains("\u{2066}"))
    }

    @Test("browser storage text output cannot emit terminal control characters")
    func browserStorageTextOutputSanitizesTerminalControlCharacters() throws {
        let responseObject: [String: Any] = [
            "id": NSNull(),
            "ok": true,
            "result": [
                "type": "local",
                "key": "unsafe",
                "value": "\u{001B}[2J\u{0007}stored",
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        let response = try #require(String(data: responseData, encoding: .utf8))
        let socketPath = "/tmp/cmux-browser-storage-\(UUID().uuidString.prefix(8)).sock"
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
            arguments: ["browser", "surface:1", "storage", "local", "get", "unsafe"],
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.output.debugDescription))
        #expect(result.status == 0, Comment(rawValue: result.output.debugDescription))
        #expect(result.output == "�[2J�stored\n", Comment(rawValue: result.output.debugDescription))
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

    @Test("browser collection reads reject successful responses without collection fields")
    func browserCollectionReadsRejectMissingResponseFields() throws {
        let cases = [
            (name: "cookies", arguments: ["browser", "surface:1", "cookies", "get"]),
            (name: "tabs", arguments: ["browser", "surface:1", "tab", "list"]),
        ]
        let response = #"{"id":null,"ok":true,"result":{"surface_ref":"surface:1"}}"#

        for testCase in cases {
            let socketPath = "/tmp/cmux-browser-missing-field-\(UUID().uuidString.prefix(8)).sock"
            let responder = try UnixSocketResponder(path: socketPath, response: response)

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
            responder.stop()

            #expect(!result.timedOut, Comment(rawValue: "\(testCase.name): \(result.output.debugDescription)"))
            #expect(result.status == 1, Comment(rawValue: "\(testCase.name): \(result.output.debugDescription)"))
            #expect(result.output.contains("Error:"), Comment(rawValue: "\(testCase.name): \(result.output.debugDescription)"))
            #expect(result.output != "[]\n", Comment(rawValue: "\(testCase.name): \(result.output.debugDescription)"))
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
