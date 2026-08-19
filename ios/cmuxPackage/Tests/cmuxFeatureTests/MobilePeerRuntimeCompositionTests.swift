import CMUXMobileCore
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation
import Testing

@testable import cmuxFeature

// MARK: - In-memory persistence fakes

private actor InMemoryBlobStorage {
    var records: [String: Data] = [:]

    func read(_ account: String) -> Data? { records[account] }

    func write(_ data: Data, account: String) { records[account] = data }

    func delete(_ account: String) { records[account] = nil }

    func deleteAll() { records.removeAll() }
}

private struct InMemoryBlobStore: PeerSecureBlobStoring {
    let storage = InMemoryBlobStorage()

    func read(account: String) async -> PeerSecureReadResult {
        if let data = await storage.read(account) { return .found(data) }
        return .absent
    }

    func write(_ data: Data, account: String) async throws {
        await storage.write(data, account: account)
    }

    func delete(account: String) async throws {
        await storage.delete(account)
    }

    func deleteAll() async throws {
        await storage.deleteAll()
    }
}

private final class InMemoryInstallStateStore: PeerInstallStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

/// Counts broker HTTP requests and answers every one with 429 + Retry-After,
/// reproducing the recorded broker rate-limit storm input.
private final class RateLimitedBrokerTransport: PeerBrokerHTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let retryAfterSeconds: Int

    init(retryAfterSeconds: Int) {
        self.retryAfterSeconds = retryAfterSeconds
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private func noteRequest() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        noteRequest()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://broker.test")!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": String(retryAfterSeconds)]
        )!
        return (Data("{}".utf8), response)
    }
}

// MARK: - Fixture

@MainActor
private struct PeerCompositionFixture {
    let composition: MobilePeerRuntimeComposition
    let transport: RateLimitedBrokerTransport
    let diagnosticLog: DiagnosticLog

    static func make(retryAfterSeconds: Int = 600) -> PeerCompositionFixture {
        let httpTransport = RateLimitedBrokerTransport(
            retryAfterSeconds: retryAfterSeconds
        )
        let diagnosticLog = DiagnosticLog(buildStamp: "test", role: .iosClient)
        let composition = MobilePeerRuntimeComposition(
            brokerBaseURL: URL(string: "https://broker.test")!,
            identities: PeerIdentityRepository(
                secureStore: InMemoryBlobStore(),
                installState: InMemoryInstallStateStore()
            ),
            offlineGrants: PeerOfflineGrantCache(secureStore: InMemoryBlobStore()),
            appInstances: MobilePeerAppInstanceRegistry(
                store: InMemoryInstallStateStore()
            ),
            brokerClientFactory: { baseURL, _, clientNamespace, discoveryScope in
                try PeerTrustBrokerClient(
                    baseURL: baseURL,
                    tokenProvider: PeerBrokerTokenProvider(
                        capture: {
                            PeerBrokerCredentials(
                                accessToken: "access",
                                refreshToken: "refresh"
                            )
                        },
                        forceRefresh: {}
                    ),
                    clientNamespace: clientNamespace,
                    discoveryScope: discoveryScope,
                    transport: httpTransport
                )
            },
            deviceID: { "1f9b6c4a-0000-4000-8000-00000000abcd" },
            clientNamespace: "dev.cmux.ios.tests",
            tag: "default",
            now: { Date() },
            diagnosticLog: diagnosticLog
        )
        return PeerCompositionFixture(
            composition: composition,
            transport: httpTransport,
            diagnosticLog: diagnosticLog
        )
    }

    func peerTransportRequest() throws -> CmxByteTransportRequest {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32)
        )
        let route = try CmxAttachRoute(
            id: "iroh-test-route",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: []),
            priority: 0
        )
        return CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "2f9b6c4a-0000-4000-8000-00000000abcd",
            authorizationMode: .transportAdmission
        )
    }
}

// MARK: - Cooldown behavior (PeerBrokerCooldownLedger-driven)

