public import CmuxMobileSSH
import Foundation

/// The keys this device holds, as login credentials. `SSHKeyStore`
/// conforms; tests use a fake.
public protocol SSHKeyProviding: Sendable {
    func credential(for keyID: UUID) async throws -> SSHCredential
}

extension SSHKeyStore: SSHKeyProviding {
    public func credential(for keyID: UUID) async throws -> SSHCredential {
        .privateKey(try privateKey(for: keyID, context: nil))
    }
}
