import Foundation

/// URLProtocol's synchronous callbacks hand off to one actor; only that actor
/// reads the fixture state or calls the client, including after stopLoading.
final class CloudRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable { case normal, statsUnavailable, listUnavailable, throttled }
    private static let responses = Responses()
    static func holdResponses() async { await responses.hold() }
    static func releaseResponses() async { await responses.release() }
    static func configure(_ behavior: Behavior) async { await responses.configure(behavior) }
    static func waitUntilStarted(_ count: Int = 1) async { await responses.waitUntilStarted(count) }
    static func waitUntilStopped() async { await responses.waitUntilStopped() }
    static func reset() async { await responses.reset() }
    static func requestCounts() async -> [String: Int] { await responses.counts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { await Self.responses.start(self) } }
    override func stopLoading() { Task { await Self.responses.stop(self) } }

    private actor Responses {
        private(set) var counts: [String: Int] = [:]
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var behavior = Behavior.normal
        private var held = false
        private var responseWaiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
        func hold() { held = true }
        func release() {
            held = false
            let pending = responseWaiters
            responseWaiters.removeAll()
            for waiter in pending.values { waiter.resume() }
        }
        private var stopped = false
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var stopWaiters: [CheckedContinuation<Void, Never>] = []
        func configure(_ value: Behavior) { behavior = value }
        func waitUntilStarted(_ count: Int) async {
            guard counts.values.reduce(0, +) < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }
        func waitUntilStopped() async {
            guard !stopped else { return }
            await withCheckedContinuation { stopWaiters.append($0) }
        }
        func reset() {
            release()
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            counts.removeAll()
            behavior = .normal
            stopped = false
        }
        func start(_ source: CloudRefreshURLProtocol) {
            let key = ObjectIdentifier(source)
            let path = source.request.url!.path
            counts[path, default: 0] += 1
            let count = counts.values.reduce(0, +)
            let ready = startWaiters.filter { $0.0 <= count }
            startWaiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
            let behavior = self.behavior
            tasks[key] = Task {
                guard !Task.isCancelled else { return }
                if self.held { await withCheckedContinuation { self.responseWaiters[key] = $0 } }
                // The fixture models a slow HTTP response, not a wait for test
                // state to settle. All callers run against that same latency.
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard self.tasks.removeValue(forKey: key) != nil else { return }
                let unavailable = path.hasSuffix("/stats") ? behavior == .statsUnavailable : behavior == .listUnavailable
                let response = HTTPURLResponse(url: source.request.url!, statusCode: behavior == .throttled ? 429 : unavailable ? 503 : 200, httpVersion: nil,
                    headerFields: behavior == .throttled ? ["Retry-After": "60"] : nil)!
                source.client?.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed)
                let body = path.hasSuffix("/stats") ? #"{"state":"awake","cpus":2}"# : #"{"vms":[{"id":"fixture-0","provider":"fixture","image":"desktop-vnc","status":"running","createdAt":0,"capabilities":{"stats":true}}]}"#
                source.client?.urlProtocol(source, didLoad: Data(body.utf8))
                source.client?.urlProtocolDidFinishLoading(source)
            }
        }
        func stop(_ source: CloudRefreshURLProtocol) {
            tasks.removeValue(forKey: ObjectIdentifier(source))?.cancel()
            responseWaiters.removeValue(forKey: ObjectIdentifier(source))?.resume()
            stopped = true
            let waiters = stopWaiters
            stopWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
}
