import XCTest
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux agent hibernate|wake <surface>` must reach the local hibernation
/// methods, not the cloud `vm agent` alias that owns the rest of `cmux agent`.
extension CLINotifyProcessIntegrationRegressionTests {
    func testAgentHibernateSendsAgentHibernateForTheSurface() throws {
        let surfaceId = UUID().uuidString
        let result = try runAgentHibernationCLI(
            name: "agent-hibernate",
            arguments: ["agent", "hibernate", surfaceId],
            respond: { method, id in
                method == "agent.hibernate"
                    ? self.v2Response(id: id, ok: true, result: ["surface_id": surfaceId, "hibernated": true])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        XCTAssertTrue(
            result.commands.contains { $0.contains(#""method":"agent.hibernate""#) && $0.contains(surfaceId) },
            "Expected agent.hibernate for \(surfaceId), saw \(result.commands)"
        )
        XCTAssertFalse(result.commands.contains { $0.contains(#""method":"vm."#) }, "\(result.commands)")
    }

    func testAgentHibernationWakeSendsAgentWake() throws {
        let surfaceId = UUID().uuidString
        let result = try runAgentHibernationCLI(
            name: "agent-wake",
            arguments: ["agent-hibernation", "wake", surfaceId],
            respond: { method, id in
                method == "agent.wake"
                    ? self.v2Response(id: id, ok: true, result: ["surface_id": surfaceId, "woke": true])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        XCTAssertTrue(
            result.commands.contains { $0.contains(#""method":"agent.wake""#) && $0.contains(surfaceId) },
            "Expected agent.wake for \(surfaceId), saw \(result.commands)"
        )
    }

    func testAgentHibernateReportsTheAppsRefusal() throws {
        let surfaceId = UUID().uuidString
        let result = try runAgentHibernationCLI(
            name: "agent-hibernate-refused",
            arguments: ["agent", "hibernate", surfaceId],
            respond: { method, id in
                method == "agent.hibernate"
                    ? self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "visible", "message": "This agent is on screen. Switch away from it first."]
                    )
                    : nil
            }
        )
        XCTAssertNotEqual(result.process.status, 0)
        XCTAssertTrue(result.process.stderr.contains("on screen"), result.process.stderr)
    }

    private func runAgentHibernationCLI(
        name: String,
        arguments: [String],
        respond: @escaping (_ method: String, _ id: String) -> String?
    ) throws -> (process: ProcessRunResult, commands: [String]) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return respond(method, id) ?? self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        return (result, state.commands)
    }
}
