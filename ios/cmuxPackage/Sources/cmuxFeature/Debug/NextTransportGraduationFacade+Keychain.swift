#if DEBUG
import CmuxNextTransport
import Foundation

extension NextTransportGraduationFacade {
    var bootstrapKeychain: NextTransportBootstrapKeychain {
        NextTransportBootstrapKeychain(service: Self.bootstrapKeychainService, logger: Self.logger)
    }

    /// Enqueues deletion after older writes so invalidation cannot resurrect a bootstrap.
    func deleteBootstrap(macID: String) {
        let keychain = bootstrapKeychain
        let defaults = NextTransportDefaultsBox(defaults)
        let prefix = Self.bootstrapKeyPrefix
        credentialPersistence.enqueue(key: macID) {
            await keychain.remove(macID: macID, defaults: defaults, keyPrefix: prefix)
        }
    }
}
#endif
