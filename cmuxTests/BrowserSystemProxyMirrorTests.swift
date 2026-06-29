import CFNetwork
import Foundation
import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5888:
// the browser pane must reach loopback directly even when a macOS system
// proxy is active. WebKit has no implicit loopback bypass, so an active
// system proxy is mirrored into explicit proxy configurations only when
// Network.framework can represent it faithfully. The produced configurations
// must exclude loopback plus the user's proxy bypass list, and the mirror must
// fail closed (keep the system proxy) whenever the system policy cannot be
// represented faithfully.
@Suite struct BrowserSystemProxyMirrorTests {
    /// A matched HTTP + HTTPS system web-proxy pair. This is deliberately not
    /// mirrored because Network.framework's HTTP CONNECT proxy is not the same
    /// policy as a system forward proxy.
    private func webProxySettings(
        host: String = "proxy.example.com",
        port: Any = 8888,
        httpHost: String? = nil,
        httpPort: Any? = nil,
        bypassList: [Any]? = nil
    ) -> [String: Any] {
        var settings: [String: Any] = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: httpHost ?? host,
            kCFNetworkProxiesHTTPPort as String: httpPort ?? port,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
        if let bypassList {
            settings[kCFNetworkProxiesExceptionsList as String] = bypassList
        }
        return settings
    }

