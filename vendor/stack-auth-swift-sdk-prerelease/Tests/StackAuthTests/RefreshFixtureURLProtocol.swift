import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URL loading owns initialization; the fixture actor serializes response delivery.
final class RefreshFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    #if canImport(FoundationNetworking)
    // corelibs URLSession removes cancelled tasks before stopLoading returns. Serialize
    // that synchronous callback with response delivery so a late fixture never calls a
    // client for an unregistered task. URL loading owns the other inherited state.
    private let stopLock = NSLock()
    private var stopped = false
    #endif
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { await RefreshTransportFixture.routes.route(self) } }
    override func stopLoading() {
        #if canImport(FoundationNetworking)
        stopLock.withLock { stopped = true }
        #endif
    }
    func respond(status: Int, token: String) {
        #if canImport(FoundationNetworking)
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return }
        #endif
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"access_token\":\"\(token)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
