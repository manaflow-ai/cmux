internal import Foundation
import CmuxLiteProtocol
import CmuxLiteTransport
import Testing

@Suite("Transport dialer")
struct TransportDialerTests {
    @Test("automatic mode falls back in deterministic preference order")
    func automaticFallback() async throws {
        let iroh = try TransportRoute(kind: .iroh, identifier: "iroh-1")
        let tailscale = try TransportRoute(
            kind: .tailscale,
            identifier: "tailscale-1"
        )
        let policy = try TransportSelectionPolicy()
        let irohConnector = ScriptedConnector(behavior: .fail)
        let tailscaleConnector = ScriptedConnector(behavior: .succeed)
        let dialer = try TransportDialer(
            routes: [tailscale, iroh],
            policy: policy,
            connectors: [
                .iroh: irohConnector,
                .tailscale: tailscaleConnector,
            ]
        )
        var events = dialer.events.makeAsyncIterator()

        _ = try await dialer.connect()

        #expect(await events.next() == .attempting(iroh))
        #expect(
            await events.next() == .failed(iroh, reason: .unavailable)
        )
        #expect(await events.next() == .attempting(tailscale))
        #expect(await events.next() == .connected(tailscale))
        #expect(await dialer.currentRoute() == tailscale)
        #expect(await irohConnector.attemptCount() == 1)
        #expect(await tailscaleConnector.attemptCount() == 1)
    }

    @Test("restricted mode never tries another route family")
    func restrictedMode() async throws {
        let iroh = try TransportRoute(kind: .iroh, identifier: "iroh-1")
        let tailscale = try TransportRoute(
            kind: .tailscale,
            identifier: "tailscale-1"
        )
        let policy = try TransportSelectionPolicy(mode: .restricted(.tailscale))
        let irohConnector = ScriptedConnector(behavior: .succeed)
        let tailscaleConnector = ScriptedConnector(behavior: .fail)
        let dialer = try TransportDialer(
            routes: [iroh, tailscale],
            policy: policy,
            connectors: [.iroh: irohConnector, .tailscale: tailscaleConnector]
        )
        var events = dialer.events.makeAsyncIterator()

        await #expect(
            throws: TransportDialer.Failure.allRoutesFailed([tailscale])
        ) {
            try await dialer.connect()
        }

        #expect(await events.next() == .attempting(tailscale))
        #expect(
            await events.next() == .failed(tailscale, reason: .unavailable)
        )
        #expect(await events.next() == .exhausted)
        #expect(await irohConnector.attemptCount() == 0)
        #expect(await tailscaleConnector.attemptCount() == 1)
    }

    @Test("concurrent callers join one in-flight route attempt")
    func concurrentCallsJoin() async throws {
        let route = try TransportRoute(kind: .iroh, identifier: "iroh-1")
        let connector = GatedConnector()
        let policy = try TransportSelectionPolicy()
        let dialer = try TransportDialer(
            routes: [route],
            policy: policy,
            connectors: [.iroh: connector]
        )

        let first = Task { try await dialer.connect() }
        await connector.waitUntilOpenIsPending()
        let second = Task { try await dialer.connect() }
        await Task.yield()
        await connector.release()

        _ = try await first.value
        _ = try await second.value
        #expect(await connector.attemptCount() == 1)
        #expect(await dialer.currentRoute() == route)
    }

    @Test("missing connectors are observable and exhaust without a hidden fallback")
    func missingConnector() async throws {
        let route = try TransportRoute(kind: .tailscale, identifier: "ts-1")
        let policy = try TransportSelectionPolicy(mode: .restricted(.tailscale))
        let dialer = try TransportDialer(
            routes: [route],
            policy: policy,
            connectors: [:]
        )
        var events = dialer.events.makeAsyncIterator()

        await #expect(
            throws: TransportDialer.Failure.allRoutesFailed([route])
        ) {
            try await dialer.connect()
        }
        #expect(await events.next() == .attempting(route))
        #expect(
            await events.next() == .failed(route, reason: .unclassified)
        )
        #expect(await events.next() == .exhausted)
    }

    @Test("authorization denial stops automatic fallback")
    func authorizationDenialStopsFallback() async throws {
        let iroh = try TransportRoute(kind: .iroh, identifier: "iroh-1")
        let tailscale = try TransportRoute(
            kind: .tailscale,
            identifier: "tailscale-1"
        )
        let policy = try TransportSelectionPolicy()
        let irohConnector = ScriptedConnector(behavior: .unauthorized)
        let tailscaleConnector = ScriptedConnector(behavior: .succeed)
        let dialer = try TransportDialer(
            routes: [iroh, tailscale],
            policy: policy,
            connectors: [.iroh: irohConnector, .tailscale: tailscaleConnector]
        )
        var events = dialer.events.makeAsyncIterator()

        await #expect(
            throws: TransportDialer.Failure.nonRetryable(
                iroh,
                reason: .unauthorized
            )
        ) {
            try await dialer.connect()
        }
        #expect(
            await events.next() == .attempting(iroh)
        )
        #expect(
            await events.next() == .failed(iroh, reason: .unauthorized)
        )
        #expect(await tailscaleConnector.attemptCount() == 0)
    }

    @Test("invalid route and policy inputs fail before any connector runs")
    func invalidInputs() async throws {
        #expect(
            throws: TransportRoute.Failure.emptyIdentifier
        ) {
            try TransportRoute(kind: .iroh, identifier: "")
        }
        #expect(
            throws: TransportSelectionPolicy.Failure.invalidPreference
        ) {
            try TransportSelectionPolicy(preference: [.iroh, .iroh])
        }
        #expect(
            throws: TransportDialer.Failure.noRoutes
        ) {
            try TransportDialer(
                routes: [],
                policy: try TransportSelectionPolicy(),
                connectors: [:]
            )
        }
    }
}

private enum ScriptedBehavior: Sendable {
    case fail
    case succeed
    case unauthorized
}

private actor ScriptedConnector: TransportConnector {
    private let behavior: ScriptedBehavior
    private var attempts = 0

    init(behavior: ScriptedBehavior) {
        self.behavior = behavior
    }

    func open(route: TransportRoute) async throws -> any ByteStream {
        attempts += 1
        switch behavior {
        case .fail:
            throw TransportOpenFailure.unavailable
        case .succeed:
            return TestByteStream()
        case .unauthorized:
            throw TransportOpenFailure.unauthorized
        }
    }

    func attemptCount() -> Int {
        attempts
    }
}

private actor GatedConnector: TransportConnector {
    private var attempts = 0
    private var pending: CheckedContinuation<any ByteStream, any Error>?
    private var pendingObserver: CheckedContinuation<Void, Never>?

    func open(route: TransportRoute) async throws -> any ByteStream {
        attempts += 1
        pendingObserver?.resume()
        pendingObserver = nil
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }

    func waitUntilOpenIsPending() async {
        if pending != nil {
            return
        }
        await withCheckedContinuation { continuation in
            pendingObserver = continuation
        }
    }

    func release() {
        pending?.resume(returning: TestByteStream())
        pending = nil
    }

    func attemptCount() -> Int {
        attempts
    }
}

private actor TestByteStream: ByteStream {
    func connect() async throws {}

    func send(_ bytes: Data) async throws {}

    func receive() async throws -> Data? {
        nil
    }

    func close() async {}
}
