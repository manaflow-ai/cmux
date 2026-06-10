import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateIssue2907RoutingTests: XCTestCase {
    func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    private func decodeV2Response(_ response: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try XCTUnwrap(response.data(using: .utf8), file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    func v2Envelope(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (raw: String, envelope: [String: Any]) {
        let request: [String: Any] = [
            "id": id ?? method,
            "method": method,
            "params": params
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try XCTUnwrap(String(data: requestData, encoding: .utf8), file: file, line: line)
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        return (raw, try decodeV2Response(raw, file: file, line: line))
    }

    func v2Result(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let (raw, envelope) = try v2Envelope(method: method, params: params, id: id, file: file, line: line)
        XCTAssertEqual(envelope["ok"] as? Bool, true, raw, file: file, line: line)
        return try XCTUnwrap(envelope["result"] as? [String: Any], raw, file: file, line: line)
    }

    func v2Error(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let (raw, envelope) = try v2Envelope(method: method, params: params, id: id, file: file, line: line)
        XCTAssertEqual(envelope["ok"] as? Bool, false, raw, file: file, line: line)
        return try XCTUnwrap(envelope["error"] as? [String: Any], raw, file: file, line: line)
    }

    func workspaceListPayload(surfaceId: UUID, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try v2Result(
            method: "workspace.list",
            params: ["surface_id": surfaceId.uuidString],
            id: "workspace-list",
            file: file,
            line: line
        )
    }

    func assertWorkspaceListContains(
        _ payload: [String: Any],
        workspaceId: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let workspaces = try XCTUnwrap(payload["workspaces"] as? [[String: Any]], file: file, line: line)
        XCTAssertTrue(
            workspaces.contains { ($0["id"] as? String) == workspaceId.uuidString },
            "workspace.list should include \(workspaceId.uuidString)",
            file: file,
            line: line
        )
    }

}
