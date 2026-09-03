import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Backend selection is the gate that keeps unentitled builds on the wg-quick
/// path: every missing piece must name itself, and only a build with the
/// signed capability, the install entitlement, and a bundled extension may
/// claim the app-managed tunnel.
@Suite
struct CloudTunnelBackendSelectorTests {
    private func selector(
        capabilities: [String],
        canInstall: Bool,
        bundled: String?
    ) -> CloudTunnelBackendSelector {
        CloudTunnelBackendSelector(
            networkExtensionCapabilities: { capabilities },
            canInstallSystemExtensions: { canInstall },
            bundledExtensionIdentifier: { bundled }
        )
    }

    @Test("no NetworkExtension capability falls back to wg-quick")
    func entitlementMissing() {
        let backend = selector(capabilities: [], canInstall: true, bundled: "x.tunnel").select()
        #expect(backend == .wgQuick(.entitlementMissing))
        #expect(!backend.isNetworkExtension)
        #expect(backend.wireName == "wg-quick")
    }

    @Test("the app-extension flavor of the capability does not count on macOS")
    func appExtensionCapabilityIsNotEnough() {
        let backend = selector(capabilities: ["packet-tunnel-provider"], canInstall: true, bundled: "x.tunnel").select()
        #expect(backend == .wgQuick(.entitlementMissing))
    }

    @Test("the capability without system-extension install falls back")
    func installEntitlementMissing() {
        let backend = selector(
            capabilities: ["packet-tunnel-provider-systemextension"],
            canInstall: false,
            bundled: "x.tunnel"
        ).select()
        #expect(backend == .wgQuick(.systemExtensionInstallEntitlementMissing))
    }

    @Test("an entitled build whose signing dropped the extension falls back")
    func extensionNotBundled() {
        let backend = selector(
            capabilities: ["packet-tunnel-provider-systemextension"],
            canInstall: true,
            bundled: nil
        ).select()
        #expect(backend == .wgQuick(.extensionNotBundled))
        #expect(backend.fallbackReason == .extensionNotBundled)
    }

    @Test("all three pieces select the app-managed tunnel")
    func networkExtensionSelected() {
        let backend = selector(
            capabilities: ["packet-tunnel-provider-systemextension"],
            canInstall: true,
            bundled: "com.cmuxterm.app.tunnel"
        ).select()
        #expect(backend == .networkExtension(extensionBundleIdentifier: "com.cmuxterm.app.tunnel"))
        #expect(backend.isNetworkExtension)
        #expect(backend.extensionBundleIdentifier == "com.cmuxterm.app.tunnel")
        #expect(backend.wireName == "network-extension")
    }

    @Test("the bundled extension identifier is read from the shipped Info.plist")
    func bundledIdentifierFromBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tunnel-selector-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("cmux.app", isDirectory: true)
        #expect(CloudTunnelBackendSelector.bundledSystemExtensionIdentifier(in: app) == nil)

        let contents = app.appendingPathComponent(
            "Contents/Library/SystemExtensions/cmuxTunnel.systemextension/Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.cmuxterm.app.debug.tunnel", "CFBundlePackageType": "SYSX"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        #expect(CloudTunnelBackendSelector.bundledSystemExtensionIdentifier(in: app) == "com.cmuxterm.app.debug.tunnel")
    }

    @Test("a stripped bundle (folder present, no extension) reports nothing")
    func emptySystemExtensionsFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tunnel-selector-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("cmux.app/Contents/Library/SystemExtensions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(CloudTunnelBackendSelector.bundledSystemExtensionIdentifier(in: root.appendingPathComponent("cmux.app")) == nil)
    }
}
