import Foundation

final class RovoDevOversizedTranscriptURLProtocol: URLProtocol {
    static let scheme = "cmux-rovodev-oversized"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == scheme
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let payload = try JSONSerialization.data(withJSONObject: [
                "messages": [
                    [
                        "role": "user",
                        "content": String(repeating: "x", count: 8 * 1024 * 1024 + 1),
                    ],
                ],
            ])
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            client?.urlProtocol(
                self,
                didReceive: URLResponse(
                    url: url,
                    mimeType: "application/json",
                    expectedContentLength: payload.count,
                    textEncodingName: "utf-8"
                ),
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
