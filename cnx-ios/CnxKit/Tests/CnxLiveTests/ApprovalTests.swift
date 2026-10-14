import CnxAgentChat
import CnxTransport
import CryptoKit
import Foundation
import Testing
@testable import CnxLive

/// Phone-signed approvals (verify/phone-approvals.md): the signed bytes match
/// acpmux and cnx-hostd byte for byte (same vectors as their Rust tests), and
/// the hub signs an Allow or an answer, never a deny.
@Suite struct ApprovalPayloadTests {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static let answers: JSONValue = .object([
        "Which?": .string("B"),
        "a\"b": .array([.string("x\ny"), .string("\u{1}")]),
        "codex": .object(["answers": .array([.string("é")])]),
    ])

    @Test func canonicalAnswersMatchAcpmux() {
        var text = ""
        ApprovalPayload.canonicalJSON(Self.answers, into: &text)
        #expect(text == #"{"Which?":"B","a\"b":["x\ny","\u0001"],"codex":{"answers":["é"]}}"#)
        #expect(ApprovalPayload.answersDigest(Self.answers) == "44ba30ad88bf4d244b42c361e7ba2a97441780fce0cdfd2a175df95d6e2d6fc8")
        #expect(ApprovalPayload.answersDigest(nil) == "")
    }

    @Test func payloadMatchesAcpmux() {
        var payload = ApprovalPayload(
            instance: "0123abcd", macDevice: "9f1c2d3e-0000-4000-8000-000000000001",
            approver: "6a7b8c9d-0000-4000-8000-000000000002", session: "sess-1", permission: "perm-7",
            option: "allow_once", nonce: String(repeating: "ab", count: 32), expiresAt: 1_760_000_000)
        #expect(payload.message.starts(with: Data("acpmux-approver-decision-v1\u{0}".utf8)))
        #expect(Self.sha256(payload.message) == "3093d49d440c85bb9f357d0940a5bbd0e822c944fdfe650e9faae0b58afb6c2c")
        payload.answers = Self.answers
        #expect(Self.sha256(payload.message) == "764300d7c596ec827c3d7ffb2b8b5819816151589c5edce1feecd0937b125fe8")
    }

    @Test func linkChallengeMatchesHostd() {
        let payload = LinkAuthPayload(mac: "mac-1", phone: "phone-1", nonce: "n0", identityKey: "04aa", approvalKey: "04bb", action: "pair")
        #expect(Self.sha256(payload.message) == "237c38ed09257b49bfb2a2e105506741f1dbadbc3d63414ff65c40af9faf9084")
    }
}

@MainActor
@Suite struct ApprovalHubTests {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var params: [[String: Any]] = []
        func append(_ p: [String: Any]) { lock.withLock { params.append(p) } }
        var all: [[String: Any]] { lock.withLock { params } }
    }

    /// acpmux with one pending prompt (nonce `n1`, run `inst`) that records each answer.
    static func fakeAcpmux(_ sent: Sent) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"personInstance":"inst"}}}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[]}"#)]
            case "_acpmux/info":
                return [reply(#"{"sessionId":"s1","pending":[{"permissionId":"perm","decisionNonce":"n1","personInstance":"inst","request":{"toolCall":{"title":"rm -rf build"},"options":[{"optionId":"allow","kind":"allow_once"},{"optionId":"deny","kind":"reject_once"}]}}]}"#)]
            case "_acpmux/permission_respond":
                sent.append(object["params"] as? [String: Any] ?? [:])
                return [reply("{}")]
            default:
                return [reply("{}")]
            }
        }
    }

    @Test func allowIsSignedAfterFaceIDAndDenyIsNot() async throws {
        let sent = Sent()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.fakeAcpmux(sent).openChannel(service: "acpmux", args: [:]))
        let key = P256.Signing.PrivateKey()
        let reasons = Sent()
        hub.approver = AcpmuxHub.Approver(phoneID: "phone-1", macDevice: "mac-1",
                                          now: { Date(timeIntervalSince1970: 1_000) }) { message, reason in
            reasons.append(["reason": reason])
            return try key.signature(for: message).rawRepresentation
        }
        try await hub.respond(sessionID: "s1", permissionID: "perm", optionID: "allow")
        try await hub.respond(sessionID: "s1", permissionID: "perm", optionID: "deny")
        let allow = try #require(sent.all.first)
        let meta = try #require((allow["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])
        #expect(meta["decisionNonce"] as? String == "n1")
        let decision = try #require(meta["approverDecision"] as? [String: Any])
        #expect(decision["approver"] as? String == "phone-1")
        #expect((decision["expiresAt"] as? NSNumber)?.intValue == 1_120)
        let payload = ApprovalPayload(instance: "inst", macDevice: "mac-1", approver: "phone-1", session: "s1",
                                      permission: "perm", option: "allow", nonce: "n1", expiresAt: 1_120)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(hexString: decision["signature"] as? String ?? "")))
        #expect(key.publicKey.isValidSignature(signature, for: payload.message))
        #expect(reasons.all.first?["reason"] as? String == "Allow “rm -rf build”")
        // The deny went unsigned, and Face ID asked once.
        #expect(sent.all.count == 2 && sent.all[1]["_meta"] == nil)
        #expect(reasons.all.count == 1)
    }

    @Test func cancelledFaceIDSendsNothing() async throws {
        let sent = Sent()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.fakeAcpmux(sent).openChannel(service: "acpmux", args: [:]))
        hub.approver = AcpmuxHub.Approver(phoneID: "phone-1", macDevice: "mac-1") { _, _ in throw PhoneKeys.Failure.cancelled }
        await #expect(throws: AcpmuxHub.ApprovalCancelled.self) {
            try await hub.respond(sessionID: "s1", permissionID: "perm", optionID: "allow")
        }
        #expect(sent.all.isEmpty)
    }
}

private extension Data {
    init?(hexString: String) {
        var out = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}
