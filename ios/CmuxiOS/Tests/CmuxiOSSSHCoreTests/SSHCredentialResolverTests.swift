import CmuxiOSFeatureKit
import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation
import Testing

actor MemoryVault: SSHSecretVault {
    var passwords: [HostID: String] = [:]
    func password(for host: HostID) -> String? { passwords[host] }
    func setPassword(_ password: String, for host: HostID) { passwords[host] = password }
    func removePassword(for host: HostID) { passwords[host] = nil }
}

struct NoKeys: SSHKeyProviding {
    func credential(for keyID: UUID) async throws -> SSHCredential { throw SSHSessionFailure.missingCredentials }
}

@Suite struct SSHCredentialResolverTests {
    @Test func passwordAndMissingCredentials() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = SSHHostSettingsStore(url: url)
        let vault = MemoryVault()
        let resolver = SSHCredentialResolver(settings: settings, keys: NoKeys(), vault: vault)
        let host = HostID("h")
        await #expect(throws: SSHSessionFailure.missingCredentials) { try await resolver.credentials(for: host) }
        try await settings.set(SSHHostSettings(auth: .password), for: host)
        await #expect(throws: SSHSessionFailure.missingCredentials) { try await resolver.credentials(for: host) }
        await vault.setPassword("hunter2", for: host)
        let credentials = try await resolver.credentials(for: host)
        guard case .password(let password)? = credentials.first else { Issue.record("no password"); return }
        #expect(password == "hunter2")
        let keyID = UUID()
        try await settings.set(SSHHostSettings(auth: .key(keyID)), for: host)
        await #expect(throws: SSHSessionFailure.missingCredentials) { try await resolver.credentials(for: host) }
        #expect(await SSHHostSettingsStore(url: url).hosts(using: keyID) == [host])
    }
}
