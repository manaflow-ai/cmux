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
    /// A matched HTTP + HTTPS system web-proxy pair (both enabled, one
    /// endpoint). With a loopback `host` this is the common Clash/Surge/mihomo
    /// mixed-port setup that is mirrored as a single CONNECT proxy with loopback
    /// excluded (#5703); the default remote host stays fail-closed (#5959).
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
    // subdomains, so a matched HTTP+HTTPS system web proxy on loopback (the
    // common Clash/Surge/mihomo mixed-port setup on 127.0.0.1) leaves
    // `tenant.localhost:PORT` dev servers unreachable in the browser pane. A
    // matched loopback web proxy is now mirrored as a single CONNECT proxy with
    // the loopback family excluded.
    @Test("A matched loopback HTTP+HTTPS web proxy mirrors as CONNECT with loopback excluded (#5703)")
    func matchedLoopbackWebProxyMirrorsAsHTTPCONNECT() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(systemProxySettings: webProxySettings(host: "127.0.0.1"))
        )
        #expect(mirror.proxy == .httpCONNECT(host: "127.0.0.1", port: 8888))
        #expect(mirror.excludedDomains == BrowserSystemProxyMirror.implicitExclusions)
    }

    @Test("A remote (non-loopback) matched web proxy is not mirrored as CONNECT")
    func remoteMatchedWebProxyDeclinesTheMirror() {
        // A corporate/remote forward proxy may be forward-only or require auth a
        // CONNECT ProxyConfiguration cannot carry, so it stays on WebKit's
        // native system-proxy path (#5959). "127.proxy.corp.example" is a DNS
        // name, not the 127.0.0.0/8 loopback block, so the loopback gate must
        // not treat its "127." prefix as a local proxy.
        for host in ["proxy.example.com", "10.0.0.5", "127.proxy.corp.example"] {
            #expect(
                BrowserSystemProxyMirror(systemProxySettings: webProxySettings(host: host)) == nil,
                "host=\(host)"
            )
        }
    }

    @Test("Every loopback proxy-host form mirrors as CONNECT (#5703)")
    func loopbackProxyHostVariantsMirror() throws {
        for host in ["localhost", "::1", "127.0.0.5"] {
            let mirror = try #require(
                BrowserSystemProxyMirror(systemProxySettings: webProxySettings(host: host)),
                "host=\(host)"
            )
            #expect(mirror.proxy == .httpCONNECT(host: host, port: 8888), "host=\(host)")
        }
    }

    @Test("A SOCKS proxy with no web proxy mirrors to a SOCKSv5 proxy")
    func socksProxyMirrorsToSOCKSv5() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(systemProxySettings: socksProxySettings())
        )
        #expect(mirror.proxy == .socksV5(host: "socks.example.com", port: 1080))
    }

    @Test("A matched loopback web proxy mirrors (as CONNECT) even while SOCKS is also active")
    func matchedLoopbackWebProxyMirrorsEvenWithSOCKS() throws {
        var settings = webProxySettings(host: "127.0.0.1")
        settings.merge(socksProxySettings()) { current, _ in current }
        let mirror = try #require(BrowserSystemProxyMirror(systemProxySettings: settings))
        #expect(mirror.proxy == .httpCONNECT(host: "127.0.0.1", port: 8888))
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

    @Test("Exclude-simple-hostnames declines before any bypass-list processing")
    func excludeSimpleHostnamesDeclinesRegardlessOfBypassList() {
        // The decline takes precedence over the bypass-list merge, so neither a
        // representable domain entry nor a deliberate CIDR changes the outcome:
        // mirroring would route dot-less intranet hosts (which the OS bypasses
        // under this flag) to the proxy, a privacy regression we avoid.
        for bypassList in [["intranet.corp.example"], ["10.0.0.0/8"], ["intranet.corp.example", "10.0.0.0/8"]] {
            var settings = socksProxySettings(bypassList: bypassList)
            settings[kCFNetworkProxiesExcludeSimpleHostnames as String] = 1
            #expect(
                BrowserSystemProxyMirror(systemProxySettings: settings) == nil,
                "bypassList=\(bypassList)"
            )
        }
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

    @Test("A matched loopback web-proxy mirror produces one CONNECT configuration carrying the exclusions")
    func webProxyMirrorProducesConfigurationWithExclusions() throws {
        let mirror = try #require(
            BrowserSystemProxyMirror(
                systemProxySettings: webProxySettings(host: "127.0.0.1", bypassList: ["intranet.corp.example"])
            )
        )
        #expect(mirror.proxy == .httpCONNECT(host: "127.0.0.1", port: 8888))
        #expect(
            mirror.excludedDomains ==
                BrowserSystemProxyMirror.implicitExclusions + ["intranet.corp.example"]
        )
        let configurations = mirror.proxyConfigurations()
        #expect(configurations.count == 1)
        let configuration = try #require(configurations.first)
        #expect(enumeratedExcludedDomains(configuration) == mirror.excludedDomains)
        #expect(configuration.allowFailover == false)
    }
}
