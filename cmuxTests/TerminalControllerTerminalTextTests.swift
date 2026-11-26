import XCTest
import Darwin
import Foundation
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalControllerTerminalTextTests: XCTestCase {
    func testTailTerminalLinesPreservesSplitSuffixSemanticsWithoutFullSplit() {
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb\nc", maxLines: 2), "b\nc")
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb\n", maxLines: 2), "b\n")
        XCTAssertEqual(TerminalController.tailTerminalLines("a", maxLines: 2), "a")
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb", maxLines: 0), "")
    }

    func testTerminalTextPayloadTailsScrollbackBeforeEncoding() throws {
        let result = TerminalController.terminalTextPayload(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: nil,
                screen: "old\nscreen",
                history: "one\ntwo\nthree",
                active: "four\nfive"
            ),
            includeScrollback: true,
            lineLimit: 3
        )
        let payload = try result.get()

        XCTAssertEqual(payload.text, "three\nfour\nfive")
        XCTAssertEqual(payload.base64, Data("three\nfour\nfive".utf8).base64EncodedString())
    }

    func testNotRunningReplyForHibernatedTerminalCarriesWakeCommand() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let result = TerminalController.readTextTerminalNotRunningResult(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            reason: .hibernated
        )
        guard case let .err(code, message, rawData) = result else {
            return XCTFail("expected an error reply")
        }
        let data = try XCTUnwrap(rawData as? [String: Any])
        let expectedCommand = "cmux focus-panel --workspace \(workspaceID.uuidString) --panel \(surfaceID.uuidString)"
        XCTAssertEqual(code, "surface_unavailable")
        XCTAssertEqual(data["reason"] as? String, "hibernated")
        XCTAssertEqual(data["surface_id"] as? String, surfaceID.uuidString)
        XCTAssertEqual(data["workspace_id"] as? String, workspaceID.uuidString)
        XCTAssertEqual(data["wake_command"] as? String, expectedCommand)
        XCTAssertTrue(message.contains(expectedCommand))
    }

    func testNotRunningReplyOmitsWakeCommandForSelfResolvingStates() throws {
        for reason in [TerminalSurfaceRuntimeUnavailableReason.awaitingRestore, .starting, .closing] {
            let result = TerminalController.readTextTerminalNotRunningResult(
                workspaceID: UUID(),
                surfaceID: UUID(),
                reason: reason
            )
            guard case let .err(code, _, rawData) = result else {
                return XCTFail("expected an error reply for \(reason)")
            }
            let data = try XCTUnwrap(rawData as? [String: Any])
            XCTAssertEqual(code, "surface_unavailable")
            XCTAssertEqual(data["reason"] as? String, reason.rawValue)
            XCTAssertNil(data["wake_command"], "\(reason) has no wake command")
        }
    }
}
