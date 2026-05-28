import SwiftUI
import CmuxKit

struct HostAddView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var hostStore: HostStore

    @State private var label: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: CmuxHost.AuthMethodKind
    @State private var passwordOrKey: String
    @State private var cmuxBinaryPath: String
    @State private var error: String?
    @State private var existingID: UUID?
    @State private var existingPin: String?
    private let originalAuthMethod: CmuxHost.AuthMethodKind?

    init(host: CmuxHost? = nil) {
        originalAuthMethod = host?.authMethod
        _existingID = State(initialValue: host?.id)
        _existingPin = State(initialValue: host?.serverFingerprintPin)
        _label = State(initialValue: host?.label ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? 22))
        _username = State(initialValue: host?.username ?? "")
        _authMethod = State(initialValue: host?.authMethod ?? .ed25519Key)
        _passwordOrKey = State(initialValue: "")
        _cmuxBinaryPath = State(initialValue: host?.cmuxBinaryPath ?? "cmux")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string("host.edit.section.host", defaultValue: "Host")) {
                    TextField(L10n.string("host.edit.label.placeholder", defaultValue: "Label"), text: $label)
                    TextField(L10n.string("host.edit.hostname.placeholder", defaultValue: "Hostname or IP"), text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.string("host.edit.port.placeholder", defaultValue: "Port"), text: $port)
                        .keyboardType(.numberPad)
                    TextField(L10n.string("host.edit.username.placeholder", defaultValue: "Username"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section(L10n.string("host.edit.section.authentication", defaultValue: "Authentication")) {
                    Picker(L10n.string("host.edit.auth.method", defaultValue: "Method"), selection: $authMethod) {
                        Text(L10n.string("host.edit.auth.ed25519", defaultValue: "ed25519 key")).tag(CmuxHost.AuthMethodKind.ed25519Key)
                        Text(L10n.string("host.edit.auth.ecdsa_p256", defaultValue: "ECDSA P-256 key")).tag(CmuxHost.AuthMethodKind.ecdsaP256Key)
                        Text(L10n.string("host.edit.auth.password", defaultValue: "Password")).tag(CmuxHost.AuthMethodKind.password)
                    }
                    SecureField(
                        authMethod == .password
                            ? L10n.string("host.edit.password.placeholder", defaultValue: "Password")
                            : L10n.string("host.edit.private_key.placeholder", defaultValue: "Private key (base64 raw)"),
                        text: $passwordOrKey
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section(L10n.string("host.edit.section.advanced", defaultValue: "Advanced")) {
                    TextField(L10n.string("host.edit.cmux_path.placeholder", defaultValue: "cmux binary path"), text: $cmuxBinaryPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let pin = existingPin {
                    Section(L10n.string("host.edit.section.host_key_pin", defaultValue: "Host key pin")) {
                        Text(pin)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button(role: .destructive) {
                            existingPin = nil
                        } label: {
                            Label(
                                L10n.string("host.edit.clear_pin", defaultValue: "Clear pin (will prompt next connect)"),
                                systemImage: "exclamationmark.shield"
                            )
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existingID == nil
                ? L10n.string("host.edit.title.add", defaultValue: "Add Mac")
                : L10n.string("host.edit.title.edit", defaultValue: "Edit Mac")
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.string("common.save", defaultValue: "Save")) { Task { await save() } }
                        .disabled(label.isEmpty || hostname.isEmpty || username.isEmpty)
                }
            }
        }
    }

    private func save() async {
        guard let portInt = Int(port), (1...65535).contains(portInt) else {
            error = L10n.string("host.edit.error.invalid_port", defaultValue: "Port must be 1-65535")
            return
        }
        let id = existingID ?? UUID()
        let host = CmuxHost(
            id: id,
            label: label,
            hostname: hostname,
            port: portInt,
            username: username,
            authMethod: authMethod,
            // PRESERVE the existing TOFU pin across edits. Wiping it on
            // every save (regression caught in adversarial review) drops
            // the host back to TOFU and silently re-pins to whatever the
            // network returns next — a serious MITM hazard.
            serverFingerprintPin: existingPin,
            cmuxBinaryPath: cmuxBinaryPath
        )
        do {
            let isEditingExistingHost = existingID != nil
            let authMethodChanged = originalAuthMethod != nil && originalAuthMethod != authMethod
            let shouldStoreCredential = !isEditingExistingHost || authMethodChanged || !passwordOrKey.isEmpty
            if shouldStoreCredential {
                switch authMethod {
                case .password:
                    guard !passwordOrKey.isEmpty else {
                        error = L10n.string(
                            "host.edit.error.credential_required",
                            defaultValue: "Enter a credential to save this authentication method."
                        )
                        return
                    }
                    try await CmuxCredentialStore.shared.storePassword(passwordOrKey, hostID: id)
                case .ed25519Key:
                    guard !passwordOrKey.isEmpty else {
                        error = L10n.string(
                            "host.edit.error.credential_required",
                            defaultValue: "Enter a credential to save this authentication method."
                        )
                        return
                    }
                    guard let data = Data(base64Encoded: passwordOrKey) else {
                        error = L10n.string(
                            "host.edit.error.invalid_ed25519",
                            defaultValue: "Could not decode private key (expected base64-encoded 32-byte ed25519 seed)"
                        )
                        return
                    }
                    try await CmuxCredentialStore.shared.storeEd25519PrivateKey(data, hostID: id)
                case .ecdsaP256Key:
                    guard !passwordOrKey.isEmpty else {
                        error = L10n.string(
                            "host.edit.error.credential_required",
                            defaultValue: "Enter a credential to save this authentication method."
                        )
                        return
                    }
                    guard let data = Data(base64Encoded: passwordOrKey) else {
                        error = L10n.string(
                            "host.edit.error.invalid_p256",
                            defaultValue: "Could not decode private key (expected base64-encoded P-256 raw private bytes)"
                        )
                        return
                    }
                    try await CmuxCredentialStore.shared.storeP256PrivateKey(data, hostID: id)
                case .rsaKey:
                    error = L10n.string("host.edit.error.rsa_unsupported", defaultValue: "RSA keys are not supported")
                    return
                }
                if authMethodChanged, let originalAuthMethod {
                    await CmuxCredentialStore.shared.deleteCredential(hostID: id, method: originalAuthMethod)
                }
            }
            hostStore.addOrUpdate(host)
            hostStore.setActive(host.id)
            dismiss()
        } catch {
            self.error = L10n.string(
                "host.edit.error.save_failed",
                defaultValue: "Could not save this host. Check the settings and try again."
            )
        }
    }
}
