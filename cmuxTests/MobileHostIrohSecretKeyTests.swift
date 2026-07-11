import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mobile host iroh secret key", .serialized)
@MainActor
struct MobileHostIrohSecretKeyTests {
    private let keyLength = 32

    @Test func providerPersistsGeneratedKeyAndReusesIt() throws {
        let store = InMemorySecretKeyStore()
        let counter = LockedCounter()
        let generated = Data((0..<keyLength).map { UInt8($0) })
        let provider = MobileHostIrohSecretKeyProvider(
            store: store,
            generate: {
                counter.increment()
                return generated
            }
        )

        let first = try provider.secretKey()
        let second = try provider.secretKey()

        #expect(first == generated)
        #expect(second == generated)
        #expect(counter.value == 1)
        #expect(store.savedKey == generated)
    }

    @Test func providerRejectsInvalidStoredLength() throws {
        let store = InMemorySecretKeyStore(initialKey: Data([1, 2, 3]))
        let provider = MobileHostIrohSecretKeyProvider(
            store: store,
            generate: {
                Issue.record("generate should not run when an invalid stored key exists")
                return Data(repeating: 0, count: keyLength)
            }
        )

        #expect(throws: MobileHostIrohSecretKeyStoreError.invalidLength(3)) {
            try provider.secretKey()
        }
    }

    @Test func hostStartPublishesTCPRoutesWhileSecretKeyLoadHangs() async throws {
        let store = HangingSecretKeyStore()
        let service = MobileHostService(
            irohFFIClient: UnusedMobileHostIrohFFIClient(),
            irohSecretKeyProvider: MobileHostIrohSecretKeyProvider(
                store: store,
                generate: { Data(repeating: 7, count: 32) }
            ),
            isListeningEnabled: { true }
        )
        defer {
            store.unblock()
            service.stop()
        }

        service.start()
        #expect(store.waitUntilLoadStarts())
        let status = await service.ensureListeningAndReady()

        #expect(status.isRunning)
        #expect(status.port != nil)
        #expect(status.routes.contains { $0.kind != .iroh })
        #expect(!status.routes.contains { $0.kind == .iroh })
        #expect(status.irohLaneState == .starting)
    }

    @Test func hostDegradesToTCPRoutesWhenSecretKeyLoadFails() async {
        let service = MobileHostService(
            irohFFIClient: UnusedMobileHostIrohFFIClient(),
            irohSecretKeyProvider: MobileHostIrohSecretKeyProvider(
                store: FailingSecretKeyStore(),
                generate: { Data(repeating: 8, count: 32) }
            ),
            isListeningEnabled: { true }
        )
        defer { service.stop() }

        service.start()
        await service.debugWaitForIrohStartupForTesting()
        let status = await service.ensureListeningAndReady()

        #expect(status.isRunning)
        #expect(status.routes.contains { $0.kind != .iroh })
        #expect(!status.routes.contains { $0.kind == .iroh })
        #expect(status.irohLaneState == .unavailableKeychain)
        #expect(status.payload["iroh_lane_state"] as? String == "unavailable_keychain")
    }
}

private enum ExpectedSecretKeyFailure: Error {
    case failed
}

private struct FailingSecretKeyStore: MobileHostIrohSecretKeyStoring {
    func loadSecretKey() throws -> Data? {
        throw ExpectedSecretKeyFailure.failed
    }

    func saveSecretKey(_ key: Data) throws {
        Issue.record("save should not run after a failed key load")
    }
}

private final class HangingSecretKeyStore: MobileHostIrohSecretKeyStoring, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    func loadSecretKey() throws -> Data? {
        started.signal()
        gate.wait()
        return Data(repeating: 1, count: 32)
    }

    func saveSecretKey(_ key: Data) throws {
        Issue.record("save should not run when a stored key exists")
    }

    func waitUntilLoadStarts() -> Bool {
        started.wait(timeout: .now() + 2) == .success
    }

    func unblock() {
        gate.signal()
    }
}

private struct UnusedMobileHostIrohFFIClient: MobileHostIrohFFIClient {
    func generateSecretKey() throws -> Data { Data(repeating: 2, count: 32) }

    func bindEndpoint(
        secretKey: Data,
        enableRelay: Bool,
        acceptConnections: Bool
    ) throws -> MobileHostIrohEndpointReference {
        Issue.record("bind should not run while the key load is blocked or failed")
        throw ExpectedSecretKeyFailure.failed
    }

    func endpointID(_ endpoint: MobileHostIrohEndpointReference) -> String? { nil }
    func routeJSON(_ endpoint: MobileHostIrohEndpointReference) -> String? { nil }

    func accept(
        endpoint: MobileHostIrohEndpointReference,
        timeoutMilliseconds: UInt64
    ) throws -> MobileHostIrohConnectionReference {
        throw ExpectedSecretKeyFailure.failed
    }

    func receive(connection: MobileHostIrohConnectionReference, maximumLength: Int) throws -> Data? { nil }
    func send(connection: MobileHostIrohConnectionReference, data: Data) throws {}
    func close(connection: MobileHostIrohConnectionReference) {}
    func close(endpoint: MobileHostIrohEndpointReference) {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class InMemorySecretKeyStore: MobileHostIrohSecretKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    init(initialKey: Data? = nil) {
        key = initialKey
    }

    var savedKey: Data? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func loadSecretKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func saveSecretKey(_ key: Data) throws {
        lock.lock()
        self.key = key
        lock.unlock()
    }
}
