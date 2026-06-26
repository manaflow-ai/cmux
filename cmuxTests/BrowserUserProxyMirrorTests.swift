import CFNetwork
import CmuxSettings
import Foundation
import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Coverage for https://github.com/manaflow-ai/cmux/issues/6639: the embedded
// browser must route through an explicit user-configured proxy (cmux.json
// `browser.proxy` / CMUX_BROWSER_PROXY) when one is enabled. The produced
// Network.framework configurations must carry the configured proxy plus the
// always-on loopback exclusions merged with the user's bypass list, keep
// failover disabled, and yield nothing when no usable proxy is configured.
@Suite struct BrowserUserProxyMirrorTests {
    /// Reads the exclusions from the underlying `nw_proxy_config` — the
    /// representation WebKit actually consumes. The Swift
    /// `ProxyConfiguration.excludedDomains` getter returns `[]` even after a
    /// successful set, so asserting via the getter would test an Apple getter
    /// bug instead of the produced configuration (see BrowserSystemProxyMirrorTests).
    private func enumeratedExcludedDomains(_ configuration: ProxyConfiguration) -> [String] {
        var domains: [String] = []
        nw_proxy_config_enumerate_excluded_domains(configuration._nw) { domain in
            domains.append(String(cString: domain))
        }
        return domains
    }

    private func socksConfiguration(
        host: String = "127.0.0.1",
        port: Int = 1080,
        username: String = "",
        password: String = "",
        bypass: [String] = []
    ) -> BrowserProxyConfiguration {
        BrowserProxyConfiguration(
            type: .socks5, host: host, port: port,
            username: username, password: password, bypass: bypass
        )
    }

    // MARK: - No proxy produced

    @Test("A disabled configuration produces no proxy")
    func disabledConfigurationProducesNoProxy() {
        #expect(BrowserUserProxyMirror.proxyConfigurations(for: .disabled) == nil)
    }

    @Test("An off-type configuration produces no proxy even with a host and port")
    func offTypeConfigurationProducesNoProxy() {
        let config = BrowserProxyConfiguration(
            type: .off, host: "127.0.0.1", port: 1080,
            username: "", password: "", bypass: []
        )
        #expect(BrowserUserProxyMirror.proxyConfigurations(for: config) == nil)
    }

    @Test("Out-of-range ports produce no proxy")
    func outOfRangePortsProduceNoProxy() {
        for port in [0, -1, 65536, 70000] {
            #expect(
                BrowserUserProxyMirror.proxyConfigurations(for: socksConfiguration(port: port)) == nil,
                "port=\(port)"
            )
        }
    }

    // MARK: - Proxy produced

    @Test("A SOCKS5 configuration produces one configuration with failover disabled")
    func socksConfigurationProducesOneConfiguration() throws {
        let configurations = try #require(
            BrowserUserProxyMirror.proxyConfigurations(for: socksConfiguration())
        )
        #expect(configurations.count == 1)
        #expect(configurations[0].allowFailover == false)
    }

    @Test("An HTTP CONNECT configuration produces one configuration")
    func httpConnectConfigurationProducesOneConfiguration() throws {
        let config = BrowserProxyConfiguration(
            type: .httpConnect, host: "proxy.example.com", port: 8080,
            username: "", password: "", bypass: []
        )
        let configurations = try #require(BrowserUserProxyMirror.proxyConfigurations(for: config))
        #expect(configurations.count == 1)
    }

    @Test("An authenticated configuration still produces one configuration")
    func authenticatedConfigurationProducesOneConfiguration() throws {
        let config = socksConfiguration(username: "alice", password: "s3cret")
        let configurations = try #require(BrowserUserProxyMirror.proxyConfigurations(for: config))
        #expect(configurations.count == 1)
    }

    // MARK: - Excluded domains

    @Test("Loopback and link-local hosts are always excluded")
    func loopbackIsAlwaysExcluded() throws {
        let configurations = try #require(
            BrowserUserProxyMirror.proxyConfigurations(for: socksConfiguration())
        )
        let excluded = enumeratedExcludedDomains(configurations[0])
        #expect(excluded == BrowserSystemProxyMirror.implicitExclusions)
        for host in ["localhost", "127.0.0.1", "::1", "local", "169.254.169.254", "169.254.170.2"] {
            #expect(excluded.contains(host))
        }
    }

    @Test("User bypass entries merge after the loopback defaults, normalized and deduplicated")
    func userBypassMergesAfterLoopbackDefaults() throws {
        let config = socksConfiguration(
            bypass: ["*.corp.example", "MyHost.Internal", "localhost", " padded.example.com "]
        )
        let configurations = try #require(BrowserUserProxyMirror.proxyConfigurations(for: config))
        let excluded = enumeratedExcludedDomains(configurations[0])
        #expect(
            excluded ==
                BrowserSystemProxyMirror.implicitExclusions +
                ["corp.example", "myhost.internal", "padded.example.com"]
        )
    }

    @Test("mergedExcludedDomains keeps implicit defaults first and drops duplicates")
    func mergedExcludedDomainsKeepsImplicitFirst() {
        let merged = BrowserUserProxyMirror.mergedExcludedDomains(
            userBypass: ["localhost", "corp.example", "127.0.0.1"]
        )
        #expect(merged == BrowserSystemProxyMirror.implicitExclusions + ["corp.example"])
    }

    // MARK: - Injectable resolution (no app singleton)

    @Test("Resolution uses the injected file configuration when no env override is set")
    func resolutionUsesFileConfigurationWithoutEnvOverride() {
        let mirror = BrowserUserProxyMirror(
            fileConfiguration: socksConfiguration(host: "file-host", port: 1080),
            environment: [:]
        )
        #expect(mirror.resolvedConfiguration().host == "file-host")
        let configurations = mirror.proxyConfigurations()
        #expect(configurations?.count == 1)
    }

    @Test("A CMUX_BROWSER_PROXY override wins over the injected file configuration")
    func envOverrideWinsOverFileConfiguration() {
        let mirror = BrowserUserProxyMirror(
            fileConfiguration: socksConfiguration(host: "file-host", port: 1),
            environment: ["CMUX_BROWSER_PROXY": "socks5://127.0.0.1:1080"]
        )
        let resolved = mirror.resolvedConfiguration()
        #expect(resolved.host == "127.0.0.1")
        #expect(resolved.port == 1080)
        #expect(mirror.proxyConfigurations()?.count == 1)
    }

    @Test("A CMUX_BROWSER_PROXY=off override disables an injected file proxy")
    func envOffOverrideDisablesFileProxy() {
        let mirror = BrowserUserProxyMirror(
            fileConfiguration: socksConfiguration(host: "file-host", port: 1080),
            environment: ["CMUX_BROWSER_PROXY": "off"]
        )
        #expect(mirror.resolvedConfiguration() == .disabled)
        #expect(mirror.proxyConfigurations() == nil)
    }

    @Test("A disabled injected configuration produces no proxy")
    func disabledInjectedConfigurationProducesNoProxy() {
        let mirror = BrowserUserProxyMirror(fileConfiguration: .disabled, environment: [:])
        #expect(mirror.proxyConfigurations() == nil)
    }
}
