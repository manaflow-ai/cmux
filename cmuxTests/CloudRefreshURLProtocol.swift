import Foundation

/// URLProtocol's synchronous callbacks hand off to one actor; only that actor
/// reads the fixture state or calls the client, including after stopLoading.
final class CloudRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable { case normal, statsUnavailable, listUnavailable, throttled }
    private static let responses = Responses()
    /// Fixture state is keyed per request, not by object address: URLSession
    /// frees a finished protocol, and the next request can reuse its address,
    /// which made a fresh request look already stopped and never answer.
    private let requestID = UUID()
    static func holdResponses() async { await responses.hold() }
    static func releaseResponses() async { await responses.release() }
    static func configure(_ behavior: Behavior) async { await responses.configure(behavior) }
    static func waitUntilStarted(_ count: Int = 1) async { await responses.waitUntilStarted(count) }
    static func currentStopCount() async -> Int { await responses.stopCount }
    static func waitUntilStopped(after baseline: Int) async { await responses.waitUntilStopped(after: baseline) }
    static func lastTeamID() async -> String? { await responses.lastTeamID }
    static func reset() async { await responses.reset() }
    static func requestCounts() async -> [String: Int] { await responses.counts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { await Self.responses.start(self) } }
    override func stopLoading() { Task { await Self.responses.stop(self) } }

    private actor Responses {
        private(set) var counts: [String: Int] = [:]
        private(set) var lastTeamID: String?
        private var tasks: [UUID: Task<Void, Never>] = [:]
        private var behavior = Behavior.normal
        private var held = false
        private var responseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        func hold() { held = true }
        func release() {
            held = false
            let pending = responseWaiters
            responseWaiters.removeAll()
            for waiter in pending.values { waiter.resume() }
        }
        private var stoppedRequests: Set<UUID> = []
        private(set) var stopCount = 0
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var stopWaiters: [(after: Int, CheckedContinuation<Void, Never>)] = []
        func configure(_ value: Behavior) { behavior = value }
        func waitUntilStarted(_ count: Int) async {
            guard counts.values.reduce(0, +) < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }
        func waitUntilStopped(after baseline: Int) async {
            guard stopCount <= baseline else { return }
            await withCheckedContinuation { stopWaiters.append((baseline, $0)) }
        }
        func reset() {
            release()
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            counts.removeAll()
            lastTeamID = nil
            behavior = .normal
            stoppedRequests.removeAll()
            stopCount = 0
        }
        func start(_ source: CloudRefreshURLProtocol) {
            let key = source.requestID
            guard !stoppedRequests.contains(key) else { return }
            let path = source.request.url!.path
            lastTeamID = source.request.value(forHTTPHeaderField: "X-Cmux-Team-Id")
            counts[path, default: 0] += 1
            let count = counts.values.reduce(0, +)
            let ready = startWaiters.filter { $0.0 <= count }
            startWaiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
            let behavior = self.behavior
            tasks[key] = Task {
                guard !Task.isCancelled else { return }
                if self.held { await withCheckedContinuation { self.responseWaiters[key] = $0 } }
                guard self.tasks.removeValue(forKey: key) != nil else { return }
                let unavailable = path.hasSuffix("/stats") ? behavior == .statsUnavailable : behavior == .listUnavailable
                let response = HTTPURLResponse(url: source.request.url!, statusCode: behavior == .throttled ? 429 : unavailable ? 503 : 200, httpVersion: nil,
                    headerFields: behavior == .throttled ? ["Retry-After": "60"] : nil)!
                source.client?.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed)
                let body: String
                if path == "/api/coderouter/vm-usage/team" {
                    body = #"{"teamId":"fixture-team","kind":"ready","periodDays":30,"machines":[]}"#
                } else if path.hasSuffix("/stats") {
                    body = #"{"state":"awake","cpus":2}"#
                } else {
                    body = #"{"vms":[{"id":"fixture-0","provider":"fixture","image":"desktop-vnc","status":"running","createdAt":0,"capabilities":{"stats":true}}]}"#
                }
                source.client?.urlProtocol(source, didLoad: Data(body.utf8))
                source.client?.urlProtocolDidFinishLoading(source)
            }
        }
        func stop(_ source: CloudRefreshURLProtocol) {
            let key = source.requestID
            guard stoppedRequests.insert(key).inserted else { return }
            tasks.removeValue(forKey: key)?.cancel()
            responseWaiters.removeValue(forKey: key)?.resume()
            stopCount += 1
            let waiters = stopWaiters.filter { $0.after < stopCount }
            stopWaiters.removeAll { $0.after < stopCount }
            for (_, waiter) in waiters { waiter.resume() }
        }
    }
}
