import Foundation

actor RefreshFixtureRoutes {
    private var routes: [String: RefreshTransportFixture] = [:]
    func register(_ fixture: RefreshTransportFixture, host: String) { routes[host] = fixture }
    func remove(host: String) { routes[host] = nil }
    func route(_ request: RefreshFixtureURLProtocol) async {
        if let host = request.request.url?.host, let fixture = routes[host] {
            await fixture.receive(request)
        }
    }
}
