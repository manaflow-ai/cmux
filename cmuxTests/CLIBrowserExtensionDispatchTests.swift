import XCTest
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux browser <surface> extension ...` must reach the
/// `browser.extension.*` socket methods instead of failing as an unknown
/// browser subcommand.
extension CLINotifyProcessIntegrationRegressionTests {
    func testBrowserExtensionListSendsExtensionListForTheSurface() throws {
        let surfaceId = UUID().uuidString
        let result = try runBrowserExtensionCLI(
            name: "browser-ext-list",
            arguments: ["browser", surfaceId, "extension", "list"],
            respond: { method, id in
                method == "browser.extension.list"
                    ? self.v2Response(id: id, ok: true, result: ["surface_id": surfaceId, "extensions": [Any](), "commands": [Any]()])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        XCTAssertTrue(
            result.commands.contains { $0.contains(#""method":"browser.extension.list""#) && $0.contains(surfaceId) },
            "Expected browser.extension.list for \(surfaceId), saw \(result.commands)"
        )
    }

    func testBrowserExtensionPinSendsTheExtension() throws {
        let surfaceId = UUID().uuidString
        let extensionId = String(repeating: "a", count: 32)
        let result = try runBrowserExtensionCLI(
            name: "browser-ext-pin",
            arguments: ["browser", "--surface", surfaceId, "extension", "pin", extensionId],
            respond: { method, id in
                method == "browser.extension.pin"
                    ? self.v2Response(id: id, ok: true, result: ["surface_id": surfaceId, "extension_id": extensionId])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        XCTAssertTrue(
            result.commands.contains { $0.contains(#""method":"browser.extension.pin""#) && $0.contains(extensionId) },
            "Expected browser.extension.pin for \(extensionId), saw \(result.commands)"
        )
    }

    private func runBrowserExtensionCLI(
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
