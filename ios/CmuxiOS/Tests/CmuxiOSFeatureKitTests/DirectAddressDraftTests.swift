@testable import CmuxiOSFeatureKit
import Foundation
import Testing

struct DirectAddressDraftTests {
    static let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()

    @Test func validDraftBecomesADirectHostDraft() throws {
        let draft = DirectAddressDraft(name: " Studio ", address: " [fd7a:115c:a1e0::1] ", port: "", hostKey: Self.key)
        #expect(draft.issues.isEmpty)
        let host = try #require(draft.hostDraft())
        #expect(host.name == "Studio")
        #expect(host.kind == .direct(
            endpoint: HostEndpoint(address: "fd7a:115c:a1e0::1", port: DirectAddressDraft.defaultPort),
            hostKey: try #require(DirectHostKey(rawValue: Self.key))
        ))
    }

    @Test func nameDefaultsToTheAddress() throws {
        let host = try #require(DirectAddressDraft(address: "mac.tail1.ts.net", port: "5000", hostKey: Self.key).hostDraft())
        #expect(host.name == "mac.tail1.ts.net")
        guard case let .direct(endpoint, _) = host.kind else { Issue.record("not direct"); return }
        #expect(endpoint.port == 5000)
    }

    @Test(arguments: [
        ("", DirectAddressIssue.addressMissing),
        ("https://mac.local", .addressInvalid),
        ("mac local", .addressInvalid),
        ("mac.local/path", .addressInvalid),
        ("user@mac.local", .addressInvalid),
        ("mac.local:4180", .addressHasPort),
        ("100.64.1.1:22", .addressHasPort),
        ("a..b", .addressInvalid),
    ])
    func addressIssues(_ address: String, _ issue: DirectAddressIssue) {
        #expect(DirectAddressDraft(address: address, hostKey: Self.key).issues == [issue])
    }

    @Test func portAndKeyIssues() {
        #expect(DirectAddressDraft(address: "10.0.0.2", port: "0", hostKey: Self.key).issues == [.portInvalid])
        #expect(DirectAddressDraft(address: "10.0.0.2", port: "70000", hostKey: Self.key).issues == [.portInvalid])
        #expect(DirectAddressDraft(address: "10.0.0.2").issues == [.hostKeyMissing])
        #expect(DirectAddressDraft(address: "10.0.0.2", hostKey: "AAAA").issues == [.hostKeyInvalid])
        #expect(DirectAddressDraft().hostDraft() == nil)
    }

    @Test func hostKeyNormalizesURLSafeBase64() throws {
        let urlSafe = Self.key.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(DirectHostKey(rawValue: urlSafe)?.rawValue == Self.key)
    }

    @Test func editsRoundTripThroughARecord() throws {
        let host = try #require(DirectAddressDraft(name: "Lab", address: "192.168.1.9", port: "4181", hostKey: Self.key).hostDraft())
        let record = HostRecord(id: HostID("h1"), name: host.name, kind: host.kind, reachability: .unknown)
        let draft = try #require(DirectAddressDraft(record: record))
        #expect(draft.hostDraft() == host)
        #expect(DirectAddressDraft(record: HostRecord(id: HostID("m"), name: "Mac", kind: .pairedMac, reachability: .unknown)) == nil)
    }

    @Test func savesThroughTheHostsStore() async throws {
        let store = MockHostsStore()
        let draft = try #require(DirectAddressDraft(address: "100.100.2.3", hostKey: Self.key).hostDraft())
        let receipt = try await store.add(draft, key: IntentKey())
        guard case .committed = receipt else { Issue.record("expected commit"); return }
        #expect(await store.hub.current.value.contains { $0.kind == draft.kind })
    }
}
