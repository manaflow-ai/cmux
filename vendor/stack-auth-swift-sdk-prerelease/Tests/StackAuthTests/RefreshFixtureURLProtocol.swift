import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URL loading owns initialization; the fixture actor serializes response delivery.
final class RefreshFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    #if canImport(FoundationNetworking)
    // corelibs URLSession unregisters a cancelled or timed-out task, then traps
    // ("Trying to access a behaviour for a task that in not in the registry")
    // when the protocol's client is called for it; Darwin ignores such calls.
    // A late `respond` after `stopLoading` is therefore dropped here, under one
    // lock so a cancellation cannot land between its three client calls.
    private let stopLock = NSLock()
    private var stopped = false
    #endif
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { await RefreshTransportFixture.routes.route(self) } }
    #if canImport(FoundationNetworking)
    override func stopLoading() { stopLock.withLock { stopped = true } }
    #else
    override func stopLoading() {}
    #endif
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
