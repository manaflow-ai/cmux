#if os(iOS)
import CnxAuth
import CnxDesign
import CnxModel
import SwiftUI
import UIKit
import UserNotifications

private let theme = CnxTheme.standard

extension View {
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, theme.metrics.settingsRowHeight)
            .scrollContentBackground(.hidden)
            .background(theme.colors.bgGrouped.color.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountPage: View {
    let auth: CnxAuthModel
    let directory: (any SettingsDeviceDirectory)?
    @State private var methods: SettingsLoad<[SignInMethod]> = .loading
    @State private var confirmsDeletion = false
    @State private var deleting = false
    @State private var deletionError: String?

    var body: some View {
        List {
            if let user = auth.user {
                Section {
                    HStack(spacing: 14) {
                        UserInitials(user.initials, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name).font(theme.type.rowTitle.weight(.semibold))
                            if let email = user.email { Text(email).font(theme.type.meta).foregroundStyle(theme.colors.label2) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Name") { Text(user.name) }
                Section("Email") { Text(user.email ?? "No email") }
            }
            Section {
                switch methods {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading").foregroundStyle(theme.colors.label2)
                    }
                case .failed(let message):
                    SettingsLoadError(message: message) { Task { await loadMethods() } }
                case .loaded(let list) where list.isEmpty:
                    Text("No sign-in methods are linked.").foregroundStyle(theme.colors.label2)
                case .loaded(let list):
                    ForEach(list) { method in
                        HStack {
                            Text(method.title).font(theme.type.rowTitle)
                            Spacer(minLength: 8)
                            if let detail = method.detail {
                                Text(detail).font(theme.type.meta).foregroundStyle(theme.colors.label2).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Sign-in methods")
            }
            Section {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    HStack {
                        Text("Delete Account").foregroundStyle(theme.colors.danger)
                        if deleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(deleting)
                .accessibilityIdentifier("settings.deleteAccount")
            } footer: {
                Text("Deletes your cmux account and its data for every cmux app, and removes your Macs and phones from the cmux service. This can't be undone.")
            }
        }
        .settingsPage("Account")
        .task(id: auth.user?.id) { await loadMethods() }
        .confirmationDialog("Delete your cmux account?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Your cmux account is used by every cmux app (Mac, iPhone and web). Deleting it signs you out everywhere, removes your Macs and phones from the cmux service and permanently deletes your account. This can't be undone.")
        }
        .alert("Account not deleted", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        var purge: (@MainActor () async throws -> Void)?
        if let directory {
            purge = { try await directory.deleteAccountData() }
        }
        do {
            try await auth.deleteAccount(purgeServiceData: purge)
        } catch let error as CnxAuthModel.AccountDeletionError {
            deletionError = error.message
        } catch {
            deletionError = "Your account couldn't be deleted. Try again."
        }
    }

    private func loadMethods() async {
        methods = .loading
        do {
            methods = .loaded(try await auth.signInMethods())
        } catch is CancellationError {
        } catch {
            methods = .failed("Couldn't load your sign-in methods.")
        }
    }
}

/// A Settings list loaded from the cloud service.
enum SettingsLoad<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)
}

/// A failed load with a Retry button.
struct SettingsLoadError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.colors.label2)
            Text(message).font(theme.type.meta).foregroundStyle(theme.colors.label2)
            Spacer(minLength: 8)
            Button("Retry", action: retry).font(theme.type.rowTitle)
        }
    }
}

struct TeamPage: View {
    let team: Team
    let auth: CnxAuthModel
    let edit: () -> Void
    let invite: () -> Void
    @State private var members: SettingsLoad<[TeamMember]> = .loading

    var body: some View {
        List {
            Section {
                Button(action: edit) {
                    HStack(spacing: 14) {
                        TeamAvatar(name: team.name, colorHex: team.appearance.colorHex, emoji: team.appearance.emoji, size: 28)
                        Text("Color and icon").font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.colors.label3)
                    }
                }
            } footer: {
                Text("Color and icon are yours only; teammates choose their own.")
            }
            Section("Members") {
                switch members {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading members").foregroundStyle(theme.colors.label2)
                    }
                case .failed(let message):
                    SettingsLoadError(message: message) { Task { await loadMembers() } }
                case .loaded(let list):
                    ForEach(list) { member in
                        HStack(spacing: 14) {
                            UserInitials(member.initials, size: 28)
                            Text(member.name).font(theme.type.rowTitle)
                            Spacer()
                            if member.isYou {
                                Text("You").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Section {
                Button(action: invite) {
                    SettingsLabel("Invite to team", symbol: "person.badge.plus")
                }
            }
        }
        .settingsPage(LocalizedStringKey(team.name))
        .task(id: team.id) { await loadMembers() }
        .refreshable { await loadMembers() }
    }

    private func loadMembers() async {
        if case .loaded = members {} else { members = .loading }
        do {
            members = .loaded(try await auth.teamMembers(teamID: team.id))
        } catch is CancellationError {
        } catch {
            members = .failed("Couldn't load the team's members.")
        }
    }
}

struct TerminalPage: View {
    let settings: SettingsStore

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Stepper(value: $settings.terminalFontSize, in: CnxPreferences.terminalFontSizes) {
                    SettingsLabel("Font size", symbol: "textformat.size", value: "\(settings.terminalFontSize) pt")
                }
                Text(verbatim: "~/cmux $ swift build")
                    .font(.system(size: CGFloat(settings.terminalFontSize), design: .monospaced))
                    .foregroundStyle(Color(hex: "#E6E6E6"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.black, in: .rect(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } footer: {
                Text("Applies to open terminals at once.")
            }
            Section {
                Toggle(isOn: $settings.wrapCode) { SettingsLabel("Wrap code and diff lines", symbol: "text.word.spacing") }
                Toggle(isOn: $settings.keyClicks) { SettingsLabel("Key clicks", symbol: "keyboard") }
            } header: {
                Text("Code")
            } footer: {
                Text("Key clicks sound when you tap the keys above the keyboard. They follow the ring/silent switch.")
            }
        }
        .settingsPage("Terminal")
    }
}

struct ComposerPage: View {
    let settings: SettingsStore

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle(isOn: $settings.dismissKeyboardAfterSend) {
                    SettingsLabel("Dismiss keyboard after sending", symbol: "keyboard.chevron.compact.down")
                }
                Picker(selection: $settings.followUp) {
                    ForEach(FollowUpBehavior.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel("Follow-up while running", symbol: "arrow.turn.down.right")
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Queue sends after the current turn. Steer interrupts the agent.")
            }
        }
        .settingsPage("Composer")
    }
}

struct NotificationsPage: View {
    let settings: SettingsStore
    @State private var status: UNAuthorizationStatus?
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Button {
                    if status == .notDetermined {
                        Task {
                            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                            if granted { UIApplication.shared.registerForRemoteNotifications() }
                            await refresh()
                        }
                    } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        SettingsLabel("Allow notifications", symbol: "bell.badge")
                        Spacer()
                        Text(statusText).foregroundStyle(theme.colors.label2)
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.notifyQuestions) { SettingsLabel("Questions and permissions", symbol: "questionmark.bubble") }
                Toggle(isOn: $settings.notifyFinished) { SettingsLabel("Finished tasks", symbol: "checkmark.circle") }
                Toggle(isOn: $settings.notifyErrors) { SettingsLabel("Errors", symbol: "exclamationmark.triangle") }
            } header: {
                Text("Notify me about")
            } footer: {
                Text("Your Macs send these through the cmux service. A notification names the agent and workspace only, never what the agent wrote.")
            }
        }
        .settingsPage("Notifications")
        .task { await refresh() }
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        case .notDetermined: "Not set"
        default: ""
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

struct AcknowledgementsPage: View {
    var body: some View {
        List {
            ForEach(Acknowledgement.groups, id: \.id) { group in
                Section {
                    ForEach(group.items, id: \.name) { item in
                        Link(destination: item.url) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(verbatim: item.name).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                                    Spacer(minLength: 8)
                                    Text(verbatim: item.license).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                                }
                                Text(item.use).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .settingsPage("Acknowledgements")
    }
}

/// Third-party software in the app: the Swift packages CnxKit links
/// (`CnxKit/Package.swift`), the Rust crates in the link library
/// (`rust/Cargo.toml`, `cnx-ffi`), and the vendored web renderer
/// (`CnxMarkdown/Resources/web/THIRD_PARTY.txt`).
struct Acknowledgement: Sendable {
    let name: String
    let license: String
    let use: LocalizedStringResource
    let url: URL

    struct Group: Sendable {
        let id: String
        let title: LocalizedStringResource
        let items: [Acknowledgement]

        init(title: String.LocalizationValue, items: [Acknowledgement]) {
            self.id = "\(items.first?.name ?? "")"
            self.title = LocalizedStringResource(title)
            self.items = items
        }
    }

    private init(_ name: String, _ license: String, _ use: LocalizedStringResource, _ url: String) {
        self.name = name
        self.license = license
        self.use = use
        self.url = URL(string: url)!
    }

    static let groups: [Group] = [
        Group(title: "Terminal", items: [
            Acknowledgement("Ghostty", "MIT", "Terminal emulation and rendering", "https://github.com/ghostty-org/ghostty"),
        ]),
        Group(title: "Connection", items: [
            Acknowledgement("webrtc-rs", "MIT or Apache 2.0", "WebRTC data channels to your Mac", "https://github.com/webrtc-rs/webrtc"),
            Acknowledgement("BoringTun", "BSD 3-Clause", "WireGuard® protocol", "https://github.com/cloudflare/boringtun"),
            Acknowledgement("smoltcp", "0BSD", "TCP/IP inside the WireGuard tunnel", "https://github.com/smoltcp-rs/smoltcp"),
            Acknowledgement("x25519-dalek", "BSD 3-Clause", "Key exchange", "https://github.com/dalek-cryptography/curve25519-dalek"),
            Acknowledgement("rustls", "Apache 2.0, ISC or MIT", "TLS", "https://github.com/rustls/rustls"),
            Acknowledgement("ring", "Apache 2.0 and ISC", "Cryptography", "https://github.com/briansmith/ring"),
            Acknowledgement("Tokio", "MIT", "Asynchronous runtime", "https://github.com/tokio-rs/tokio"),
            Acknowledgement("reqwest", "MIT or Apache 2.0", "HTTP client", "https://github.com/seanmonstar/reqwest"),
            Acknowledgement("tokio-tungstenite", "MIT", "WebSockets", "https://github.com/snapview/tokio-tungstenite"),
            Acknowledgement("ip_network", "BSD 2-Clause", "Tunnel addressing", "https://github.com/JakubOnderka/ip_network"),
            Acknowledgement("Serde", "MIT or Apache 2.0", "Serialization", "https://github.com/serde-rs/serde"),
            Acknowledgement("UniFFI", "MPL 2.0", "Swift bindings for the connection library", "https://github.com/mozilla/uniffi-rs"),
        ]),
        Group(title: "Sign-in", items: [
            Acknowledgement("Stack Auth Swift SDK", "MIT", "Sign-in", "https://github.com/stack-auth/stack-auth"),
            Acknowledgement("swift-crypto", "Apache 2.0", "Cryptography for sign-in", "https://github.com/apple/swift-crypto"),
            Acknowledgement("swift-asn1", "Apache 2.0", "Used by swift-crypto", "https://github.com/apple/swift-asn1"),
        ]),
        Group(title: "Rendering", items: [
            Acknowledgement("marked", "MIT", "Markdown in the Feed", "https://github.com/markedjs/marked"),
            Acknowledgement("Temml", "MIT", "Math", "https://github.com/ronkok/Temml"),
            Acknowledgement("highlight.js", "BSD 3-Clause", "Code highlighting", "https://github.com/highlightjs/highlight.js"),
        ]),
    ]
}
#endif
