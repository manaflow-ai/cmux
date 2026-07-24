import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Wire-format tests for the multiplayer workspace share protocol
/// (plans/feat-multiplayer-share/DESIGN.md): outbound frame key names,
/// inbound frame decoding including unknown-type tolerance, replay capping,
/// and normalized-rect math.
final class WorkspaceShareProtocolTests: XCTestCase {
    private func json(_ frame: ShareOutboundFrame) throws -> [String: Any] {
        let data = try frame.encodedJSONData()
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Outbound encoding

    func testTermFrameUsesSnakeCaseDataKey() throws {
        let object = try json(.term(surfaceId: "abc", seq: 42, dataB64: "aGk="))
        XCTAssertEqual(object["type"] as? String, "term")
        XCTAssertEqual(object["surfaceId"] as? String, "abc")
        XCTAssertEqual(object["seq"] as? UInt64, 42)
        XCTAssertEqual(object["data_b64"] as? String, "aGk=")
        XCTAssertNil(object["dataB64"], "wire key must be data_b64 per DESIGN.md")
    }

    func testJoinResponseFrame() throws {
        let object = try json(.joinResponse(requestId: "r1", allow: true))
        XCTAssertEqual(object["type"] as? String, "join_response")
        XCTAssertEqual(object["requestId"] as? String, "r1")
        XCTAssertEqual(object["allow"] as? Bool, true)
    }

    func testTermResizeFrame() throws {
        let object = try json(.termResize(surfaceId: "s", cols: 120, rows: 40))
        XCTAssertEqual(object["type"] as? String, "term_resize")
        XCTAssertEqual(object["cols"] as? Int, 120)
        XCTAssertEqual(object["rows"] as? Int, 40)
    }

    func testSnapshotFrameTargetsOneViewerAndCarriesReplay() throws {
        let workspace = ShareWorkspace(
            title: "ws",
            size: ShareWorkspaceSize(width: 1512, height: 916),
            panes: [
                ShareWorkspacePane(
                    id: "p1",
                    kind: "terminal",
                    title: "zsh",
                    rect: ShareRect(x: 0, y: 0, w: 0.5, h: 1),
                    surfaceId: "u1",
                    cols: 80,
                    rows: 24,
                    replaySeq: 100,
                    replay_b64: "aGk="
                )
            ]
        )
        let object = try json(.snapshot(to: "viewer-1", workspace: workspace))
        XCTAssertEqual(object["type"] as? String, "snapshot")
        XCTAssertEqual(object["to"] as? String, "viewer-1")
        let workspaceObject = try XCTUnwrap(object["workspace"] as? [String: Any])
        let panes = try XCTUnwrap(workspaceObject["panes"] as? [[String: Any]])
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0]["replay_b64"] as? String, "aGk=")
        XCTAssertEqual(panes[0]["replaySeq"] as? UInt64, 100)
    }

    func testLayoutFrameOmitsReplayFields() throws {
        let workspace = ShareWorkspace(
            title: "ws",
            size: ShareWorkspaceSize(width: 100, height: 100),
            panes: [
                ShareWorkspacePane(
                    id: "p1",
                    kind: "browser",
                    title: "docs",
                    rect: ShareRect(x: 0, y: 0, w: 1, h: 1)
                )
            ]
        )
        let object = try json(.layout(workspace: workspace))
        let workspaceObject = try XCTUnwrap(object["workspace"] as? [String: Any])
        let panes = try XCTUnwrap(workspaceObject["panes"] as? [[String: Any]])
        XCTAssertNil(panes[0]["replay_b64"])
        XCTAssertNil(panes[0]["replaySeq"])
        XCTAssertNil(panes[0]["surfaceId"])
    }

    func testEndFrame() throws {
        let object = try json(.end)
        XCTAssertEqual(object["type"] as? String, "end")
        XCTAssertEqual(object.count, 1)
    }

    // MARK: - Inbound decoding

    private func decode(_ jsonString: String) throws -> ShareInboundFrame {
        try ShareInboundFrame.decode(fromJSONData: Data(jsonString.utf8))
    }

    func testDecodeJoinRequest() throws {
        let frame = try decode(
            #"{"type":"join_request","requestId":"r9","email":"a@b.c","name":"Ada"}"#
        )
        XCTAssertEqual(frame, .joinRequest(requestId: "r9", email: "a@b.c", name: "Ada"))
    }

    func testDecodeSyncRequest() throws {
        let frame = try decode(#"{"type":"sync_request","participantId":"v1"}"#)
        XCTAssertEqual(frame, .syncRequest(participantId: "v1"))
    }

    func testDecodeCursorWithStampedParticipant() throws {
        let frame = try decode(#"{"type":"cursor","participantId":"v2","x":0.25,"y":0.75}"#)
        XCTAssertEqual(frame, .cursor(participantId: "v2", x: 0.25, y: 0.75))
    }

    func testDecodeChat() throws {
        let frame = try decode(
            #"{"type":"chat","participantId":"v3","ts":1700000000.5,"text":"hi","x":0.1,"y":0.2}"#
        )
        XCTAssertEqual(frame, .chat(participantId: "v3", ts: 1_700_000_000.5, text: "hi", x: 0.1, y: 0.2))
    }

    func testDecodePresence() throws {
        let frame = try decode(
            #"{"type":"presence","participants":[{"id":"h","email":"h@x.y","name":"Host","color":0,"role":"host"}]}"#
        )
        guard case .presence(let participants) = frame else {
            return XCTFail("expected presence, got \(frame)")
        }
        XCTAssertEqual(participants.count, 1)
        XCTAssertTrue(participants[0].isHost)
        XCTAssertEqual(participants[0].color, 0)
    }

    func testDecodeEnded() throws {
        XCTAssertEqual(try decode(#"{"type":"ended"}"#), .ended)
    }

    func testUnknownFrameTypeDoesNotThrow() throws {
        let frame = try decode(#"{"type":"totally_new_thing","whatever":1}"#)
        XCTAssertEqual(frame, .unknown(type: "totally_new_thing"))
    }

    // MARK: - Replay cap

    func testReplayCapKeepsTailWithinBase64Budget() {
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        let capped = WorkspaceShareReplayCap.cappedReplayTail(data)
        // 256 KB base64 budget => 192 KB raw.
        XCTAssertEqual(capped.count, (256 * 1024 / 4) * 3)
        XCTAssertEqual(capped, data.suffix(capped.count), "cap must keep the most recent bytes")
        XCTAssertLessThanOrEqual(
            capped.base64EncodedString().utf8.count,
            WorkspaceShareReplayCap.maximumBase64ByteCount
        )
    }

    func testReplayCapPassesSmallDataThrough() {
        let data = Data(repeating: 7, count: 1024)
        XCTAssertEqual(WorkspaceShareReplayCap.cappedReplayTail(data), data)
    }

    // MARK: - Layout math

    func testNormalizedRectForRightHalfPane() {
        let container = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let pane = CGRect(x: 600, y: 50, width: 500, height: 800)
        let rect = WorkspaceShareLayoutMath.normalizedRect(paneFrame: pane, container: container)
        XCTAssertEqual(rect.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rect.y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(rect.w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rect.h, 1.0, accuracy: 1e-9)
    }

    func testNormalizedRectClampsOverflow() {
        let container = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pane = CGRect(x: 90, y: -10, width: 40, height: 200)
        let rect = WorkspaceShareLayoutMath.normalizedRect(paneFrame: pane, container: container)
        XCTAssertEqual(rect.x, 0.9, accuracy: 1e-9)
        XCTAssertEqual(rect.y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(rect.x + rect.w, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rect.y + rect.h, 1.0, accuracy: 1e-9)
    }

    func testNormalizedRectZeroContainerIsSafe() {
        let rect = WorkspaceShareLayoutMath.normalizedRect(
            paneFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
            container: .zero
        )
        XCTAssertEqual(rect, ShareRect(x: 0, y: 0, w: 0, h: 0))
    }

    func testNormalizedPointInsideAndOutside() {
        let container = CGRect(x: 100, y: 100, width: 200, height: 100)
        let inside = WorkspaceShareLayoutMath.normalizedPoint(CGPoint(x: 200, y: 150), container: container)
        XCTAssertEqual(inside?.x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(inside?.y ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(WorkspaceShareLayoutMath.normalizedPoint(CGPoint(x: 50, y: 50), container: container))
    }

    // MARK: - Endpoints

    func testHostSocketURLUpgradesSchemeAndCarriesToken() throws {
        let https = try XCTUnwrap(WorkspaceShareEndpoints.hostSocketURL(
            base: URL(string: "https://share.cmux.dev")!,
            shareId: "abc123",
            hostToken: "tok"
        ))
        XCTAssertEqual(https.scheme, "wss")
        XCTAssertEqual(https.path, "/v1/share/abc123/host")
        XCTAssertEqual(https.query, "token=tok")

        let http = try XCTUnwrap(WorkspaceShareEndpoints.hostSocketURL(
            base: URL(string: "http://127.0.0.1:8787")!,
            shareId: "abc123",
            hostToken: "tok"
        ))
        XCTAssertEqual(http.scheme, "ws")
        XCTAssertEqual(http.port, 8787)
    }

    func testServiceBaseURLDefaultsOverride() {
        let defaults = UserDefaults(suiteName: "WorkspaceShareProtocolTests")!
        defaults.removePersistentDomain(forName: "WorkspaceShareProtocolTests")
        XCTAssertEqual(
            WorkspaceShareEndpoints.serviceBaseURL(defaults: defaults),
            WorkspaceShareEndpoints.defaultServiceURL
        )
        defaults.set("http://127.0.0.1:8787", forKey: WorkspaceShareEndpoints.serviceURLDefaultsKey)
        XCTAssertEqual(
            WorkspaceShareEndpoints.serviceBaseURL(defaults: defaults).absoluteString,
            "http://127.0.0.1:8787"
        )
        defaults.removePersistentDomain(forName: "WorkspaceShareProtocolTests")
    }
}
