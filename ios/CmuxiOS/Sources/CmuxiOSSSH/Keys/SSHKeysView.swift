import CmuxMobileSSH
import SwiftUI

/// Keys on this device with copy and share of each public key.
struct SSHKeysView: View {
    @Bindable var model: SSHKeysModel

    var body: some View {
        List {
            if model.keys.isEmpty {
                Text(SSHText.keysEmpty).foregroundStyle(.secondary)
            }
            ForEach(model.keys) { key in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key.label).font(.body)
                        Text(key.algorithm + " · " + SSHKeysModel.kindLabel(key.kind))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(key.fingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    PublicKeyActions(publicKeyLine: key.publicKeyLine)
                    Button(SSHText.delete, role: .destructive) { Task { await model.askDelete(key) } }
                }
            }
            if let message = model.message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("ssh.keys.list")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(SSHText.generate, systemImage: "plus") { model.beginGenerate() }
                    .accessibilityIdentifier("ssh.keys.generate")
            }
        }
        .sheet(isPresented: $model.showingGenerate) {
            NavigationStack { SSHKeyGenerateView(model: model) }
        }
        .confirmationDialog(
            String(format: SSHText.deleteKeyTitle, model.pendingDelete?.label ?? ""),
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(SSHText.delete, role: .destructive) { Task { await model.confirmDelete() } }
            Button(SSHText.cancel, role: .cancel) { model.pendingDelete = nil }
        } message: {
            if model.pendingDeleteUsers > 0 {
                Text(SSHText.deleteKeyBody + "\n" + String(format: SSHText.deleteKeyInUse, Int64(model.pendingDeleteUsers)))
            } else {
                Text(SSHText.deleteKeyBody)
            }
        }
        .task { await model.load() }
    }
}
