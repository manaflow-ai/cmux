import SwiftUI

/// The generate sheet: name, type, and Face ID for enclave keys.
struct SSHKeyGenerateView: View {
    @Bindable var model: SSHKeysModel

    var body: some View {
        Form {
            Section {
                LabeledContent(SSHText.keyName) {
                    TextField(SSHText.keyName, text: $model.newLabel)
                        .multilineTextAlignment(.trailing)
                }
                Picker(SSHText.keyType, selection: $model.newKind) {
                    Text(SSHText.typeEd25519).tag(SSHKeyKindChoice.ed25519)
                    if model.secureEnclaveAvailable {
                        Text(SSHText.typeEnclave).tag(SSHKeyKindChoice.secureEnclave)
                    }
                }
                if model.newKind == .secureEnclave {
                    Toggle(SSHText.requireFaceID, isOn: $model.requireBiometry)
                }
            } footer: {
                Text(SSHText.typeFooter)
            }
            if let message = model.message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(SSHText.generate)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(SSHText.cancel) { model.showingGenerate = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(SSHText.generate) { Task { await model.generate() } }
                    .disabled(model.isWorking)
            }
        }
    }
}
