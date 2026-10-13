#if os(iOS)
import CnxAuth
import CnxDesign
import CnxModel
import SwiftUI
import UIKit
import UserNotifications

private let theme = CnxTheme.standard

/// Settings tab root (SPEC 9): inset grouped list on `bgGrouped`, leading
/// drawer circle, centered title, sub-pages pushed with the system edge swipe.
public struct SettingsScreen<Leading: ToolbarContent>: View {
    let auth: CnxAuthModel
    let store: AppStore
    let settings: SettingsStore
    let leading: () -> Leading
    let inviteToTeam: (Team) -> Void
    @Binding var path: [SettingsRoute]
    let scrollRequest: String?
    @State private var confirmsLogOut = false
    @State private var editingTeam: Team?

    public init(auth: CnxAuthModel, store: AppStore, settings: SettingsStore, path: Binding<[SettingsRoute]>, scrollRequest: String? = nil, inviteToTeam: @escaping (Team) -> Void, @ToolbarContentBuilder leading: @escaping () -> Leading) {
        self.scrollRequest = scrollRequest
        self.auth = auth
        self.store = store
        self.settings = settings
        _path = path
        self.inviteToTeam = inviteToTeam
        self.leading = leading
    }

    public var body: some View {
        @Bindable var settings = settings
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            List {
                accountSection.id("top")
                if let team = store.activeTeam {
                    Section("Team") {
                        NavigationLink(value: SettingsRoute.team) {
                            HStack(spacing: 14) {
                                TeamAvatar(name: team.name, colorHex: team.appearance.colorHex, emoji: team.appearance.emoji, size: 28)
                                Text(team.name).font(theme.type.rowTitle)
                            }
                        }
                    }
                }
                Section {
                    Picker(selection: $settings.transport) {
                        ForEach(TransportKind.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingsLabel("Transport", symbol: "antenna.radiowaves.left.and.right")
                    }
                    .pickerStyle(.menu)
                    NavigationLink(value: SettingsRoute.pairedMacs) {
                        SettingsLabel("Paired Macs", symbol: "desktopcomputer", value: "\(store.activeTeam?.macs.count ?? 0)")
                    }
                    Toggle(isOn: $settings.showConnectionDetails) {
                        SettingsLabel("Show connection details", symbol: "point.3.connected.trianglepath.dotted")
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Switching reconnects to your Macs.")
                }
                Section("Terminal") {
                    NavigationLink(value: SettingsRoute.terminal) {
                        SettingsLabel("Terminal", symbol: "apple.terminal", value: "\(settings.terminalFontSize) pt")
                    }
                    NavigationLink(value: SettingsRoute.composer) {
                        SettingsLabel("Composer", symbol: "keyboard", value: settings.followUp.title)
                    }
                }
                Section("Appearance") {
                    AppearanceTiles(selection: $settings.appearance)
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    Toggle(isOn: $settings.hapticsEnabled) {
                        SettingsLabel("Haptic feedback", symbol: "iphone.radiowaves.left.and.right")
                    }
                }
                .id("appearance")
                Section("Notifications") {
                    NavigationLink(value: SettingsRoute.notifications) {
                        SettingsLabel("Notifications", symbol: "bell")
                    }
                }
                Section {
                    Toggle(isOn: $settings.requireFaceID) {
                        SettingsLabel("Require Face ID", symbol: "faceid")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Require Face ID or passcode to open cmux on this device.")
                }
                #if DEBUG
                DeveloperSection(auth: auth)
                #endif
                Section("About") {
                    LinkRow("Help", symbol: "questionmark.circle", url: "https://cmux.com/docs")
                    LinkRow("Report a problem", symbol: "flag", url: "https://github.com/manaflow-ai/cmux/issues")
                    LinkRow("Terms of Use", symbol: "doc.text", url: "https://cmux.com/terms")
                    LinkRow("Privacy Policy", symbol: "hand.raised", url: "https://cmux.com/privacy")
                    NavigationLink(value: SettingsRoute.acknowledgements) {
                        SettingsLabel("Acknowledgements", symbol: "info.circle")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmsLogOut = true
                    } label: {
                        Label {
                            Text("Log out").font(theme.type.rowTitle)
                        } icon: {
                            Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 17))
                        }
                        .foregroundStyle(theme.colors.danger)
                    }
                    .accessibilityIdentifier("settings.logout")
                    .confirmationDialog("Log out of cmux?", isPresented: $confirmsLogOut, titleVisibility: .visible) {
                        Button("Log out", role: .destructive) { Task { await auth.signOut() } }
                    }
                } footer: {
                    VersionFooter().id("bottom")
                }
            }
            .onChange(of: scrollRequest) { _, target in
                guard let target else { return }
                withAnimation(theme.motion.gentle.animation) { proxy.scrollTo(target, anchor: target == "bottom" ? .bottom : .top) }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, theme.metrics.settingsRowHeight)
            .scrollContentBackground(.hidden)
            .background(theme.colors.bgGrouped.color.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { leading() }
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(route)
            }
            .sheet(item: $editingTeam) { team in
                TeamAppearanceEditor(team: team) { store.setAppearance($0, for: team.id) }
            }
            }
        }
        .cnxNeutralControlTint()
    }

    @ViewBuilder private var accountSection: some View {
        if let user = auth.user {
            Section {
                NavigationLink(value: SettingsRoute.account) {
                    HStack(spacing: 14) {
                        UserInitials(user.initials, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name).font(theme.type.rowTitle.weight(.semibold))
                            if let email = user.email {
                                Text(email).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .account: AccountPage(auth: auth)
        case .team:
            if let team = store.activeTeam {
                TeamPage(team: team, user: auth.user, edit: { editingTeam = team }, invite: { inviteToTeam(team) })
            }
        case .pairedMacs: PairedMacsPage(store: store, transport: settings.transport)
        case .terminal: TerminalPage(settings: settings)
        case .composer: ComposerPage(settings: settings)
        case .notifications: NotificationsPage(settings: settings)
        case .acknowledgements: AcknowledgementsPage()
        }
    }
}

/// Pushed settings pages.
public enum SettingsRoute: Hashable, Sendable {
    case account, team, pairedMacs, terminal, composer, notifications, acknowledgements

    /// The route named by its case name (DEBUG launch arguments).
    public init?(name: String) {
        let all: [SettingsRoute] = [.account, .team, .pairedMacs, .terminal, .composer, .notifications, .acknowledgements]
        guard let route = all.first(where: { "\($0)" == name }) else { return nil }
        self = route
    }
}

/// A settings row label: 17 pt line icon in a 22 pt frame, title, trailing value.
struct SettingsLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    let value: String?

    init(_ title: LocalizedStringKey, symbol: String, value: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.value = value
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: theme.metrics.settingsIconFrame)
                .foregroundStyle(theme.colors.label)
            Text(title).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
            if let value {
                Spacer(minLength: 8)
                Text(value).font(theme.type.rowTitle).foregroundStyle(theme.colors.label2)
            }
        }
    }
}

