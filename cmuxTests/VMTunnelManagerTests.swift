import CryptoKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The local half of Cloud VM private networking: keys and device identity are
/// minted once and stay stable, and the server-issued config (blank
/// `PrivateKey`) is completed on this Mac without ever sending the key out.
@Suite
struct VMTunnelManagerTests {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tunnel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func keypairIsMintedOnceAndStable() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-test")

        let first = try manager.keypair()
        let second = try manager.keypair()
        #expect(first.privateKey == second.privateKey)
        #expect(first.publicKey == second.publicKey)

        // The public half must be the X25519 derivation of the private half —
        // a mismatch would enroll a key the Mac cannot handshake with.
        let raw = try #require(Data(base64Encoded: first.privateKey))
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        #expect(key.publicKey.rawRepresentation.base64EncodedString() == first.publicKey)

        // 0600: the private key is a credential.
        let attrs = try FileManager.default.attributesOfItem(atPath: manager.privateKeyURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test
    func deviceFingerprintIsStablePerInstallation() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-test")
        let first = try manager.deviceFingerprint()
        #expect(first.hasPrefix("mac-"))
        #expect(try manager.deviceFingerprint() == first)
    }

    @Test
    func readingStoredFingerprintDoesNotMintAfterRevoke() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-test")

        #expect(manager.storedDeviceFingerprint() == nil)
        #expect(!FileManager.default.fileExists(atPath: manager.deviceIDURL.path))

        let minted = try manager.deviceFingerprint()
        #expect(manager.storedDeviceFingerprint() == minted)

