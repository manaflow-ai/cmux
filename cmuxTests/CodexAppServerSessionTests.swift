import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CodexAppServerSessionTests: XCTestCase {
    func testEncodesPromptAsJSONRPCInsteadOfRawStdin() throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: "/tmp/cmux-agent-session-test",
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try session.start()
        XCTAssertEqual(jsonLine(sentLines[0])["method"] as? String, "initialize")

        session.consumeStdout(#"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"# + "\n")
        XCTAssertEqual(jsonLine(sentLines[1])["method"] as? String, "initialized")

        let threadStart = jsonLine(sentLines[2])
        XCTAssertEqual(threadStart["method"] as? String, "thread/start")
        let threadParams = try XCTUnwrap(threadStart["params"] as? [String: Any])
        XCTAssertEqual(threadParams["cwd"] as? String, "/tmp/cmux-agent-session-test")

        try session.submit("hello codex")
        XCTAssertEqual(sentLines.count, 3, "Prompt should queue until thread/start returns a thread id.")

        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        let turnStart = jsonLine(sentLines[3])
        XCTAssertEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"] as? [String: Any])
        XCTAssertEqual(turnParams["threadId"] as? String, "thread-1")
        let input = try XCTUnwrap(turnParams["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "text")
        XCTAssertEqual(input.first?["text"] as? String, "hello codex")

        for line in sentLines {
            XCTAssertTrue(line.hasPrefix("{"), "Codex app-server stdin must stay JSON-RPC, got \(line)")
        }
    }

    func testMapsAgentMessageDeltaToStdout() {
        var output: [(String, String)] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { stream, text in output.append((stream, text)) }
        )

        session.consumeStdout(#"{"method":"item/agentMessage/delta","params":{"delta":"partial answer"}}"# + "\n")

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.0, "stdout")
        XCTAssertEqual(output.first?.1, "partial answer")
    }

    private func jsonLine(_ rawLine: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let data = rawLine.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            XCTFail("Expected JSON object", file: file, line: line)
            return [:]
        }
        return object
    }
}
