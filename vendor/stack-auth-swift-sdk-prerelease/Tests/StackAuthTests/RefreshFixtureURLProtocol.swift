import Foundation

/// URL loading owns initialization; the fixture actor serializes response delivery.
final class RefreshFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { await RefreshTransportFixture.routes.route(self) } }
    override func stopLoading() {}
    func respond(status: Int, token: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"access_token\":\"\(token)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
