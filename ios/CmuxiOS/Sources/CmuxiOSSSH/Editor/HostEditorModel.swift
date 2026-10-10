import CmuxiOSFeatureKit
import CmuxiOSSSHCore
import CmuxMobileSSH
import Foundation
import Observation

/// The host editor's state: the synced record's fields plus this device's
/// login (key or Keychain password). Saving commits the record through the
/// `HostsStore` first, then the device settings, so a refused record leaves
/// device state untouched.
@MainActor
@Observable
final class HostEditorModel {
    enum Mode: Hashable {
        /// Adding with this intent key (it also names the new host).
        case add(IntentKey)
        case edit(HostID)
    }

    let mode: Mode
    var name = ""
    var address = ""
    var port = ""
    var user = ""
    var method: HostEditorAuthMethod = .key
    var keyID: UUID?
    var password = ""
    var hasSavedPassword = false
    var jumpHost: HostID?
    var installPassword = ""
    private(set) var keys: [SSHKeyRecord] = []
    private(set) var jumpCandidates: [HostRecord] = []
    private(set) var isWorking = false
    var message: String?
    var dismiss: (() -> Void)?

    private let records: [HostRecord]
    private let feature: SSHFeature

    init(mode: Mode, records: [HostRecord], feature: SSHFeature) {
        self.mode = mode
        self.records = records
        self.feature = feature
        if case .edit(let id) = mode, let record = records.first(where: { $0.id == id }) {
            name = record.name
            switch record.kind {
            case .ssh(let endpoint, let jump):
                fill(endpoint)
                jumpHost = jump
            case .direct(let endpoint, _):
                fill(endpoint)
            case .pairedMac:
                break
            }
        }
        jumpCandidates = records.filter { candidate in
            guard case .ssh = candidate.kind, candidate.id != hostID else { return false }
            return !Self.routes(through: hostID, from: candidate.id, records: records)
        }
    }

    var hostID: HostID {
        switch mode {
        case .add(let key): .added(by: key)
        case .edit(let id): id
        }
    }

    var isNew: Bool {
        if case .add = mode { return true }
        return false
    }

    var canSave: Bool {
        !isWorking && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var selectedKey: SSHKeyRecord? { keys.first { $0.id == keyID } }

    /// Install needs a direct host with a key picked.
    var canInstall: Bool { method == .key && keyID != nil && jumpHost == nil && !installPassword.isEmpty && !isWorking }

    func load() async {
        keys = await feature.device.keys.all()
        guard !isNew else {
            keyID = keys.last?.id
            return
        }
        switch await feature.device.settings.settings(for: hostID).auth {
        case .key(let id):
            method = .key
            keyID = id
        case .password:
            method = .password
        case .unset:
            keyID = keys.last?.id
        }
        hasSavedPassword = ((try? await feature.device.vault.password(for: hostID)) ?? nil) != nil
    }

    func generateKey() async {
        await work {
            let record = try await self.feature.device.keys.generateEd25519Key(label: self.keyLabel)
            self.keys.append(record)
            self.keyID = record.id
            self.method = .key
        }
    }

    func save() async -> Bool {
        guard let draft = makeDraft() else { return false }
        var didSave = false
        await work {
            let receipt: IntentReceipt
            switch self.mode {
            case .add(let key): receipt = try await self.feature.hosts.add(draft, key: key)
            case .edit(let id): receipt = try await self.feature.hosts.update(id, with: draft, key: IntentKey())
            }
            if case .refused(_, let reason) = receipt {
                self.message = SSHText.refusal(reason)
                return
            }
            try await self.saveLogin()
            didSave = true
        }
        return didSave
    }

    /// Appends the selected key to the server's authorized_keys with a
    /// one-time password login, then proves a key-only login works.
    func installKey() async {
        guard let key = selectedKey, let draft = makeDraft(), case .ssh(let endpoint, _) = draft.kind,
              let user = endpoint.user else { return }
        let password = installPassword
        await work {
            let credential = try await self.feature.device.keys.credential(for: key.id)
            let target = SSHEndpoint(host: endpoint.address, port: Int(endpoint.port ?? 22), username: user)
            let verifier = TOFUHostKeyVerifier(knownHosts: self.feature.device.knownHosts, prompter: self.feature.prompter,
                                               names: [target.hostKeyIdentity: draft.name])
            _ = try await SSHKeyInstaller().install(publicKeyLine: key.publicKeyLine, endpoint: target, password: password,
                                                    verifyWith: credential, hostKeyVerifier: verifier)
            self.installPassword = ""
            self.message = SSHText.installed
        }
    }

    // MARK: - Private

    private var keyLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? SSHText.defaultKeyName : trimmed
    }

    private func fill(_ endpoint: HostEndpoint) {
        address = endpoint.address
        port = endpoint.port.map(String.init) ?? ""
        user = endpoint.user ?? ""
    }

    private func makeDraft() -> HostDraft? {
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        var parsedPort: UInt16?
        if !trimmedPort.isEmpty {
            guard let value = UInt16(trimmedPort), value > 0 else {
                message = SSHText.portInvalid
                return nil
            }
            parsedPort = value
        }
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty else {
            message = SSHText.userRequired
            return nil
        }
        let endpoint = HostEndpoint(address: address.trimmingCharacters(in: .whitespaces), port: parsedPort, user: trimmedUser)
        return HostDraft(name: name, kind: .ssh(endpoint: endpoint, jumpHost: jumpHost))
    }

    private func saveLogin() async throws {
        let device = feature.device
        switch method {
        case .key:
            try await device.settings.set(SSHHostSettings(auth: keyID.map(SSHHostAuth.key) ?? .unset), for: hostID)
            try await device.vault.removePassword(for: hostID)
        case .password:
            if !password.isEmpty {
                try await device.vault.setPassword(password, for: hostID)
            } else if !hasSavedPassword {
                try await device.settings.set(SSHHostSettings(auth: .unset), for: hostID)
                return
            }
            try await device.settings.set(SSHHostSettings(auth: .password), for: hostID)
        }
    }

    private func work(_ body: @MainActor () async throws -> Void) async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await body()
        } catch let failure as SSHSessionFailure {
            message = SSHText.failure(failure)
        } catch is FeatureSourceError {
            message = SSHText.offline
        } catch let error as SSHConnectionError {
            message = SSHText.failure(SSHSessionFailure(error))
        } catch {
            message = SSHText.genericError
        }
    }

    /// Whether `candidate`'s jump chain passes through `host` (picking it
    /// would loop).
    private static func routes(through host: HostID, from candidate: HostID, records: [HostRecord]) -> Bool {
        var seen = Set<HostID>()
        var cursor: HostID? = candidate
        while let id = cursor, seen.insert(id).inserted {
            guard let record = records.first(where: { $0.id == id }), case .ssh(_, let jump) = record.kind else { return false }
            if jump == host { return true }
            cursor = jump
        }
        return false
    }
}
