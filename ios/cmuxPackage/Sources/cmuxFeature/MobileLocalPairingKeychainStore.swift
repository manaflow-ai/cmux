import CmuxIrohTransport
import CmuxMobileShellUI
import Foundation

/// Keychain adapter for one device-local pairing URL.
actor MobileLocalPairingKeychainStore: MobileLocalPairingCredentialStoring {
    private static let account = "last-successful-local-pairing"
    private let keychain: CmxIrohKeychainCredentialStore

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        accessGroup: String?
    ) {
        let normalized = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace: String
        if let normalized, !normalized.isEmpty {
            namespace = normalized
        } else {
            namespace = "com.cmux.app"
        }
        keychain = CmxIrohKeychainCredentialStore(
            service: "\(namespace).mobile-local-pairing.v1",
            accessGroup: accessGroup
        )
    }

    func loadAttachURL() async -> String? {
        guard let data = try? await keychain.read(account: Self.account),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func saveAttachURL(_ attachURL: String) async {
        guard let data = attachURL.data(using: .utf8) else { return }
        try? await keychain.write(
            data,
            account: Self.account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    func clearAttachURL() async {
        try? await keychain.delete(account: Self.account)
    }
}
