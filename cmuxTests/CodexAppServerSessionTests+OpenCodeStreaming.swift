import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif


// MARK: - OpenCode server auth, event stream parsing, and output line buffering
extension CodexAppServerSessionTests {
    @Test
    func testOpenCodeAuthHeaderMatchesServerEnvironment() {
        expectNil(OpenCodeServerAuth(environment: [:]))
        expectNil(OpenCodeServerAuth(environment: ["OPENCODE_SERVER_PASSWORD": ""]))

        expectEqual(
            OpenCodeServerAuth(environment: ["OPENCODE_SERVER_PASSWORD": "secret"])?.authorizationHeader,
            "Basic b3BlbmNvZGU6c2VjcmV0"
        )
        expectEqual(
            OpenCodeServerAuth(environment: [
                "OPENCODE_SERVER_USERNAME": "cmux",
                "OPENCODE_SERVER_PASSWORD": "secret",
            ])?.authorizationHeader,
            "Basic Y211eDpzZWNyZXQ="
        )
    }

    @Test
    func testOpenCodeEventStreamParserDecodesDataEvents() {
        var parser = OpenCodeEventStreamParser()

        expectEqual(parser.consumeLine("event: message").count, 0)
        expectEqual(parser.consumeLine(#"data: {"type":"server.connected","properties":{}}"#).count, 0)
        let events = parser.consumeLine("")

        expectEqual(events.count, 1)
        expectEqual(events.first?["type"] as? String, "server.connected")
    }

    @Test
    func testOpenCodeEventStreamParserBoundsUnterminatedDataEvents() {
        var parser = OpenCodeEventStreamParser()

        expectEqual(parser.consumeLine("data: \(String(repeating: "a", count: 1024 * 1024 + 1))").count, 0)
        expectEqual(parser.consumeLine("").count, 0)
        expectEqual(parser.consumeLine(#"data: {"type":"server.connected","properties":{}}"#).count, 0)

        let events = parser.consumeLine("")

        expectEqual(events.count, 1)
        expectEqual(events.first?["type"] as? String, "server.connected")
    }

    @Test
    func testAgentSessionOutputLineBufferBoundsNewlineFreeOutput() {
        var buffer = AgentSessionOutputLineBuffer()
        let oversizedLine = Data(repeating: 97, count: 2 * 1024 * 1024 + 5)

        let lines = buffer.append(oversizedLine)

        expectEqual(lines.count, 2)
        expectTrue(lines.allSatisfy { $0.hasSuffix("\n") })
        expectTrue(lines.allSatisfy { $0.count <= 1024 * 1024 + 1 })
        expectEqual(buffer.bufferedByteCountForTesting, 5)
        expectEqual(buffer.flush(), [String(repeating: "a", count: 5)])
    }

    @Test
    func testAgentSessionOutputLineBufferPreservesNormalNewlineFrames() {
        var buffer = AgentSessionOutputLineBuffer()

        expectEqual(buffer.append(Data("hello\npartial".utf8)), ["hello\n"])
        expectEqual(buffer.bufferedByteCountForTesting, "partial".utf8.count)
        expectEqual(buffer.append(Data(" line\n".utf8)), ["partial line\n"])
        expectEqual(buffer.flush(), [])
    }

    @Test
    func testOpenCodeProcessStdoutLogsAreNotAssistantOutput() throws {
        let serverURL = try #require(URL(string: "http://127.0.0.1:49211"))

        expectEqual(
            AgentSessionProcessStore.openCodeProcessOutputDisposition(
                text: "opencode server listening on http://127.0.0.1:49211\n",
                stream: "stdout"
            ),
            .serverURL(serverURL)
        )
        expectEqual(
            AgentSessionProcessStore.openCodeProcessOutputDisposition(
                text: "INFO request completed\n",
                stream: "stdout"
            ),
            .suppress
        )
        expectEqual(
            AgentSessionProcessStore.openCodeProcessOutputDisposition(
                text: "OpenCode session could not be created.\n",
                stream: "stderr"
            ),
            .emit
        )
    }

    @Test
    func testOpenCodeEventStreamEOFPolicyFailsOnlyForLiveSession() {
        expectTrue(
            AgentSessionProcessStore.openCodeEventStreamEOFRequiresFailure(
                isCancelled: false,
                processIsRunning: true
            )
        )
        expectFalse(
            AgentSessionProcessStore.openCodeEventStreamEOFRequiresFailure(
                isCancelled: true,
                processIsRunning: true
            )
        )
        expectFalse(
            AgentSessionProcessStore.openCodeEventStreamEOFRequiresFailure(
                isCancelled: false,
                processIsRunning: false
            )
        )
    }

}