private struct LinkRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let url: String
    @Environment(\.openURL) private var openURL

    init(_ title: LocalizedStringKey, symbol: String, url: String) {
        self.title = title
        self.symbol = symbol
        self.url = url
    }

    var body: some View {
        Button {
            if let url = URL(string: url) { openURL(url) }
        } label: {
            HStack {
                SettingsLabel(title, symbol: symbol)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.label3)
            }
        }
    }
}

/// Initials in a circle on `surfaceRaised` (Claude's "AA").
struct UserInitials: View {
    let initials: String
    let size: CGFloat

    init(_ initials: String, size: CGFloat) {
        self.initials = initials
        self.size = size
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(theme.colors.label)
            .frame(width: size, height: size)
            .background(theme.colors.surfaceRaised, in: .circle)
            .accessibilityHidden(true)
    }
}

/// Light / Dark / System tiles (96 x 64 previews, selected 2 pt `label` stroke).
struct AppearanceTiles: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppearanceMode.allCases) { mode in
                let selected = mode == selection
                Button {
                    selection = mode
                    theme.haptics.selection()
                } label: {
                    VStack(spacing: 8) {
                        AppearancePreview(mode: mode)
                            .frame(height: 64)
                            .clipShape(.rect(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(selected ? theme.colors.label.color : theme.colors.separator.color, lineWidth: selected ? 2 : 0.5)
                            }
                            .animation(theme.motion.snap.animation, value: selected)
                        Text(mode.title)
                            .font(theme.type.meta.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? theme.colors.label : theme.colors.label2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct AppearancePreview: View {
    let mode: AppearanceMode

    var body: some View {
        ZStack {
            switch mode {
            case .light: page(dark: false)
            case .dark: page(dark: true)
            case .system:
                page(dark: false)
                page(dark: true).mask { DiagonalHalf() }
            }
        }
    }

    private func page(dark: Bool) -> some View {
        let bg = dark ? Color.black : Color.white
        let ink = dark ? Color.white : Color.black
        return ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink.opacity(0.55)).frame(width: 34, height: 4)
                Capsule().fill(ink.opacity(0.3)).frame(width: 24, height: 4)
            }
            .padding(10)
            Circle().fill(ink).frame(width: 12, height: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(9)
        }
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Centered mark + "Version 1.0 (123) · tag".
#if DEBUG
/// Settings → Developer (DEBUG and Demo builds): demo toggles read at launch,
/// so a phone demo needs no launch arguments.
private struct DeveloperSection: View {
    let auth: CnxAuthModel
    @AppStorage(DeveloperOptions.mockDataKey) private var mockData = false
    @AppStorage(DeveloperOptions.launchDemoKey) private var launchDemo = ""
    @State private var launchedWithMock = DeveloperOptions.mockData

    var body: some View {
        Section {
            Toggle(isOn: $mockData) {
                SettingsLabel("Mock data", symbol: "theatermasks")
            }
            Picker(selection: $launchDemo) {
                Text("None").tag("")
                ForEach(DeveloperOptions.demos, id: \.id) { demo in
                    Text(verbatim: demo.title).tag(demo.id)
                }
            } label: {
                SettingsLabel("Demo at next launch", symbol: "play.rectangle")
            }
            .pickerStyle(.menu)
            HStack {
                SettingsLabel("Service", symbol: "server.rack")
                Spacer()
                Text(verbatim: auth.apiBaseURL?.host() ?? (auth.isMock ? "Mock" : "None"))
                    .foregroundStyle(theme.colors.label3)
                    .lineLimit(1)
            }
            if mockData != launchedWithMock || !launchDemo.isEmpty {
                Button(role: .destructive) {
                    exit(0)
                } label: {
                    SettingsLabel("Quit to apply", symbol: "arrow.clockwise")
                }
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Mock data signs in as a sample user with sample teams, Macs and chats. Changes apply at the next launch: quit, then open cmux again. To sign in with the dev test account, enter 42 as the email.")
        }
    }
}
#endif

struct VersionFooter: View {
    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        let tag = (info["CNXTag"] as? String).flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        VStack(spacing: 8) {
            CmuxMark().fill(theme.colors.label3).frame(width: 16, height: 16)
            Text(verbatim: "Version \(version) (\(build))" + (tag.map { " · \($0)" } ?? ""))
                .font(theme.type.legal)
                .foregroundStyle(theme.colors.label3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .accessibilityElement(children: .combine)
    }
}
#endif
