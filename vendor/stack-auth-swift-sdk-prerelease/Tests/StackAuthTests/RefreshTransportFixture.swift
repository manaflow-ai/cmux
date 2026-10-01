import Foundation
@testable import StackAuth

/// Each ephemeral URLSession routes to its own actor through a unique synthetic
/// origin. URLProtocol has no instance injection API; this registry is only the
/// callback routing seam, and each fixture unregisters at teardown.
actor RefreshTransportFixture {
    static let routes = RefreshFixtureRoutes()
    let host = UUID().uuidString.lowercased() + ".invalid"
    private var requests: [RefreshFixtureURLProtocol] = []
    private var started: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    private var response: (Int, String)?

    func session() async -> URLSession {
        await Self.routes.register(self, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshFixtureURLProtocol.self]
        return URLSession(configuration: config)
    }

    func receive(_ request: RefreshFixtureURLProtocol) {
        count += 1
        if let response { request.respond(status: response.0, token: response.1) }
        else { requests.append(request) }
        let waiters = started
        started = []
        for waiter in waiters { waiter.resume() }
    }

    func waitForRequest() async {
        if count > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release(status: Int = 200, token: String) {
        response = (status, token)
        let pending = requests
        requests = []
        for request in pending { request.respond(status: status, token: token) }
    }

    func close() async { await Self.routes.remove(host: host) }
}
