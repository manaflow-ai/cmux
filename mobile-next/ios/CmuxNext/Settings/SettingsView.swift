import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @AppStorage("appearance") private var appearance = "system"

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
                Section("Appearance") {
                    HStack(spacing: 12) {
                        ForEach([("light", "Light"), ("dark", "Dark"), ("system", "System")], id: \.0) { value, label in
                            AppearanceTile(kind: value, label: LocalizedStringKey(label), selected: appearance == value) {
                                appearance = value
                            }
                        }
                    }
                    .padding(.vertical, 6)
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
            .tint(.primary)
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

/// Claude-style appearance preview: a tiny chat card in that scheme.
struct AppearanceTile: View {
    let kind: String
    let label: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if kind == "system" {
                        HStack(spacing: 0) { preview(dark: false); preview(dark: true) }
                    } else {
                        preview(dark: kind == "dark")
                    }
                }
                .frame(height: 64)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.primary : Color(.separator), lineWidth: selected ? 2 : 0.5))
                Text(label).font(.footnote.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("appearance.\(kind)")
    }

    private func preview(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Color(hex: dark ? 0x1E1E1E : 0xFEFFFF)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color(hex: dark ? 0x555555 : 0xCCCCCC)).frame(width: 34, height: 5)
                Capsule().fill(Color(hex: dark ? 0x444444 : 0xDDDDDD)).frame(width: 24, height: 5)
            }
            .padding(10)
            Circle().fill(CmuxTheme.highlight).frame(width: 9, height: 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
        }
    }
}
