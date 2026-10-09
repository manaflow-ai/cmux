import CmuxiOSSSHCore
import CmuxMobileSSH
import CryptoKit
import Foundation
import Observation

/// The keys screen: list, generate, delete. Private keys never leave the
/// Keychain or the Secure Enclave; only public key lines reach the UI.
@MainActor
@Observable
final class SSHKeysModel {
    private(set) var keys: [SSHKeyRecord] = []
    private(set) var isWorking = false
    var message: String?
    var showingGenerate = false
    var newLabel = ""
    var newKind: SSHKeyKindChoice = .ed25519
    var requireBiometry = false
    var pendingDelete: SSHKeyRecord?
    private(set) var pendingDeleteUsers = 0

    let device: SSHDeviceState

    init(device: SSHDeviceState) {
        self.device = device
    }

    var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    func load() async {
        keys = await device.keys.all()
    }

    func beginGenerate() {
        newLabel = SSHText.defaultKeyName
        newKind = .ed25519
        requireBiometry = false
        showingGenerate = true
    }

    func generate() async {
        let label = newLabel.trimmingCharacters(in: .whitespaces).isEmpty ? SSHText.defaultKeyName : newLabel
        isWorking = true
        defer { isWorking = false }
        do {
            switch newKind {
            case .ed25519:
                _ = try await device.keys.generateEd25519Key(label: label)
            case .secureEnclave:
                _ = try await device.keys.generateSecureEnclaveKey(label: label, requiresBiometry: requireBiometry)
            }
            showingGenerate = false
            await load()
        } catch SSHKeyStoreError.secureEnclaveUnavailable {
            message = SSHText.enclaveUnavailable
        } catch {
            message = SSHText.genericError
        }
    }

    func askDelete(_ key: SSHKeyRecord) async {
        pendingDeleteUsers = await device.settings.hosts(using: key.id).count
        pendingDelete = key
    }

    func confirmDelete() async {
        guard let key = pendingDelete else { return }
        pendingDelete = nil
        do {
            try await device.keys.delete(id: key.id)
        } catch {
            message = SSHText.genericError
        }
        await load()
    }

    static func kindLabel(_ kind: SSHKeyRecord.Kind) -> String {
        switch kind {
        case .secureEnclave: SSHText.kindSecureEnclave
        case .imported: SSHText.kindImported
        case .generatedEd25519: SSHText.kindGenerated
        }
    }
}
