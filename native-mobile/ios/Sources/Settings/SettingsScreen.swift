import SwiftUI

/// Settings sheet (Claude / Grok / Codex layout): account card, Macs with
/// live status, terminal and composer behavior, appearance, sign out.
struct SettingsScreen: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("haptics") private var haptics = true
    @AppStorage("terminal.fontSize") private var fontSize = 12.0
    @AppStorage("composer.dismissAfterSend") private var dismissAfterSend = false
    @AppStorage("appearance") private var appearance = "system"
    @State private var showPairing = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Circle().fill(Theme.elevated).frame(width: 52, height: 52)
                            .overlay(Text(initials).font(.headline))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.user?.name ?? String(localized: "Signed in")).font(.body.weight(.semibold))
                            if let email = app.user?.email { Text(email).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(app.hosts) { host in
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                HStack(spacing: 5) {
                                    Circle().fill(statusColor(host)).frame(width: 7, height: 7)
                                    Text(statusText(host)).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if host.id == app.connection?.host.id {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture { app.connect(host) }
                        .swipeActions {
                            Button(role: .destructive) { Task { await app.unpair(host) } } label: {
                                Label(String(localized: "Unpair"), systemImage: "minus.circle")
                            }
                        }
                    }
                    Button { showPairing = true } label: {
                        Label(String(localized: "Connect a Mac"), systemImage: "plus")
                    }
                } header: {
                    Text(String(localized: "Macs"))
                } footer: {
                    if let path = app.connection?.path, !path.isEmpty {
                        Text(String(localized: "Connected over \(path)."))
                    }
                }

                Section(String(localized: "Terminal")) {
                    Stepper(value: $fontSize, in: 9...18, step: 1) {
                        LabeledContent(String(localized: "Font size"), value: "\(Int(fontSize)) pt")
                    }
                    Toggle(String(localized: "Dismiss keyboard after sending"), isOn: $dismissAfterSend)
                }

                Section(String(localized: "App")) {
                    Picker(String(localized: "Appearance"), selection: $appearance) {
                        Text(String(localized: "System")).tag("system")
                        Text(String(localized: "Light")).tag("light")
                        Text(String(localized: "Dark")).tag("dark")
                    }
                    Toggle(String(localized: "Haptic feedback"), isOn: $haptics)
                }

                Section {
                    Button(String(localized: "Sign Out"), role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text(versionText).frame(maxWidth: .infinity).padding(.top, 12)
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
            }
            .confirmationDialog(String(localized: "Sign out of cmux?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(String(localized: "Sign Out"), role: .destructive) { app.signOut(); dismiss() }
            }
            .sheet(isPresented: $showPairing) { PairingFlow(app: app) }
        }
    }

    private var initials: String {
        let parts = (app.user?.name ?? app.user?.email ?? "?").split(separator: " ")
        return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func statusColor(_ host: APIClient.Host) -> Color {
        if host.id == app.connection?.host.id, app.connection?.phase == .connected { return Theme.success }
        return host.online == true ? Theme.success : Color.secondary
    }

    private func statusText(_ host: APIClient.Host) -> String {
        if host.id == app.connection?.host.id, app.connection?.phase == .connected { return String(localized: "Connected") }
        if host.online == true { return String(localized: "Online") }
        if let seen = host.lastSeen {
            let date = Date(timeIntervalSince1970: seen > 1e12 ? seen / 1000 : seen)
            return String(localized: "Last seen \(date.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Offline")
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "cmux \(version) (\(build))"
    }
}
