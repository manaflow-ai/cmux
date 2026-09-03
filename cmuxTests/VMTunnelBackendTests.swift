import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Which tunnel backend a build resolves to, and why it does not resolve to the
/// app-managed one. The bug these cover: a nightly signed with the regenerated
/// Developer ID profile carries `packet-tunnel-provider-systemextension`, the
/// gate only accepted `packet-tunnel-provider`, and `cmux vpn status` therefore
/// misreported the backend in both directions once the profile changed.
@Suite
struct VMTunnelBackendTests {
    // MARK: - Entitlement flavors

    @Test
    func developerIDSystemExtensionFlavorGrantsPacketTunnel() {
        #expect(VMTunnelBackendSelection.packetTunnelEntitlementGranted(
            ["packet-tunnel-provider-systemextension"]
        ))
    }

    @Test
    func macAppStoreAndDevelopmentFlavorGrantsPacketTunnel() {
        #expect(VMTunnelBackendSelection.packetTunnelEntitlementGranted(["packet-tunnel-provider"]))
    }

    @Test
    func aRealDeveloperIDCapabilityListGrantsPacketTunnel() {
        // Verbatim shape of the list our Developer ID profiles carry.
        #expect(VMTunnelBackendSelection.packetTunnelEntitlementGranted([
            "packet-tunnel-provider-systemextension",
            "app-proxy-provider-systemextension",
            "content-filter-provider-systemextension",
            "dns-proxy-systemextension",
            "dns-settings",
            "relay",
        ]))
    }

    @Test
    func otherNetworkExtensionCapabilitiesDoNotGrantPacketTunnel() {
        #expect(!VMTunnelBackendSelection.packetTunnelEntitlementGranted([
            "content-filter-provider-systemextension",
            "dns-proxy-systemextension",
        ]))
    }

    @Test
    func absentOrMalformedEntitlementDoesNotGrantPacketTunnel() {
        #expect(!VMTunnelBackendSelection.packetTunnelEntitlementGranted(nil))
        #expect(!VMTunnelBackendSelection.packetTunnelEntitlementGranted([String]()))
        #expect(!VMTunnelBackendSelection.packetTunnelEntitlementGranted("packet-tunnel-provider"))
        #expect(!VMTunnelBackendSelection.packetTunnelEntitlementGranted(["packet-tunnel-provider": true]))
    }

    // MARK: - Backend selection

    @Test
    func entitledBuildWithAnEmbeddedProviderIsAppManaged() {
        let selection = VMTunnelBackendSelection.resolve(
            entitlementValue: ["packet-tunnel-provider-systemextension"],
            bundledProviderIdentifier: "com.cmuxterm.app.tunnel"
        )
        #expect(selection.backend == .networkExtension)
        #expect(selection.providerBundleIdentifier == "com.cmuxterm.app.tunnel")
        #expect(selection.unavailableReason == nil)
    }

    @Test
    func entitledBuildWithNoEmbeddedProviderStaysOnWgQuick() {
        // Every build today: the Developer ID profile grants the capability but
        // no build embeds the extension yet. Reporting "app-managed" here is
        // exactly the misreport this gate exists to prevent.
        let selection = VMTunnelBackendSelection.resolve(
            entitlementValue: ["packet-tunnel-provider-systemextension"],
            bundledProviderIdentifier: nil
        )
        #expect(selection.backend == .wgQuick)
        #expect(selection.providerBundleIdentifier == nil)
        #expect(selection.unavailableReason == .providerNotBundled)
    }

    @Test
    func unentitledBuildStaysOnWgQuickEvenWithAProviderPresent() {
        let selection = VMTunnelBackendSelection.resolve(
            entitlementValue: nil,
            bundledProviderIdentifier: "com.cmuxterm.app.debug.netun.tunnel"
        )
        #expect(selection.backend == .wgQuick)
        #expect(selection.unavailableReason == .entitlementMissing)
    }

    @Test
    func anEmptyProviderIdentifierIsNotAProvider() {
        let selection = VMTunnelBackendSelection.resolve(
            entitlementValue: ["packet-tunnel-provider"],
            bundledProviderIdentifier: ""
        )
        #expect(selection.backend == .wgQuick)
        #expect(selection.unavailableReason == .providerNotBundled)
    }

    @Test
    func eachUnavailableReasonGetsItsOwnUserFacingLine() {
        let unentitled = VMTunnelBackendSelection.resolve(
            entitlementValue: nil, bundledProviderIdentifier: nil
        ).statusDescription
        let noProvider = VMTunnelBackendSelection.resolve(
            entitlementValue: ["packet-tunnel-provider"], bundledProviderIdentifier: nil
        ).statusDescription
        let appManaged = VMTunnelBackendSelection.resolve(
            entitlementValue: ["packet-tunnel-provider"], bundledProviderIdentifier: "x.tunnel"
        ).statusDescription
        #expect(unentitled != noProvider)
        #expect(appManaged != unentitled)
        #expect(!unentitled.isEmpty)
        #expect(!noProvider.isEmpty)
        #expect(!appManaged.isEmpty)
    }

    // MARK: - Embedded provider discovery

    @Test
    func discoversAPacketTunnelSystemExtensionInAnAppBundle() throws {
        let bundle = try TemporaryAppBundle()
        try bundle.addSystemExtension(
            name: "CmuxTunnel",
            identifier: "com.cmuxterm.app.tunnel",
            providerClasses: [
                VMTunnelBackendSelection.packetTunnelProviderClassKey: "CmuxTunnel.PacketTunnelProvider",
            ]
        )
        #expect(VMTunnelBackendSelection.bundledProviderIdentifier(in: bundle.url) == "com.cmuxterm.app.tunnel")
    }

    @Test
    func ignoresASystemExtensionThatIsNotAPacketTunnel() throws {
        // A content filter or DNS proxy lives in the same directory. Treating
        // any system extension as the tunnel provider would make the app try to
        // start the wrong one.
        let bundle = try TemporaryAppBundle()
        try bundle.addSystemExtension(
            name: "CmuxFilter",
            identifier: "com.cmuxterm.app.filter",
            providerClasses: ["com.apple.networkextension.filter-data": "CmuxFilter.Provider"]
        )
        #expect(VMTunnelBackendSelection.bundledProviderIdentifier(in: bundle.url) == nil)
    }

    @Test
    func picksThePacketTunnelWhenSeveralSystemExtensionsAreEmbedded() throws {
        let bundle = try TemporaryAppBundle()
        try bundle.addSystemExtension(
            name: "AFilter",
            identifier: "com.cmuxterm.app.filter",
            providerClasses: ["com.apple.networkextension.filter-data": "CmuxFilter.Provider"]
        )
        try bundle.addSystemExtension(
            name: "ZTunnel",
            identifier: "com.cmuxterm.app.tunnel",
            providerClasses: [
                VMTunnelBackendSelection.packetTunnelProviderClassKey: "CmuxTunnel.PacketTunnelProvider",
            ]
        )
        #expect(VMTunnelBackendSelection.bundledProviderIdentifier(in: bundle.url) == "com.cmuxterm.app.tunnel")
    }

    @Test
    func aBundleWithNoSystemExtensionsDirectoryHasNoProvider() throws {
        let bundle = try TemporaryAppBundle()
        #expect(VMTunnelBackendSelection.bundledProviderIdentifier(in: bundle.url) == nil)
    }

    @Test
    func aSystemExtensionWithNoProviderClassesIsNotAProvider() throws {
        let bundle = try TemporaryAppBundle()
        try bundle.addSystemExtension(
            name: "CmuxTunnel",
            identifier: "com.cmuxterm.app.tunnel",
            providerClasses: nil
        )
        #expect(VMTunnelBackendSelection.bundledProviderIdentifier(in: bundle.url) == nil)
    }

    @Test
    func anUnreadableInfoPlistIsNotAProvider() throws {
        let bundle = try TemporaryAppBundle()
        let dir = bundle.url
            .appendingPathComponent("Contents/Library/SystemExtensions/Broken.systemextension/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: dir.appendingPathComponent("Info.plist"))
        #expect(VMTunnelBackendSelection.bundledProviderIdentifier(in: bundle.url) == nil)
    }

    // MARK: - System extension load location

    @Test
    func onlyAnAppInApplicationsCanLoadASystemExtension() {
        // macOS refuses to load a system extension from anywhere else, so the
        // app has to say so instead of failing activation silently.
        #expect(VMTunnelExtensionController.appLocationSupportsSystemExtension(
            URL(fileURLWithPath: "/Applications/cmux.app")
        ))
        #expect(!VMTunnelExtensionController.appLocationSupportsSystemExtension(
            URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/cmux.app")
        ))
        #expect(!VMTunnelExtensionController.appLocationSupportsSystemExtension(
            URL(fileURLWithPath: "/Applications")
        ))
    }

    @Test
    func theControllerCannotBeBuiltForTheWgQuickBackend() {
        let wgQuick = VMTunnelBackendSelection.resolve(entitlementValue: nil, bundledProviderIdentifier: nil)
        #expect(VMTunnelExtensionController(selection: wgQuick) == nil)
        let appManaged = VMTunnelBackendSelection.resolve(
            entitlementValue: ["packet-tunnel-provider-systemextension"],
            bundledProviderIdentifier: "com.cmuxterm.app.tunnel"
        )
        let controller = VMTunnelExtensionController(
            selection: appManaged,
            appBundleURL: URL(fileURLWithPath: "/Applications/cmux.app")
        )
        #expect(controller?.providerBundleIdentifier == "com.cmuxterm.app.tunnel")
    }
}

/// A throwaway `.app` on disk, so provider discovery is tested against real
/// bundle layout instead of a mocked filesystem.
private final class TemporaryAppBundle {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMTunnelBackendTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("cmux.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func addSystemExtension(name: String, identifier: String, providerClasses: [String: String]?) throws {
        let contents = url
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("\(name).systemextension", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleVersion": "1",
            "NSExtensionPointIdentifier": "com.apple.system-extension.network-extension",
        ]
        if let providerClasses {
            plist["NetworkExtension"] = ["NEProviderClasses": providerClasses]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
