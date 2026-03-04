import SwiftUI

// MARK: - Key Management View

struct SSHKeyManagementView: View {
    @State private var keys: [SSHKeyPair] = []
    @State private var newKeyLabel = ""
    @State private var showingGenerateSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var keyToDelete: SSHKeyPair?
    @State private var errorMessage: String?
    @State private var copiedKeyLabel: String?

    var body: some View {
        List {
            Section {
                ForEach(keys) { key in
                    SSHKeyRow(
                        key: key,
                        isCopied: copiedKeyLabel == key.label,
                        onCopyPublicKey: { copyPublicKey(key) },
                        onDelete: {
                            keyToDelete = key
                            showingDeleteConfirmation = true
                        }
                    )
                }

                if keys.isEmpty {
                    Text("No SSH keys. Generate one to connect to your Mac.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("SSH Keys")
            }
        }
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Generate Key") {
                    showingGenerateSheet = true
                }
            }
        }
        .sheet(isPresented: $showingGenerateSheet) {
            GenerateKeySheet(
                label: $newKeyLabel,
                onGenerate: { generateKey() },
                onCancel: { showingGenerateSheet = false }
            )
        }
        .alert("Delete Key?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let key = keyToDelete {
                Text("This will permanently delete \"\(key.label)\". Remove it from authorized_keys on any servers first.")
            }
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let msg = errorMessage { Text(msg) }
        }
        .onAppear { loadKeys() }
    }

    private func loadKeys() {
        do {
            keys = try SSHKeyStore.listKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateKey() {
        let label = newKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }

        do {
            _ = try SSHKeyStore.generateKeyPair(label: label)
            newKeyLabel = ""
            showingGenerateSheet = false
            loadKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyPublicKey(_ key: SSHKeyPair) {
        let pubKey = SSHKeyStore.publicKeyOpenSSH(key)
        UIPasteboard.general.string = pubKey
        copiedKeyLabel = key.label

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedKeyLabel == key.label {
                copiedKeyLabel = nil
            }
        }
    }

    private func deleteKey() {
        guard let key = keyToDelete else { return }
        do {
            try SSHKeyStore.deleteKey(label: key.label)
            keyToDelete = nil
            loadKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Key Row

private struct SSHKeyRow: View {
    let key: SSHKeyPair
    let isCopied: Bool
    let onCopyPublicKey: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.label)
                .font(.headline)

            Text(key.fingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text("Created \(key.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button { onCopyPublicKey() } label: {
                Label(
                    isCopied ? "Copied" : "Copy Public Key",
                    systemImage: isCopied ? "checkmark" : "doc.on.doc"
                )
            }
            .tint(.blue)
        }
        .contextMenu {
            Button { onCopyPublicKey() } label: {
                Label("Copy Public Key", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Generate Key Sheet

private struct GenerateKeySheet: View {
    @Binding var label: String
    let onGenerate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Key Label", text: $label, prompt: Text("e.g. MacBook Pro"))
                } footer: {
                    Text("A name to identify this key. An Ed25519 key pair will be generated and stored securely in the Keychain.")
                }
            }
            .navigationTitle("Generate SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate", action: onGenerate)
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