@MainActor
@Suite("Mobile peer runtime composition broker cooldown", .serialized)
struct MobilePeerRuntimeCompositionCooldownTests {
    @Test
    func rateLimitedRegistrationFloorsAllFurtherBrokerTraffic() async throws {
        let fixture = PeerCompositionFixture.make()
        fixture.composition.setObservedAuthStateForTesting(accountID: "acct-1")

        await fixture.composition.prepareForConnection()
        let countAtFloor = fixture.transport.requestCount
        #expect(countAtFloor >= 1)
        #expect((await fixture.diagnosticLog.snapshot()).events.contains {
            $0.code == .endpointFailed
        })

        // External churn (every dial, discovery, preparation re-triggers a
        // reconcile) must not translate into broker traffic while the
        // account-scoped cooldown floor is active. This is the recorded
        // 40-hour retry-storm pathology.
        await fixture.composition.prepareForConnection()
        await fixture.composition.prepareForConnection()
        #expect(fixture.transport.requestCount == countAtFloor)
    }

    @Test
    func transportCreationSurfacesTheBrokerRetryFloor() async throws {
        let fixture = PeerCompositionFixture.make(retryAfterSeconds: 600)
        fixture.composition.setObservedAuthStateForTesting(accountID: "acct-2")
        await fixture.composition.prepareForConnection()
        let countAtFloor = fixture.transport.requestCount

        do {
            _ = try await fixture.composition.transport(
                for: try fixture.peerTransportRequest()
            )
            Issue.record("Expected transport creation to fail during cooldown")
        } catch {
            let retryAfter = (error as? any CmxRetryAfterProviding)?.retryAfterSeconds
            #expect((retryAfter ?? 0) > 0)
            // The floor came from the 600-second Retry-After, not the local
            // reconnect ladder's 1-30s window.
            #expect((retryAfter ?? 0) > 60)
        }
        #expect(fixture.transport.requestCount == countAtFloor)
    }

    @Test
    func signedOutCompositionFailsClosedWithoutBrokerTraffic() async throws {
        let fixture = PeerCompositionFixture.make()
        await fixture.composition.prepareForConnection()
        #expect(fixture.transport.requestCount == 0)
        do {
            _ = try await fixture.composition.transport(
                for: try fixture.peerTransportRequest()
            )
            Issue.record("Expected transport creation to fail while signed out")
        } catch {
            let kind = (error as? any DiagnosticFailureProviding)?.diagnosticFailureKind
            #expect(kind == .authorizationFailed)
        }
        #expect(fixture.transport.requestCount == 0)
    }
}

// MARK: - Transport verification mode

@MainActor
@Suite
struct MobilePeerTransportVerificationModeTests {
    @Test
    func iosCompositionResolvesTheReleasePathPreferenceAndDebugOverride() throws {
        let suiteName = "MobilePeerTransportVerificationModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            MobilePeerRuntimeComposition.initialTransportVerificationMode(
                defaults: defaults
            ) == .automatic
        )

        defaults.set(
            CmxIrohPathPreference.relayOnly.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        #expect(
            MobilePeerRuntimeComposition.initialTransportVerificationMode(
                defaults: defaults
            ) == .automatic
        )

        defaults.set(
            CmxIrohPathPreference.neverUseRelays.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        #expect(
            MobilePeerRuntimeComposition.initialTransportVerificationMode(
                defaults: defaults
            ) == .directOnly
        )

        #if DEBUG
        defaults.set(
            CmxIrohTransportVerificationMode.directOnly.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        #expect(
            MobilePeerRuntimeComposition.initialTransportVerificationMode(
                defaults: defaults
            ) == .directOnly
        )
        #endif
    }

    @Test
    func relayConfigsFollowThePolicyConstraint() {
        let credential = PeerBrokerRelayTokenResponse(credentials: [
            PeerBrokerRelayCredential(
                relayURL: "https://relay-a.example/",
                token: "token-a",
                expiresAt: "2030-01-01T00:00:00Z",
                refreshAfter: "2029-01-01T00:00:00Z"
            ),
            PeerBrokerRelayCredential(
                relayURL: "https://relay-b.example/",
                token: "token-b",
                expiresAt: "2030-01-01T00:00:00Z",
                refreshAfter: "2029-01-01T00:00:00Z"
            ),
        ])

        let unconstrained = MobilePeerEndpointActivator.relayConfigs(
            from: credential,
            allowedRelayURLs: nil
        )
        #expect(unconstrained.map(\.url) == [
            "https://relay-a.example/",
            "https://relay-b.example/",
        ])
        #expect(unconstrained.map(\.authToken) == ["token-a", "token-b"])

        let constrained = MobilePeerEndpointActivator.relayConfigs(
            from: credential,
            allowedRelayURLs: ["https://relay-b.example/"]
        )
        #expect(constrained.map(\.url) == ["https://relay-b.example/"])
    }
}

// MARK: - Terminal output envelope wire compatibility

@Suite
struct MobilePeerTerminalOutputEnvelopeTests {
    @Test
    func roundTripsChunkedFrames() throws {
        let codec = MobilePeerTerminalOutputEnvelopeCodec()
        let first = try MobilePeerTerminalOutputEnvelope(
            kind: .replay,
            retainedBaseSequence: 5,
            sequence: 5,
            currentSequence: 10,
            payload: Data("hello".utf8)
        )
        let second = try MobilePeerTerminalOutputEnvelope(
            kind: .chunk,
            retainedBaseSequence: 5,
            sequence: 10,
            currentSequence: 12,
            payload: Data("ok".utf8)
        )
        var wire = codec.encode(first)
        wire.append(codec.encode(second))

        var decoder = MobilePeerTerminalOutputEnvelopeDecoder()
        var decoded: [MobilePeerTerminalOutputEnvelope] = []
        // Feed byte-by-byte to prove QUIC receive chunking cannot split frames.
        for byte in wire {
            decoded.append(contentsOf: try decoder.append(Data([byte])))
        }
        #expect(decoded == [first, second])
        #expect(!decoder.hasBufferedBytes)
    }

    @Test
    func rejectsForeignMagic() {
        var decoder = MobilePeerTerminalOutputEnvelopeDecoder()
        let junk = Data(repeating: 0x41, count: 64)
        #expect(throws: (any Error).self) {
            _ = try decoder.append(junk)
        }
    }
}
