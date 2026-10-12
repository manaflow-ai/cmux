import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: model.user?.displayName ?? model.user?.email ?? "?", size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.user?.displayName ?? "Your account").font(.title3.weight(.semibold))
                            Text(model.user?.email ?? "").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    TextField("Name", text: $name)
                        .onSubmit { Task { await model.updateName(name) } }
                        .submitLabel(.done)
                }
                Section("Macs") {
                    ForEach(model.hosts) { host in
                        HStack {
                            Label(host.name, systemImage: "laptopcomputer")
                            Spacer()
                            ConnectionBadge(status: host.status)
                        }
                    }
                    Button {
                        dismiss()
                        shell.showAddMac = true
                    } label: {
                        Label("Add a Mac", systemImage: "plus")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("Connection", value: "WebRTC (peer to peer)")
                }
                Section {
                    Button("Sign out") { confirmSignOut = true }
                        .accessibilityIdentifier("settings.signout")
                    Button("Delete account", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .onAppear { name = model.user?.displayName ?? "" }
            .confirmationDialog("Sign out of cmux?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { await model.signOut() }
                }
            }
            .confirmationDialog(
                "Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    Task { try? await model.deleteAccount() }
                }
            } message: {
                Text("This removes your account and unpairs every Mac. It can't be undone.")
            }
        }
    }
}
