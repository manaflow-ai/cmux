import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Workspace worker aliases and heartbeat dispatch
extension TerminalControllerSocketSecurityTests {
    func testWorkspaceWorkerMethodRejectsWindowAliasInsteadOfDefaultWindowFallback() async throws {
        let socketPath = makeSocketPath("alias-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let params: [String: Any] = ["window": "window:2"]
        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_sessions",
            params: params
        )

        let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
        let mainError = try XCTUnwrap(mainEnvelope["error"] as? [String: Any])
        XCTAssertEqual(mainError["code"] as? String, "invalid_dispatch")

        let workerEnvelope = try await sendV2RequestAsync(
            method: "workspace.remote.pty_sessions",
            params: params,
            to: socketPath
        )
        try assertUnsupportedWorkspaceWindowAlias(workerEnvelope)
    }

    func testHeartbeatMethodsSupportInProcessAndSocketDispatch() async throws {
        let socketPath = makeSocketPath("heartbeat-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        for method in ["system.ping", "system.capabilities"] {
            let requestLine = try makeV2RequestLine(method: method, params: [:])
            let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
            XCTAssertEqual(mainEnvelope["ok"] as? Bool, true, method)
            try assertHeartbeatResult(method: method, envelope: mainEnvelope)

            let workerEnvelope = try await sendV2RequestAsync(method: method, params: [:], to: socketPath)
            XCTAssertEqual(workerEnvelope["ok"] as? Bool, true, method)
            try assertHeartbeatResult(method: method, envelope: workerEnvelope)
        }
    }

    private func assertHeartbeatResult(method: String, envelope: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try XCTUnwrap(envelope["result"] as? [String: Any], method, file: file, line: line)
        switch method {
        case "system.ping":
            XCTAssertEqual(result["pong"] as? Bool, true, file: file, line: line)
        case "system.capabilities":
            let methods = try XCTUnwrap(result["methods"] as? [String], method, file: file, line: line)
            let advertisedMethods = Set(methods)
            let expectedMethods: Set<String> = [
                "system.ping",
                "system.capabilities",
                "mobile.host.status",
                "mobile.attach_ticket.create",
                "mobile.workspace.list",
                "workspace.list",
                "workspace.create",
                "mobile.terminal.create",
                "terminal.create",
                "mobile.terminal.input",
                "terminal.input",
                "mobile.terminal.replay",
                "terminal.replay",
                "mobile.terminal.viewport",
                "terminal.viewport",
                "mobile.events.subscribe",
                "mobile.events.unsubscribe",
            ]
            XCTAssertTrue(
                expectedMethods.isSubset(of: advertisedMethods),
                "Missing capabilities: \(expectedMethods.subtracting(advertisedMethods).sorted())",
                file: file,
                line: line
            )
        default:
            XCTFail("Unexpected heartbeat method \(method)", file: file, line: line)
        }
    }

    private func assertUnsupportedWorkspaceWindowAlias(
        _ envelope: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(envelope["ok"] as? Bool, false, file: file, line: line)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(error["code"] as? String, "invalid_params", file: file, line: line)
        let data = try XCTUnwrap(error["data"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(data["unsupported_param"] as? String, "window", file: file, line: line)
        XCTAssertEqual(data["supported_param"] as? String, "window_id", file: file, line: line)
    }

}
