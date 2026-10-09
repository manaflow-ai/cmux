import CmuxiOSFeatureKit
import CmuxiOSPlatform
import CmuxMobileWire
import Foundation
import Testing

@Suite("What's New, Mac gate, demo mode")
struct ReleaseSurfacesTests {
    private func version(_ text: String) -> AppVersion { AppVersion(text)! }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "c16.wn." + UUID().uuidString)! }

    private var entries: [WhatsNewEntry] {
        [
            WhatsNewEntry(version: version("1.0.5"), items: []),
            WhatsNewEntry(version: version("1.0.6"), items: []),
            WhatsNewEntry(version: version("1.0.7"), items: [], channels: [.dev, .beta, .appStore]),
        ]
    }

    @Test func versionsCompareNumerically() {
        #expect(version("1.0.10") > version("1.0.9"))
        #expect(version("1.2") == version("1.2.0"))
        #expect(AppVersion("1.x") == nil)
    }

    @Test func firstInstallShowsNothingThenAnUpdateShowsOnce() {
        let policy = WhatsNewPolicy(channel: .beta, defaults: defaults())
        #expect(policy.entryToPresent(entries, current: version("1.0.5")) == nil)
        #expect(policy.entryToPresent(entries, current: version("1.0.6"))?.version == version("1.0.6"))
        #expect(policy.entryToPresent(entries, current: version("1.0.6")) == nil)
    }

    @Test func appStoreSeesOnlyOptedInEntries() {
        let store = defaults()
        store.set("1.0.4", forKey: WhatsNewPolicy.lastSeenKey)
        let policy = WhatsNewPolicy(channel: .appStore, defaults: store)
        #expect(policy.entryToPresent(entries, current: version("1.0.6")) == nil)
        #expect(policy.visibleEntries(entries).map(\.version) == [version("1.0.7")])
        #expect(WhatsNewPolicy(channel: .dev, defaults: store).visibleEntries(entries).count == 3)
    }

    @Test func channelFollowsBundleID() {
        #expect(BuildChannel(bundleID: "dev.cmux.ios", isDebug: false) == .appStore)
        #expect(BuildChannel(bundleID: "dev.cmux.app.beta", isDebug: false) == .beta)
        #expect(BuildChannel(bundleID: "dev.cmux.ios.nxc16", isDebug: false) == .dev)
        #expect(BuildChannel(bundleID: "dev.cmux.ios", isDebug: true) == .dev)
    }

    private func mac(protocol version: Int, capabilities: Set<String> = []) -> MacCapabilities {
        MacCapabilities(host: HostID("mac"), name: "Mac", appVersion: "1", protocolVersion: version, capabilities: capabilities)
    }

    @Test("live host status wins over discovery metadata while hello is the protocol fallback")
    func liveMacCapabilitiesProjection() {
        let hello = HelloOKFrame(version: 1, caps: ["workspace.close"], serverTime: 0, maxFrame: 1024)
        let status: JSONValue = .object([
            "mac_display_name": .string("Studio"),
            "mac_app_version": .string("1.2.3"),
            "capabilities": .array([.string("workspace.close"), .string("task.stream")]),
        ])
        let projected = MacCapabilities.decode(host: HostID("host_1"), fallbackName: "Old Name",
                                                         hello: hello, status: status)
        #expect(projected.name == "Studio")
        #expect(projected.appVersion == "1.2.3")
        #expect(projected.protocolVersion == 1)
        #expect(projected.capabilities == ["workspace.close", "task.stream"])

        let fallback = MacCapabilities.decode(host: HostID("host_1"), fallbackName: "Old Name",
                                                        hello: hello, status: nil)
        #expect(fallback.name == "Old Name")
        #expect(fallback.appVersion == "0")
        #expect(fallback.capabilities == ["workspace.close"])
    }

    @Test func macVerdicts() {
        let policy = MacCompatibilityPolicy(supported: 2...3, required: ["terminal.v1"])
        #expect(policy.verdict(for: mac(protocol: 1, capabilities: ["terminal.v1"])) == .macUpdateRequired(minimumProtocol: 2))
        #expect(policy.verdict(for: mac(protocol: 4, capabilities: ["terminal.v1"])) == .phoneUpdateRequired(macProtocol: 4))
        #expect(policy.verdict(for: mac(protocol: 3)) == .missingCapabilities(["terminal.v1"]))
        #expect(policy.verdict(for: mac(protocol: 2, capabilities: ["terminal.v1", "extra"])) == .compatible)
        let raised = MacCompatibilityPolicy(supported: 2...3, required: [], remoteMinimum: 3)
        #expect(raised.verdict(for: mac(protocol: 2)) == .macUpdateRequired(minimumProtocol: 3))
    }

    @Test func mockMacsIncludeOneThatNeedsAnUpdate() async {
        var iterator = await MockMacCapabilitiesSource().updates().makeAsyncIterator()
        let macs = await iterator.next()?.value.values.map { $0 } ?? []
        let verdicts = macs.map(MacCompatibilityPolicy().verdict(for:))
        #expect(verdicts.filter(\.isCompatible).count == 1)
        #expect(verdicts.count == 2)
    }

    @Test func demoModeFollowsRemoteConfigAndDebugEnvironment() {
        let release = DemoModePolicy(environment: ["CMUX_IOS_DEMO": "1"], isDebug: false)
        #expect(!release.isActive(remote: .empty))
        #expect(release.isActive(remote: RemoteConfig(demoContent: true)))
        #expect(DemoModePolicy(environment: ["CMUX_IOS_DEMO": "1"], isDebug: true).isActive(remote: .empty))
    }
}
