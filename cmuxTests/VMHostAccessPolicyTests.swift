import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What a Cloud VM may do to this Mac over the private-network listener: only
/// callers from inside the network, only with a token this Mac minted, only
/// the notification and telemetry verbs.
@Suite
struct VMHostAccessPolicyTests {
    @Test
    func sourceInsideNetworkCIDRsIsAllowed() {
        let cidrs = ["10.16.204.0/24", "fd53:9585:5690::/64"]
        #expect(VMHostAccessPolicy.sourceIsAllowed(peer: "10.16.204.3", networkCIDRs: cidrs))
        #expect(VMHostAccessPolicy.sourceIsAllowed(peer: "fd53:9585:5690::3", networkCIDRs: cidrs))
        // IPv4-mapped IPv6 peer on a dual-stack accept path.
        #expect(VMHostAccessPolicy.sourceIsAllowed(peer: "::ffff:10.16.204.7", networkCIDRs: cidrs))
    }

    @Test
    func sourceOutsideNetworkIsDenied() {
        let cidrs = ["10.16.204.0/24", "fd53:9585:5690::/64"]
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "10.16.205.3", networkCIDRs: cidrs))
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "127.0.0.1", networkCIDRs: cidrs))
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "100.64.0.1", networkCIDRs: cidrs))
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "fd53:9585:5691::3", networkCIDRs: cidrs))
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "::1", networkCIDRs: cidrs))
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "not-an-address", networkCIDRs: cidrs))
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "10.16.204.3", networkCIDRs: []))
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "10.16.204.3", networkCIDRs: ["garbage/99"]))
    }

    @Test
    func cidrParsingHandlesPrefixesAndBareAddresses() throws {
        let (network, prefix) = try #require(VMHostAccessPolicy.parseCIDR("10.40.0.0/24"))
        #expect(network == [10, 40, 0, 0])
        #expect(prefix == 24)
        let (bare, barePrefix) = try #require(VMHostAccessPolicy.parseCIDR("10.40.0.9"))
        #expect(bare == [10, 40, 0, 9])
        #expect(barePrefix == 32)
        #expect(VMHostAccessPolicy.parseCIDR("10.40.0.0/33") == nil)
        #expect(VMHostAccessPolicy.parseCIDR("fd00::/129") == nil)
        #expect(VMHostAccessPolicy.parseCIDR("") == nil)
    }

    @Test
    func nonOctetAlignedPrefixMatchesOnlyInsideTheBlock() {
        #expect(VMHostAccessPolicy.sourceIsAllowed(peer: "10.16.193.7", networkCIDRs: ["10.16.192.0/22"]))
        #expect(!VMHostAccessPolicy.sourceIsAllowed(peer: "10.16.196.1", networkCIDRs: ["10.16.192.0/22"]))
    }

    @Test
    func tokensCompareExactly() {
        #expect(VMHostAccessPolicy.tokensMatch("abc123", "abc123"))
        #expect(!VMHostAccessPolicy.tokensMatch("abc123", "abc124"))
        #expect(!VMHostAccessPolicy.tokensMatch("abc12", "abc123"))
        #expect(!VMHostAccessPolicy.tokensMatch("", "abc123"))
    }

    @Test
    func allowListHoldsOnlyTelemetryAndAttentionVerbs() {
        let allowed = VMHostAccessPolicy.allowedMethods
        #expect(allowed.contains("notification.create"))
        #expect(allowed.contains("feed.push"))
        #expect(allowed.contains("surface.report_pwd"))
        for denied in [
            "surface.send_text", "surface.send_key", "surface.read_text", "surface.list",
            "workspace.create", "workspace.select", "workspace.list", "notification.list",
            "notification.open", "notification.jump_to_unread", "notification.dismiss",
            "vm.destroy", "vm.exec", "browser.navigate", "window.focus", "system.tree", "feed.list",
        ] {
            #expect(!allowed.contains(denied), "\(denied) must not be callable from a machine")
        }
        #expect(VMHostAccessPolicy.workspaceRequiredMethods.isSubset(of: allowed))
        #expect(VMHostAccessPolicy.surfaceRequiredMethods.isSubset(of: VMHostAccessPolicy.workspaceRequiredMethods))
    }

    @Test
    func tokenStoreMintsOncePersistsAndMapsBack() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vmhost-tokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = VMHostTokenStore(home: home)
        let token = store.token(for: "vm-a")
        #expect(token.count >= 40)
        #expect(store.token(for: "vm-a") == token)
        #expect(store.vmID(forToken: token) == "vm-a")
        #expect(store.vmID(forToken: token + "x") == nil)
        #expect(store.token(for: "vm-b") != token)

        // A fresh store over the same home reads the persisted tokens.
        let reloaded = VMHostTokenStore(home: home)
        #expect(reloaded.vmID(forToken: token) == "vm-a")
        #expect(reloaded.count == 2)

        let file = home.appendingPathComponent(".cmuxterm/vm-host/tokens.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        reloaded.retain(vmIDs: ["vm-b"])
        #expect(reloaded.vmID(forToken: token) == nil)
        reloaded.removeAll()
        #expect(reloaded.count == 0)
    }
}