    private func socksProxySettings(
        host: String = "socks.example.com",
        port: Any = 1080,
        bypassList: [Any]? = nil
    ) -> [String: Any] {
        var settings: [String: Any] = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: host,
            kCFNetworkProxiesSOCKSPort as String: port,
        ]
        if let bypassList {
            settings[kCFNetworkProxiesExceptionsList as String] = bypassList
        }
        return settings
    }

    // MARK: - Proxy inactive

    @Test("No system proxy is not mirrored")
    func noSystemProxyIsNotMirrored() {
        #expect(BrowserSystemProxyMirror(systemProxySettings: [:]) == nil)
    }

    @Test("Disabled proxies are not mirrored even when endpoints are present")
    func disabledProxiesAreNotMirrored() {
        let settings: [String: Any] = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPProxy as String: "proxy.example.com",
            kCFNetworkProxiesHTTPPort as String: 8888,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesHTTPSProxy as String: "proxy.example.com",
            kCFNetworkProxiesHTTPSPort as String: 8888,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesSOCKSProxy as String: "socks.example.com",
            kCFNetworkProxiesSOCKSPort as String: 1080,
        ]
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    // MARK: - Mirrored proxy mapping

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/5703:
    // macOS bypasses the system proxy for `localhost` but NOT for `*.localhost`
    // subdomains, so a matched HTTP+HTTPS system web proxy (the common
    // Clash/Surge/mihomo mixed-port setup) leaves `tenant.localhost:PORT` dev
    // servers unreachable in the browser pane. A matched web proxy is now
    // mirrored as a single CONNECT proxy with the loopback family excluded.
    @Test("A matched HTTP+HTTPS web proxy mirrors as CONNECT with loopback excluded (#5703)")
    func matchedWebProxyMirrorsAsHTTPCONNECT() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(systemProxySettings: webProxySettings())
        )
        #expect(mirror.excludedDomains == BrowserSystemProxyMirror.implicitExclusions)
    }

    @Test("A SOCKS proxy with no web proxy mirrors to a SOCKSv5 proxy")
    func socksProxyMirrorsToSOCKSv5() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(systemProxySettings: socksProxySettings())
        )
        #expect(mirror.proxy == .socksV5(host: "socks.example.com", port: 1080))
    }

    @Test("A matched web proxy mirrors (as CONNECT) even while SOCKS is also active")
    func matchedWebProxyMirrorsEvenWithSOCKS() throws {
        var settings = webProxySettings()
        settings.merge(socksProxySettings()) { current, _ in current }
        let mirror = try #require(BrowserSystemProxyMirror(systemProxySettings: settings))
        #expect(mirror.excludedDomains == BrowserSystemProxyMirror.implicitExclusions)
    }

    @Test("SOCKS host is trimmed and accepts the highest port")
    func socksHostIsTrimmed() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(
                systemProxySettings: socksProxySettings(
                    host: " proxy.example.com ",
                    port: 65535
                )
            )
        )
        #expect(mirror.proxy == .socksV5(host: "proxy.example.com", port: 65535))
    }

    @Test("Boolean enable flags are accepted")
    func booleanEnableFlagsAreAccepted() throws {
        let settings: [String: Any] = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "socks.example.com",
            kCFNetworkProxiesSOCKSPort as String: 1080,
        ]
        let mirror = try #require(BrowserSystemProxyMirror(systemProxySettings: settings))
        #expect(mirror.proxy == .socksV5(host: "socks.example.com", port: 1080))
    }

    // MARK: - Unmappable settings fail closed (keep the system proxy)

    @Test("A plain HTTP proxy without a secure counterpart is not mirrored")
    func plainHTTPOnlyProxyIsNotMirrored() {
        let settings: [String: Any] = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "proxy.example.com",
            kCFNetworkProxiesHTTPPort as String: 8888,
        ]
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    @Test("An HTTPS-only web proxy is not mirrored")
    func httpsOnlyProxyIsNotMirrored() {
        let settings: [String: Any] = [
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "proxy.example.com",
            kCFNetworkProxiesHTTPSPort as String: 8888,
        ]
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    @Test("Split HTTP/HTTPS web-proxy endpoints are not mirrored")
    func splitWebProxyEndpointsAreNotMirrored() {
        let differentPort = webProxySettings(httpPort: 8080)
        #expect(BrowserSystemProxyMirror(systemProxySettings: differentPort) == nil)

        let differentHost = webProxySettings(httpHost: "other-proxy.example.com")
        #expect(BrowserSystemProxyMirror(systemProxySettings: differentHost) == nil)
    }

    @Test("SOCKS is not mirrored while any web proxy is active")
    func socksIsNotMirroredWhileWebProxyIsActive() {
        var httpsOnly: [String: Any] = [
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "proxy.example.com",
            kCFNetworkProxiesHTTPSPort as String: 8888,
        ]
        httpsOnly.merge(socksProxySettings()) { current, _ in current }
        #expect(BrowserSystemProxyMirror(systemProxySettings: httpsOnly) == nil)
    }

    @Test("An invalid web-proxy endpoint declines the mirror even with SOCKS available")
    func invalidWebProxyDeclinesEvenWithSOCKS() {
        var settings = webProxySettings(host: "   ")
        settings.merge(socksProxySettings()) { current, _ in current }
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    @Test("PAC configurations are not mirrored")
    func pacConfigurationIsNotMirrored() {
        var settings = socksProxySettings()
        settings[kCFNetworkProxiesProxyAutoConfigEnable as String] = 1
        settings[kCFNetworkProxiesProxyAutoConfigURLString as String] = "http://pac.example.com/proxy.pac"
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    @Test("WPAD auto-discovery is not mirrored")
    func wpadAutoDiscoveryIsNotMirrored() {
        var settings = socksProxySettings()
        settings[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] = 1
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    @Test("Exclude-simple-hostnames declines the mirror")
    func excludeSimpleHostnamesDeclinesTheMirror() {
        var settings = socksProxySettings()
        settings[kCFNetworkProxiesExcludeSimpleHostnames as String] = 1
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    @Test("Invalid endpoints are not mirrored")
    func invalidEndpointsAreNotMirrored() {
        let invalidEndpoints: [(host: String, port: Int)] = [
            (host: "", port: 8888),
            (host: "proxy.example.com", port: 0),
            (host: "proxy.example.com", port: -1),
            (host: "proxy.example.com", port: 65536),
        ]
        for endpoint in invalidEndpoints {
            let settings = socksProxySettings(host: endpoint.host, port: endpoint.port)
            #expect(
                BrowserSystemProxyMirror(systemProxySettings: settings) == nil,
                "host=\(endpoint.host) port=\(endpoint.port)"
            )
        }
    }

    @Test("A missing port is not mirrored")
    func missingPortIsNotMirrored() {
        let settings: [String: Any] = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "socks.example.com",
        ]
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    // MARK: - Excluded domains (loopback bypass + system bypass list)

    @Test("Loopback and the metadata endpoint are always excluded from the mirrored proxy")
    func loopbackIsAlwaysExcluded() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(systemProxySettings: socksProxySettings())
        )
        #expect(mirror.excludedDomains == BrowserSystemProxyMirror.implicitExclusions)
        for host in ["localhost", "127.0.0.1", "::1", "local", "169.254.169.254", "169.254.170.2"] {
            #expect(mirror.excludedDomains.contains(host))
        }
    }

    @Test("System bypass-list entries merge after the loopback defaults")
    func bypassListMergesAfterLoopbackDefaults() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(
                systemProxySettings: socksProxySettings(
                    bypassList: ["intranet.corp.example", "printer.home.arpa"]
                )
            )
        )
        #expect(
            mirror.excludedDomains ==
                BrowserSystemProxyMirror.implicitExclusions +
                ["intranet.corp.example", "printer.home.arpa"]
        )
    }

    @Test("Bypass entries are trimmed, lowercased, wildcard-stripped, and deduplicated")
    func bypassEntriesAreNormalizedAndDeduplicated() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(
                systemProxySettings: socksProxySettings(
                    bypassList: [
                        "*.local",
                        "MyHost.Corp",
                        " padded.example.com ",
                        ".dotted.example.com",
                        "localhost",
                        "::1",
                        "myhost.corp",
                    ]
                )
            )
        )
        #expect(
            mirror.excludedDomains ==
                BrowserSystemProxyMirror.implicitExclusions +
                ["myhost.corp", "padded.example.com", "dotted.example.com"]
        )
    }

    @Test("The default link-local CIDR is skipped without blocking the mirror")
    func defaultLinkLocalCIDRIsSkippedWithoutBlocking() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(
                systemProxySettings: socksProxySettings(
                    bypassList: ["*.local", "169.254/16", "169.254.0.0/16", "kept.example.com"]
                )
            )
        )
        #expect(
            mirror.excludedDomains ==
                BrowserSystemProxyMirror.implicitExclusions + ["kept.example.com"]
        )
    }

    @Test("Deliberate CIDR bypass rules decline the mirror")
    func deliberateCIDRBypassRulesDeclineTheMirror() {
        for cidr in ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "fd00::/8"] {
            let settings = socksProxySettings(bypassList: [cidr])
            #expect(
                BrowserSystemProxyMirror(systemProxySettings: settings) == nil,
                "cidr=\(cidr)"
            )
        }
    }

    @Test("Non-leading wildcard bypass rules decline the mirror")
    func wildcardBypassRulesDeclineTheMirror() {
        let settings = socksProxySettings(bypassList: ["host.*.example.com"])
        #expect(BrowserSystemProxyMirror(systemProxySettings: settings) == nil)
    }

    @Test("Noise bypass entries are dropped without blocking the mirror")
    func noiseBypassEntriesAreDroppedWithoutBlocking() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(
                systemProxySettings: socksProxySettings(
                    bypassList: ["", "   ", "*.", "kept.example.com"]
                )
            )
        )
        #expect(
            mirror.excludedDomains ==
                BrowserSystemProxyMirror.implicitExclusions + ["kept.example.com"]
        )
    }

    @Test("Non-string bypass entries are ignored")
    func nonStringBypassEntriesAreIgnored() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(
                systemProxySettings: socksProxySettings(
                    bypassList: [42, NSNull(), "kept.example.com"]
                )
            )
        )
        #expect(
            mirror.excludedDomains ==
                BrowserSystemProxyMirror.implicitExclusions + ["kept.example.com"]
        )
    }

    // MARK: - ProxyConfiguration conversion

    /// Reads the exclusions from the underlying `nw_proxy_config` — the
    /// representation WebKit actually consumes. The Swift
    /// `ProxyConfiguration.excludedDomains` getter returns `[]` even after a
    /// successful set (observed on macOS 15 and 26; the setter does write
    /// through to the C config), so asserting via the getter would test an
    /// Apple getter bug instead of the produced configuration.
    private func enumeratedExcludedDomains(_ configuration: ProxyConfiguration) -> [String] {
        var domains: [String] = []
        nw_proxy_config_enumerate_excluded_domains(configuration._nw) { domain in
            domains.append(String(cString: domain))
        }
        return domains
    }

    @Test("A SOCKS mirror produces one proxy configuration carrying the exclusions")
    func socksMirrorProducesConfigurationWithExclusions() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(
                systemProxySettings: socksProxySettings(bypassList: ["intranet.corp.example"])
            )
        )
        let configurations = mirror.proxyConfigurations()
        #expect(configurations.count == 1)
        let configuration = try #require(configurations.first)
        #expect(enumeratedExcludedDomains(configuration) == mirror.excludedDomains)
        #expect(configuration.allowFailover == false)
    }
}
