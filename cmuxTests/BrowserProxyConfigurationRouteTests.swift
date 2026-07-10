import CFNetwork
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserProxyConfigurationRouteTests {
    @Test("Direct browser networking is left untouched when no explicit proxy is configured")
    @MainActor
    func directNetworkingDoesNotRewriteAnEmptyProxyConfiguration() {
        let store = WKWebsiteDataStore.nonPersistent()
        let didMutate = BrowserProxyConfigurationRoute.direct.apply(to: store)
        #expect(!didMutate)
        #expect(store.proxyConfigurations.isEmpty)
    }

    @Test("An explicit proxy is installed for mirrored-system routing")
    @MainActor
    func explicitProxyConfigurationIsInstalled() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let mirror = try #require(systemProxyMirror())
        let didMutate = BrowserProxyConfigurationRoute.mirroredSystem(mirror).apply(to: store)
        #expect(didMutate)
        #expect(store.proxyConfigurations.count == 1)
    }

    @Test("A removed explicit proxy is cleared from its website data store")
    @MainActor
    func removedProxyConfigurationIsCleared() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let mirror = try #require(systemProxyMirror())
        _ = BrowserProxyConfigurationRoute.mirroredSystem(mirror).apply(to: store)
        let didMutate = BrowserProxyConfigurationRoute.direct.apply(to: store)
        #expect(didMutate)
        #expect(store.proxyConfigurations.isEmpty)
    }

    @Test("A direct transition clears a remembered explicit route even when WebKit reports empty")
    @MainActor
    func directTransitionClearsRememberedExplicitRouteWhenGetterIsEmpty() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let mirror = try #require(systemProxyMirror())
        _ = BrowserProxyConfigurationRoute.mirroredSystem(mirror).apply(to: store)
        store.proxyConfigurations = []

        let didMutate = BrowserProxyConfigurationRoute.direct.apply(to: store)

        #expect(didMutate)
        #expect(store.proxyConfigurations.isEmpty)
    }

    @Test("Direct routing after an explicit proxy keeps clearing retained WebKit state")
    @MainActor
    func directRouteAfterExplicitProxyDoesNotCoalesce() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let mirror = try #require(systemProxyMirror())
        _ = BrowserProxyConfigurationRoute.mirroredSystem(mirror).apply(to: store)

        #expect(BrowserProxyConfigurationRoute.direct.apply(to: store))
        #expect(BrowserProxyConfigurationRoute.direct.apply(to: store))
        #expect(store.proxyConfigurations.isEmpty)
    }

    @Test("An unchanged remote proxy route does not rewrite a shared website data store")
    @MainActor
    func unchangedRemoteProxyRouteDoesNotRewriteSharedStore() {
        let store = WKWebsiteDataStore.nonPersistent()
        let route = BrowserProxyConfigurationRoute.remoteWorkspace(host: "127.0.0.1", port: 1080)
        #expect(route.apply(to: store))
        #expect(!route.apply(to: store))
        #expect(store.proxyConfigurations.count == 2)
    }

    private func systemProxyMirror() -> BrowserSystemProxyMirror? {
        BrowserSystemProxyMirror(systemProxySettings: [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "proxy.example.com",
            kCFNetworkProxiesSOCKSPort as String: 1080,
        ])
    }
}
