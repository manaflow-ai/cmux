import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for WorkspaceRemoteDaemonPendingCallRegistry: request/response ID
/// matching, timeout cleanup, and transport failure propagation.
final class RemoteDaemonPendingCallRegistryTests: XCTestCase {

    // MARK: - Basic register/resolve cycle

    func testRegisterAndResolveReturnsResponse() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()

        let call = registry.register()
        XCTAssertEqual(call.id, 1)

        let payload: [String: Any] = ["ok": true, "result": ["version": "1.0"]]
        XCTAssertTrue(registry.resolve(id: call.id, payload: payload))

        let outcome = registry.wait(for: call, timeout: 1.0)
        guard case .response(let response) = outcome else {
            return XCTFail("Expected .response, got \(outcome)")
        }
        XCTAssertEqual(response["ok"] as? Bool, true)
    }

    // MARK: - Response ID mismatch

    /// Resolving with a non-matching ID returns false; the real call times out.
    func testResponseIDMismatchDropsResponse() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()

        let call = registry.register()
        XCTAssertFalse(registry.resolve(id: call.id + 999, payload: ["ok": true]))

        let outcome = registry.wait(for: call, timeout: 0.1)
        guard case .timedOut = outcome else {
            return XCTFail("Expected .timedOut, got \(outcome)")
        }
    }

    // MARK: - ok:false response handling

    /// {"ok": false} with no "error" field should fall through to default error
    /// strings in the RPC client's response parsing.
    func testOkFalseWithoutErrorPayloadUsesDefaults() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()

        let call = registry.register()
        registry.resolve(id: call.id, payload: ["id": call.id, "ok": false])

        guard case .response(let response) = registry.wait(for: call, timeout: 1.0) else {
            return XCTFail("Expected .response")
        }

        // Replicate the extraction logic from WorkspaceRemoteDaemonRPCClient.call
        XCTAssertEqual((response["ok"] as? Bool) ?? false, false)
        let errorObject = (response["error"] as? [String: Any]) ?? [:]
        XCTAssertEqual(
            (errorObject["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "rpc_error",
            "rpc_error"
        )
        XCTAssertEqual(
            (errorObject["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "daemon RPC call failed",
            "daemon RPC call failed"
        )
    }

    /// {"ok": false, "error": {...}} should surface the actual code and message.
    func testOkFalseWithErrorPayloadExtractsFields() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()

        let call = registry.register()
        registry.resolve(id: call.id, payload: [
            "id": call.id,
            "ok": false,
            "error": ["code": "auth_failed", "message": "authentication rejected"],
        ])

        guard case .response(let response) = registry.wait(for: call, timeout: 1.0) else {
            return XCTFail("Expected .response")
        }

        let errorObject = (response["error"] as? [String: Any]) ?? [:]
        XCTAssertEqual(errorObject["code"] as? String, "auth_failed")
        XCTAssertEqual(errorObject["message"] as? String, "authentication rejected")
    }

    // MARK: - failAll

    /// failAll should signal every pending call so none hang when the transport dies.
    func testFailAllSignalsAllPendingCalls() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()

        let call1 = registry.register()
        let call2 = registry.register()
        registry.failAll("transport closed")

        for (label, call) in [("call1", call1), ("call2", call2)] {
            guard case .failure(let msg) = registry.wait(for: call, timeout: 1.0) else {
                XCTFail("Expected .failure for \(label)")
                continue
            }
            XCTAssertEqual(msg, "transport closed")
        }
    }

    // MARK: - Reset

    func testResetClearsStateAndRestartsIDs() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()
        _ = registry.register()
        registry.reset()
        XCTAssertEqual(registry.register().id, 1)
    }

    // MARK: - Timeout cleanup

    func testTimeoutRemovesPendingCall() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()

        let call = registry.register()
        guard case .timedOut = registry.wait(for: call, timeout: 0.05) else {
            return XCTFail("Expected .timedOut")
        }

        XCTAssertFalse(
            registry.resolve(id: call.id, payload: ["ok": true]),
            "Resolve after timeout should return false"
        )
    }

    // MARK: - Sequential IDs

    func testSequentialIDAssignment() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()

        let calls = (0..<3).map { _ in registry.register() }
        XCTAssertEqual(calls.map(\.id), [1, 2, 3])

        calls.forEach { registry.remove($0) }
    }

    // MARK: - Double resolve safety

    func testDoubleResolveDoesNotCrash() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()

        let call = registry.register()
        XCTAssertTrue(registry.resolve(id: call.id, payload: ["ok": true, "attempt": 1]))
        // Second resolve: should not crash regardless of outcome.
        _ = registry.resolve(id: call.id, payload: ["ok": true, "attempt": 2])

        guard case .response = registry.wait(for: call, timeout: 1.0) else {
            return XCTFail("Expected .response after resolve")
        }
    }
}
