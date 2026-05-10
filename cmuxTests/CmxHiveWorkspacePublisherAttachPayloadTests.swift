import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmxHiveWorkspacePublisherAttachPayloadTests: XCTestCase {
    func testAttachPayloadExtractsHiveAttachObjectFromBridgeTicket() throws {
        let ticket = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": {
            "id": "endpoint-public-key",
            "addrs": ["quic-v1://127.0.0.1:1234"],
            "relay": true
          },
          "auth": {
            "mode": "rivet_stack",
            "pairing_id": "pairing_123",
            "rivet_endpoint": "http://localhost:9960/api/hive",
            "stack_project_id": "stack_abc",
            "expires_at_unix": 4000000000
          }
        }
        """

        let attach = try XCTUnwrap(CmxHiveAttachPayload.fromTicket(ticket))

        XCTAssertEqual(attach.pairingID, "pairing_123")
        XCTAssertEqual(attach.rivetEndpoint, "http://localhost:9960/api/hive")
        XCTAssertEqual(attach.stackProjectID, "stack_abc")
        XCTAssertEqual(attach.expiresAtUnix, 4000000000)

        let data = try JSONEncoder().encode(attach)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let endpoint = try XCTUnwrap(object["endpoint"] as? [String: Any])
        XCTAssertEqual(endpoint["id"] as? String, "endpoint-public-key")
        XCTAssertEqual(endpoint["relay"] as? Bool, true)
        XCTAssertEqual(object["pairing_id"] as? String, "pairing_123")
        XCTAssertEqual(object["stack_project_id"] as? String, "stack_abc")
        XCTAssertEqual((object["expires_at_unix"] as? NSNumber)?.uint64Value, 4000000000)
    }

    func testAttachPayloadIgnoresDirectTicketsWithoutHivePairing() {
        let ticket = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """

        XCTAssertNil(CmxHiveAttachPayload.fromTicket(ticket))
    }
}
