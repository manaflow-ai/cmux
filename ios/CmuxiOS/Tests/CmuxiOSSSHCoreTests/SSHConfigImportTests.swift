import CmuxiOSFeatureKit
@testable import CmuxiOSSSHCore
import Testing

@Suite struct SSHConfigImportTests {
    @Test func jumpHostsOfThePasteResolveAndComeFirst() {
        var counter = 0
        let entries = [
            SSHConfigEntry(alias: "inner", hostName: "10.0.0.5", user: "me", proxyJump: "bastion"),
            SSHConfigEntry(alias: "bastion", hostName: "jump.example.com", user: "me"),
        ]
        let plan = SSHConfigImport(entries: entries, existing: []) {
            counter += 1
            return IntentKey(rawValue: "k\(counter)")
        }
        #expect(plan.items.map(\.entry.alias) == ["bastion", "inner"])
        let bastionKey = plan.items[0].key
        guard case .ssh(_, let jump) = plan.items[1].draft.kind else { Issue.record("not ssh"); return }
        #expect(jump == .added(by: bastionKey))
    }

    @Test func jumpToExistingHostAndUnresolvedJump() {
        let existing = [HostRecord(id: HostID("h1"), name: "Gateway",
                                   kind: .ssh(endpoint: HostEndpoint(address: "gw.example.com", user: "me"), jumpHost: nil),
                                   reachability: .unknown)]
        let plan = SSHConfigImport(entries: [
            SSHConfigEntry(alias: "a", hostName: "a.lan", user: "me", proxyJump: "me@gw.example.com"),
            SSHConfigEntry(alias: "b", hostName: "b.lan", user: "me", proxyJump: "nowhere"),
            SSHConfigEntry(alias: "c", hostName: "GW.example.com", port: 22, user: "me"),
        ], existing: existing)
        guard case .ssh(_, let jumpA) = plan.items[0].draft.kind,
              case .ssh(_, let jumpB) = plan.items[1].draft.kind else { Issue.record("not ssh"); return }
        #expect(jumpA == HostID("h1"))
        #expect(jumpB == nil)
        #expect(plan.items[1].unresolvedJump == "nowhere")
        #expect(plan.items[2].duplicateOf == HostID("h1"))
    }

    @Test func jumpSpecParsing() {
        let target = SSHConfigImport.jumpTarget("user@host.example:2200")
        #expect(target.alias == "host.example")
        #expect(target.user == "user")
        #expect(target.port == 2200)
        #expect(SSHConfigImport.jumpTarget("bastion").alias == "bastion")
    }
}
