import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mobile host iroh secret key")
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
