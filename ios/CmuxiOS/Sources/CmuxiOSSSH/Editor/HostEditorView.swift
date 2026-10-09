import CmuxiOSFeatureKit
import SwiftUI

/// The add/edit form for an SSH host (low frequency, so SwiftUI).
struct HostEditorView: View {
    @Bindable var model: HostEditorModel

    var body: some View {
        Form {
            Section(SSHText.server) {
                LabeledContent(SSHText.name) {
                    TextField(SSHText.name, text: $model.name, prompt: Text(verbatim: "devbox"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("ssh.editor.name")
                }
                LabeledContent(SSHText.address) {
                    TextField(SSHText.address, text: $model.address, prompt: Text(SSHText.addressPrompt))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ssh.editor.address")
                }
                LabeledContent(SSHText.port) {
                    TextField(SSHText.port, text: $model.port, prompt: Text(verbatim: "22"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("ssh.editor.port")
                }
                LabeledContent(SSHText.user) {
                    TextField(SSHText.user, text: $model.user, prompt: Text(verbatim: "root"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ssh.editor.user")
                }
            }

            Section {
                Picker(SSHText.method, selection: $model.method) {
                    Text(SSHText.methodKey).tag(HostEditorAuthMethod.key)
                    Text(SSHText.methodPassword).tag(HostEditorAuthMethod.password)
                }
                .pickerStyle(.segmented)
                switch model.method {
                case .key:
                    Picker(SSHText.key, selection: $model.keyID) {
                        Text(SSHText.noKey).tag(UUID?.none)
                        ForEach(model.keys) { key in
                            Text(key.label).tag(UUID?.some(key.id))
                        }
                    }
                    Button(SSHText.generateKey) { Task { await model.generateKey() } }
                        .disabled(model.isWorking)
                    if let key = model.selectedKey {
                        Text(key.fingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        PublicKeyActions(publicKeyLine: key.publicKeyLine)
                    }
                case .password:
                    SecureField(model.hasSavedPassword ? SSHText.passwordSaved : SSHText.password, text: $model.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("ssh.editor.password")
                }
            } header: {
                Text(SSHText.authentication)
            } footer: {
                Text(model.method == .key ? SSHText.keyFooter : SSHText.passwordFooter)
            }

            Section {
                Picker(SSHText.jumpHost, selection: $model.jumpHost) {
                    Text(SSHText.noJumpHost).tag(HostID?.none)
                    ForEach(model.jumpCandidates) { host in
                        Text(host.name).tag(HostID?.some(host.id))
                    }
                }
            } header: {
                Text(SSHText.routing)
            } footer: {
                Text(SSHText.jumpFooter)
            }

            if model.method == .key, model.selectedKey != nil {
                Section {
                    if model.jumpHost == nil {
                        SecureField(SSHText.installPassword, text: $model.installPassword)
                            .textContentType(.password)
                        Button(SSHText.install) { Task { await model.installKey() } }
                            .disabled(!model.canInstall)
                    }
                } header: {
                    Text(SSHText.installKey)
                } footer: {
                    Text(model.jumpHost == nil ? SSHText.installFooter : SSHText.installJumpUnsupported)
                }
            }

            if let message = model.message {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(model.isNew ? SSHText.newHost : SSHText.editHost)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(SSHText.cancel) { model.dismiss?() }
            }
            ToolbarItem(placement: .confirmationAction) {
                let saveEnabled = model.canSave
                Button(model.isNew ? SSHText.add : SSHText.save) { Task { await model.save() } }
                    .disabled(!saveEnabled)
                    // Toolbar buttons can expose their UIKit wrapper rather
                    // than the SwiftUI Button on iOS 26. Publish the disabled
                    // state on that wrapper as well, so keyboard and UI test
                    // clients cannot activate an empty host form.
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(saveEnabled ? [] : .notEnabled)
                    .accessibilityIdentifier("ssh.editor.save")
            }
        }
        .task { await model.load() }
    }
}