        manager.removeLocalCredentials()
        #expect(manager.storedDeviceFingerprint() == nil)
        #expect(!FileManager.default.fileExists(atPath: manager.deviceIDURL.path))
    }

    @Test
    func cloudAccessRevokeSendsTheDeviceIDInTheBody() throws {
        let request = VMClient.cloudAccessRevocationRequest(deviceID: "mac physical/device")

        #expect(request.path == "/api/vm/tunnel")
        #expect(request.body["deviceId"] as? String == "mac physical/device")
    }

    @Test
    func completedConfigFillsTheBlankPrivateKeyLine() throws {
        let config = """
        [Interface]
        PrivateKey =
        Address = 100.64.0.1/32
        MTU = 1200

        [Peer]
        PublicKey = server-key
        AllowedIPs = 10.0.0.0/8, fd00::/8
        Endpoint = vpn.example.com:51820
        """
        let completed = try VMTunnelManager.completedConfig(config, privateKey: "PRIVATE")
        #expect(completed.contains("PrivateKey = PRIVATE"))
        // Everything else must be byte-identical: the server config is final.
        #expect(completed.contains("Address = 100.64.0.1/32"))
        #expect(completed.contains("Endpoint = vpn.example.com:51820"))
    }

    @Test
    func completedConfigInsertsWhenNoPrivateKeyLineExists() throws {
        let config = """
        [Interface]
        Address = 100.64.0.1/32

        [Peer]
        PublicKey = server-key
        """
        let completed = try VMTunnelManager.completedConfig(config, privateKey: "PRIVATE")
        let lines = completed.components(separatedBy: "\n")
        let interfaceIndex = try #require(lines.firstIndex(of: "[Interface]"))
        #expect(lines[interfaceIndex + 1] == "PrivateKey = PRIVATE")
    }

    @Test
    func completedConfigRejectsAConfigWithoutAnInterfaceSection() {
        #expect(throws: VMTunnelManager.TunnelError.self) {
            _ = try VMTunnelManager.completedConfig("[Peer]\nPublicKey = x", privateKey: "PRIVATE")
        }
    }

    @Test
    func browserEnrollerReusesSavedConfigWithoutACloudClient() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-cache-test")
        try FileManager.default.createDirectory(at: manager.stateDir, withIntermediateDirectories: true)
        let config = "[Interface]\nPrivateKey = local\n\n[Peer]\nAllowedIPs = 10.40.0.0/24\n"
        try config.write(to: manager.configURL, atomically: true, encoding: .utf8)

        let enrollment = try await VMTunnelEnroller(manager: manager).enroll()

        #expect(enrollment.wgQuickConfig == config)
        #expect(enrollment.serverAddress == "cmux Cloud")
    }

    @Test
    func interfaceAddressesParseOnlyTheInterfaceSection() {
        let config = """
        [Interface]
        PrivateKey = X
        Address = 100.64.0.9/32
        Address = FD7A:7570:6C6B::9/128, 10.9.9.9/24
        MTU = 1380

        [Peer]
        PublicKey = Y
        AllowedIPs = 10.0.0.0/8, fd00::/8
        """
        // Prefix lengths stripped, IPv6 lowercased, AllowedIPs never included —
        // matching an AllowedIPs range against interface addresses would call
        // any 10.x interface "the tunnel".
        #expect(VMTunnelManager.interfaceAddresses(in: config) == [
            "100.64.0.9", "fd7a:7570:6c6b::9", "10.9.9.9",
        ])
    }

    @Test
    func interfaceNameAndStateHaveALegacyDeploymentFallback() {
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux.com")!) == "cmux")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://cmux-staging.vercel.app")!) == "cmux-staging")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "http://localhost:9170")!) == "cmux-local")
        #expect(VMTunnelManager.interfaceName(forAPIBaseURL: URL(string: "https://dev.example.invalid")!) == "cmux-dev")

        let home = URL(fileURLWithPath: "/tmp/cmux-tunnel-scope-tests", isDirectory: true)
        let manager = VMTunnelManager(home: home, interfaceName: "cmux-staging")
        #expect(manager.configURL.lastPathComponent == "cmux-staging.conf")
    }

    @Test
    func buildScopesDoNotShareCredentialsOrConfigFiles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let productionURL = URL(string: "https://cmux.com")!
        let nightly = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            apiBaseURL: productionURL
        )
        let dev = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app.debug.all.agents",
            apiBaseURL: productionURL
        )

        #expect(nightly.interfaceName != dev.interfaceName)
        #expect(nightly.configURL != dev.configURL)
        #expect(nightly.privateKeyURL != dev.privateKeyURL)
        #expect(nightly.deviceIDURL != dev.deviceIDURL)

        let nightlyKeys = try nightly.keypair()
        let devKeys = try dev.keypair()
        #expect(nightlyKeys.privateKey != devKeys.privateKey)
        #expect(nightlyKeys.publicKey != devKeys.publicKey)
        let nightlyFingerprint = try nightly.deviceFingerprint()
        let devFingerprint = try dev.deviceFingerprint()
        #expect(nightlyFingerprint != devFingerprint)

        let devRestart = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app.debug.all.agents",
            apiBaseURL: URL(string: "http://localhost:9170")!
        )
        #expect(devRestart.interfaceName == dev.interfaceName)
        #expect(try devRestart.keypair().privateKey == devKeys.privateKey)
        #expect(try devRestart.deviceFingerprint() == devFingerprint)
    }

    @Test
    func stableProductionKeepsLegacyCredentialPathsWhileOtherBuildsAreScoped() {
        let home = URL(fileURLWithPath: "/tmp/cmux-tunnel-path-tests", isDirectory: true)
        let productionURL = URL(string: "https://cmux.com")!
        let stable = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app",
            apiBaseURL: productionURL
        )
        let nightly = VMTunnelManager(
            home: home,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            apiBaseURL: productionURL
        )

        #expect(stable.interfaceName == "cmux")
        #expect(stable.privateKeyURL.lastPathComponent == "private.key")
        #expect(stable.deviceIDURL.lastPathComponent == "device-id")
        #expect(stable.configURL.lastPathComponent == "cmux.conf")
        #expect(nightly.interfaceName == "cmux-nightly")
        #expect(nightly.privateKeyURL.lastPathComponent == "cmux-nightly.private.key")
        #expect(nightly.deviceIDURL.lastPathComponent == "cmux-nightly.device-id")
        #expect(nightly.configURL.lastPathComponent == "cmux-nightly.conf")
    }

    @Test
    func taggedBuildIdentityWinsOverItsBackendOrigin() {
        let productionURL = URL(string: "https://cmux.com")!
        let localURL = URL(string: "http://localhost:9170")!
        let taggedDev = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.all.agents",
            apiBaseURL: productionURL
        )
        let sameTaggedDevOnLocalAPI = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.all.agents",
            apiBaseURL: localURL
        )
        let anotherTaggedDev = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug.cloud-notify",
            apiBaseURL: localURL
        )
        let nightly = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.nightly",
            apiBaseURL: productionURL
        )

        #expect(taggedDev == sameTaggedDevOnLocalAPI)
        #expect(taggedDev != anotherTaggedDev)
        #expect(taggedDev != nightly)
        for name in [taggedDev, anotherTaggedDev, nightly] {
            #expect(name.utf8.count <= 15)
            #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        }
    }

    @Test
    func baseDebugBundleUsesItsLaunchTag() {
        let productionURL = URL(string: "https://cmux.com")!
        let first = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug",
            environment: ["CMUX_TAG": "all-agents"],
            apiBaseURL: productionURL
        )
        let second = VMTunnelManager.interfaceName(
            bundleIdentifier: "com.cmuxterm.app.debug",
            environment: ["CMUX_TAG": "cloud-notify"],
            apiBaseURL: productionURL
        )

        #expect(first != second)
        #expect(first != "cmux-dev")
        #expect(second != "cmux-dev")
    }

    @Test
    func removingCredentialsDeletesBothRoleSecrets() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let terminal = VMTunnelManager(home: home, interfaceName: "cmux-test", purpose: .terminal)
        let browser = VMTunnelManager(home: home, interfaceName: "cmux-test", purpose: .browser)
        try FileManager.default.createDirectory(at: terminal.stateDir, withIntermediateDirectories: true)
        for manager in [terminal, browser] {
            try "private".write(to: manager.privateKeyURL, atomically: true, encoding: .utf8)
            try "device".write(to: manager.deviceIDURL, atomically: true, encoding: .utf8)
            try "config".write(to: manager.configURL, atomically: true, encoding: .utf8)
            manager.removeLocalCredentials()
            #expect(!FileManager.default.fileExists(atPath: manager.privateKeyURL.path))
            #expect(!FileManager.default.fileExists(atPath: manager.deviceIDURL.path))
            #expect(!FileManager.default.fileExists(atPath: manager.configURL.path))
        }
    }

    @Test
    func completedConfigNarrowsRoutesWhenTheNetworkIsKnown() throws {
        let server = """
        [Interface]
        PrivateKey =
        Address = 100.64.0.1/32

        [Peer]
        PublicKey = server-key
        AllowedIPs = 10.0.0.0/8, fd00::/8
        Endpoint = vpn.example.com:51820
        """
        let completed = try VMTunnelManager.completedConfig(
            server,
            privateKey: "PRIVATE",
            allowedIPs: ["10.16.170.0/24", "fd98:deb9:4c94::/64"]
        )
        #expect(completed.contains("PrivateKey = PRIVATE"))
        #expect(completed.contains("AllowedIPs = 10.16.170.0/24, fd98:deb9:4c94::/64"))
        #expect(!completed.contains("10.0.0.0/8"))
    }

    @Test
    func terminalAndBrowserRolesUseSeparateKeysAndConfigs() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let browser = VMTunnelManager(home: home, purpose: .browser)
        let terminal = VMTunnelManager(home: home, purpose: .terminal)

        #expect(try terminal.deviceFingerprint() != browser.deviceFingerprint())

        // Separate key material: one WireGuard key supports one live session.
        let browserKeys = try browser.keypair()
        let terminalKeys = try terminal.keypair()
        #expect(browserKeys.privateKey != terminalKeys.privateKey)
        #expect(terminal.privateKeyURL.lastPathComponent == "cmux.terminal.private.key")
        #expect(browser.privateKeyURL.lastPathComponent == "private.key")
        let attrs = try FileManager.default.attributesOfItem(atPath: terminal.privateKeyURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        #expect(terminal.configURL.lastPathComponent == "cmux.terminal.conf")
        #expect(browser.configURL.lastPathComponent == "cmux.conf")
        #expect(terminal.configURL != browser.configURL)
    }

    @Test
    func allowedIPsParseOnlyPeerSections() {
        let config = """
        [Interface]
        PrivateKey = X
        Address = 100.64.0.9/32
        AllowedIPs = 1.2.3.4/32

        [Peer]
        PublicKey = Y
        AllowedIPs = 10.0.0.0/8, fd00::/8
        Endpoint = [2606:4700::1]:51820
        """
        #expect(VMTunnelManager.allowedIPs(in: config) == ["10.0.0.0/8", "fd00::/8"])
    }

    @Test
    func configuredRoutesReadTheIdentityConfigOnDisk() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let terminal = VMTunnelManager(home: home, purpose: .terminal)
        #expect(terminal.configuredRoutes() == [])
        try FileManager.default.createDirectory(at: terminal.stateDir, withIntermediateDirectories: true)
        try """
        [Interface]
        Address = 100.64.0.2/32

        [Peer]
        PublicKey = Y
        AllowedIPs = 10.0.0.0/8
        """.write(to: terminal.configURL, atomically: true, encoding: .utf8)
        #expect(terminal.configuredRoutes() == ["10.0.0.0/8"])
        // The browser role has no config here; it never reads the terminal role's.
        #expect(VMTunnelManager(home: home).configuredRoutes() == [])
    }

    @Test
    func tunnelDecoderAcceptsPayloadFromOlderCloudBackend() throws {
        let endpoint = try VMClient.decodeTunnelEndpoint([
            "tunnelId": "provider-tunnel-1",
            "provider": "freestyle",
            "deviceFingerprint": "mac-old-client",
            "clientConfig": "[Interface]\nPrivateKey = \n",
            "clientPublicKey": "client-public-key",
            "serverPublicKey": "server-public-key",
            "endpointPort": 51820,
            "routes": ["10.0.0.0/8"],
            "address": ["ipv4": "100.64.0.2"],
            "network": ["id": "network-1", "cidr": "10.0.0.0/24"],
        ], fallbackPurpose: "browser")

        // The pre-access-grant endpoint did not send these fields. They are
        // local metadata during the additive rollout, not credentials.
        #expect(endpoint.accessGrantId == "provider-tunnel-1")
        #expect(endpoint.tunnelPurpose == "browser")
        #expect(endpoint.networkCidr == "10.0.0.0/24")
    }
}
