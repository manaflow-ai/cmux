import Foundation

/// URLProtocol's synchronous callbacks hand off to one actor; only that actor
/// reads the fixture state or calls the client, including after stopLoading.
final class CloudRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    private static let responses = Responses()
    static func reset() async { await responses.reset() }
    static func requestCounts() async -> [String: Int] { await responses.counts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { await Self.responses.start(self) } }
    override func stopLoading() { Task { await Self.responses.stop(self) } }

    private actor Responses {
        private(set) var counts: [String: Int] = [:]
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        func reset() {
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            counts.removeAll()
        }
        func start(_ source: CloudRefreshURLProtocol) {
            let key = ObjectIdentifier(source)
            let path = source.request.url!.path
            counts[path, default: 0] += 1
            tasks[key] = Task {
                // The fixture models a slow HTTP response, not a wait for test
                // state to settle. All callers run against that same latency.
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard self.tasks.removeValue(forKey: key) != nil else { return }
                let response = HTTPURLResponse(url: source.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                source.client?.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed)
                let body = path.hasSuffix("/stats") ? #"{"state":"awake","cpus":2}"# : #"{"vms":[]}"#
                source.client?.urlProtocol(source, didLoad: Data(body.utf8))
                source.client?.urlProtocolDidFinishLoading(source)
            }
        }
        func stop(_ source: CloudRefreshURLProtocol) {
            tasks.removeValue(forKey: ObjectIdentifier(source))?.cancel()
        }
    }
}
