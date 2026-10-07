public import CmuxiOSFeatureKit
public import CmuxLink
public import CmuxLinkDirect
public import CmuxMobileConnect
public import CmuxMobileLink
public import CmuxPairing
import Foundation

/// The signed-in account's links to its Macs (d1-terminal-ux.md section 2):
/// a `MobileLinkRegistry` fed with routes from B6's trust store joined with
/// Bonjour results and saved direct addresses (`MobileRouteBook`), and with
/// every NWPathMonitor snapshot. One per process; `start` binds an account,
/// `stop` (sign-out, account switch) closes every client.
@MainActor
public final class AccountLinkDirectory: MobileLinkDirectory {
    /// How long `client(for:)` waits for the trust store to name a Mac.
    public static let routeWait: Duration = .seconds(10)

    private var registry: MobileLinkRegistry?
    private var ready: Task<MobileLinkRegistry?, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var browser: DirectBrowser?
    private var book = MobileRouteBook()
    private var trusted: [String: TrustedHostKey] = [:]
    private var routeWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var generation = 0
    private let clock: any Clock<Duration>

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Binds the account. `saved` streams the user's direct addresses (C9/B4
    /// host records); `browse` starts Bonjour (`_cmux._tcp`, Local Network).
    public func start(bootstrap: @escaping @Sendable () async throws -> AccountLinkBootstrap,
                      saved: AsyncStream<[DirectEndpoint]>? = nil, browse: Bool = true) {
        stop()
        generation += 1
        let current = generation
        let monitor = DirectReachabilityMonitor()
        ready = Task { [weak self] in
            guard let made = try? await bootstrap(), let self, self.generation == current else { return nil }
            let registry = MobileLinkRegistry(credentials: made.credentials, options: made.options,
                                              snapshot: monitor.currentSnapshot, signaling: made.signaling)
            self.registry = registry
            self.follow(made, monitor: monitor, saved: saved, browse: browse, generation: current)
            return registry
        }
    }

    /// Closes every client and stops following. A later `start` binds again.
    public func stop() {
        generation += 1
        ready?.cancel()
        ready = nil
        for task in tasks { task.cancel() }
        tasks.removeAll()
        browser?.stop()
        browser = nil
        registry?.close()
        registry = nil
        book = MobileRouteBook()
        trusted = [:]
        for waiter in routeWaiters.values { waiter.finish() }
        routeWaiters.removeAll()
    }

    public func client(for host: HostID) async -> MobileLinkClient? {
        guard let registry = await ready?.value else { return nil }
        if let client = registry.client(for: host.rawValue) { return client }
        let changes = routeChanges()
        let clock = self.clock
        let wait = Self.routeWait
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                for await _ in changes where self?.registry?.client(for: host.rawValue) != nil { return }
            }
            group.addTask {
                // wakeup-allow: one-shot bound on waiting for the trust store's first snapshot, injected clock, cancelled when the Mac appears
                try? await clock.sleep(for: wait)
            }
            await group.next()
            group.cancelAll()
        }
        return self.registry?.client(for: host.rawValue)
    }

    /// The live path badge per Mac host id (Settings diagnostics).
    public func pathBadges() async -> AsyncStream<[String: PathBadge]> {
        guard let registry = await ready?.value else { return AsyncStream { $0.finish() } }
        return registry.pathBadges()
    }

    /// The trust store's answer for a Mac (its install, own account or not).
    public func trustedHost(_ host: String) -> TrustedHostKey? { trusted[host] }

    // MARK: Private

    private func follow(_ made: AccountLinkBootstrap, monitor: DirectReachabilityMonitor,
                        saved: AsyncStream<[DirectEndpoint]>?, browse: Bool, generation current: Int) {
        let mirror = made.mirror
        let lookup = made.lookup
        tasks.append(Task { [weak self] in
            if let state = await mirror.state { await self?.trustChanged(state, lookup: lookup, generation: current) }
            for await state in await mirror.updates() {
                await self?.trustChanged(state, lookup: lookup, generation: current)
            }
        })
        tasks.append(Task { [weak self] in
            for await snapshot in monitor.snapshots() {
                guard let self, self.generation == current else { return }
                self.registry?.pathDidChange(snapshot)
            }
        })
        if let saved {
            tasks.append(Task { [weak self] in
                for await endpoints in saved {
                    guard let self, self.generation == current else { return }
                    self.book.saved = endpoints
                    self.applyRoutes()
                }
            })
        }
        if browse {
            let browser = DirectBrowser()
            self.browser = browser
            tasks.append(Task { [weak self] in
                for await hosts in browser.results() {
                    guard let self, self.generation == current else { return }
                    self.book.discovered = hosts
                    self.applyRoutes()
                }
            })
        }
    }

    private func trustChanged(_ state: TrustStoreState, lookup: any TrustedKeyLookup, generation current: Int) async {
        let keys = await MobileRouteBook.trustedHosts(in: state, lookup: lookup)
        guard generation == current else { return }
        book.trusted = keys
        trusted = Dictionary(keys.map { ($0.host, $0) }, uniquingKeysWith: { first, _ in first })
        applyRoutes()
    }

    private func applyRoutes() {
        registry?.update(routes: book.routes())
        for waiter in routeWaiters.values { waiter.yield() }
    }

    private func routeChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        routeWaiters[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.routeWaiters[id] = nil } }
        return stream
    }
}
