import CNBackend
import Foundation
import Security
import Synchronization

/// Keychain token store that keeps working when the keychain is unavailable
/// to the process (unsigned simulator builds get errSecMissingEntitlement):
/// the session then lives in memory for this launch instead of failing
/// sign-in.
final class SessionTokenStore: TokenStore {
    private let keychain = KeychainTokenStore()
    private let memory = Mutex<StoredSession?>(nil)

    func load() -> StoredSession? {
        memory.withLock { $0 } ?? keychain.load()
    }

    func save(_ session: StoredSession) throws {
        memory.withLock { $0 = session }
        do {
            try keychain.save(session)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            // Memory only for this launch.
        }
    }

    func clear() {
        memory.withLock { $0 = nil }
        keychain.clear()
    }
}
