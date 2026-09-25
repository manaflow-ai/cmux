import Foundation
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud browser route adoption")
struct CloudBrowserRouteAdoptionTests {
    @Test("A committed same-VM redirect retains readiness without replaying navigation")
    func committedRouteIsObservedInPlace() async throws {
        let state = CloudBrowserAccessState()
        let endpoint = CloudBrowserProxyEndpoint(
            host: "127.0.0.1", port: 48_001,
            username: "fixture", password: "fixture"
        )
        let model = CloudPortAccessModel(
            target: .init(host: "10.16.0.70", port: 6901),
            coordinator: nil,
            wake: {},
            startForward: { _ in throw CancellationError() },
            stopForward: {},
            startBrowserProxy: { endpoint }
        )
        let initial = URL(string: "http://10.16.0.70:6901/vnc.html")!
        let redirected = URL(string: "http://10.16.0.70:6902/vnc.html")!
        let resource = SurfaceResourceID(machine: .cloud("route-adoption"), kind: .display, key: "display:1")
        var navigationRequests = 0
        state.automaticallyNavigate { _ in navigationRequests += 1 }
        state.configure(model: model, url: initial, resourceID: resource)
        state.adoptCommittedRoute(model: model, url: redirected, resourceID: resource)
        model.connect()
        try #require(await AppKitTestEventPump().waitUntil { model.isReady })

        #expect(state.navigationURL == redirected)
        #expect(state.hasCommittedNavigation)
        #expect(state.model === model)
        #expect(state.remoteURL == redirected)
        #expect(navigationRequests == 0)
    }
}
