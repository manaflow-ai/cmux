@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class WorkspaceRemoteDaemonPendingCallRegistryTests: XCTestCase {
    func testSupportsMultiplePendingCallsResolvedOutOfOrder() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()
        let first = registry.register()
        let second = registry.register()

        XCTAssertTrue(registry.resolve(id: second.id, payload: [
            "ok": true,
            "result": ["stream_id": "second"],
        ]))

        switch registry.wait(for: second, timeout: 0.1) {
        case .response(let response):
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual((response["result"] as? [String: String])?["stream_id"], "second")
        default:
            XCTFail("second pending call should complete independently")
        }

        XCTAssertTrue(registry.resolve(id: first.id, payload: [
            "ok": true,
            "result": ["stream_id": "first"],
        ]))

        switch registry.wait(for: first, timeout: 0.1) {
        case .response(let response):
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual((response["result"] as? [String: String])?["stream_id"], "first")
        default:
            XCTFail("first pending call should remain pending until its own response arrives")
        }
    }

    func testFailAllSignalsEveryPendingCall() {
        let registry = WorkspaceRemoteDaemonPendingCallRegistry()
        let first = registry.register()
        let second = registry.register()

        registry.failAll("daemon transport stopped")

        switch registry.wait(for: first, timeout: 0.1) {
        case .failure(let message):
            XCTAssertEqual(message, "daemon transport stopped")
        default:
            XCTFail("first pending call should receive shared failure")
        }

        switch registry.wait(for: second, timeout: 0.1) {
        case .failure(let message):
            XCTAssertEqual(message, "daemon transport stopped")
        default:
            XCTFail("second pending call should receive shared failure")
        }
    }
}

