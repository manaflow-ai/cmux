import CmuxiOSFeatureKit
import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Testing

@Suite struct SSHHostChainTests {
    func record(_ id: String, user: String? = "me", port: UInt16? = nil, jump: String? = nil) -> HostRecord {
        HostRecord(id: HostID(id), name: id.uppercased(),
                   kind: .ssh(endpoint: HostEndpoint(address: id + ".lan", port: port, user: user), jumpHost: jump.map { HostID($0) }),
                   reachability: .unknown)
    }

    @Test func ordersJumpsOutermostFirst() throws {
        let chain = try SSHHostChain(target: HostID("c"), records: [record("a"), record("b", port: 2222, jump: "a"), record("c", jump: "b")])
        #expect(chain.hops.map(\.hostID) == [HostID("a"), HostID("b"), HostID("c")])
        #expect(chain.hops[1].endpoint == SSHEndpoint(host: "b.lan", port: 2222, username: "me"))
        #expect(chain.names["[b.lan]:2222"] == "B")
    }

    @Test func refusesLoopsUnknownHostsAndMissingUsers() {
        #expect(throws: SSHSessionFailure.invalidChain) {
            try SSHHostChain(target: HostID("a"), records: [record("a", jump: "b"), record("b", jump: "a")])
        }
        #expect(throws: SSHSessionFailure.invalidChain) { try SSHHostChain(target: HostID("z"), records: []) }
        #expect(throws: SSHSessionFailure.missingUser) { try SSHHostChain(target: HostID("a"), records: [record("a", user: nil)]) }
    }
}
