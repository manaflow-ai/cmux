import LocalAuthentication
import SwiftUI
import UserNotifications

/// Settings sheet in the Claude / Codex / Grok layout: account header,
/// Macs with live status, terminal behavior, notifications, appearance,
/// security, about, and Sign Out alone at the bottom.
struct SettingsScreen: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("haptics") private var haptics = true
    @AppStorage("terminal.fontSize") private var fontSize = 12.0
    @AppStorage("composer.dismissAfterSend") private var dismissAfterSend = false
    @AppStorage("composer.visible") private var showComposer = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(AppLock.settingKey) private var requireUnlock = false
    @State private var showPairing = false
    @State private var confirmSignOut = false
    @State private var pendingUnpair: APIClient.Host?
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var lockError: String?

    var body: some View {
        NavigationStack {
            List {
                accountSection
                macsSection
                terminalSection
                notificationsSection
                appearanceSection
                securitySection
                aboutSection
                Section {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label(String(localized: "Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(Theme.danger)
                    }
                    .accessibilityIdentifier("settings.signOut")
                } footer: {
                    Text(versionText)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
            }
            .confirmationDialog(String(localized: "Sign out of cmux?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(String(localized: "Sign Out"), role: .destructive) { app.signOut(); dismiss() }
            } message: {
                Text(String(localized: "Your paired Macs stay paired. Sign in again to reconnect."))
            }
            .confirmationDialog(
                String(localized: "Unpair \(pendingUnpair?.name ?? "")?"),
                isPresented: Binding(get: { pendingUnpair != nil }, set: { if !$0 { pendingUnpair = nil } }),
                titleVisibility: .visible,
                presenting: pendingUnpair
            ) { host in
                Button(String(localized: "Unpair"), role: .destructive) {
                    Haptics.warning()
                    Task { await app.unpair(host) }
                }
            } message: { _ in
                Text(String(localized: "This iPhone stops reaching the Mac until you pair it again."))
            }
            .sheet(isPresented: $showPairing) { PairingFlow(app: app) }
            .task(id: scenePhase) { await loadNotificationStatus() }
        }
    }

    // MARK: Sections

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                Text(initials)
                    .font(.headline)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.elevated))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    let name = app.user?.name.flatMap { $0.isEmpty ? nil : $0 }
                    Text(name ?? app.user?.email ?? String(localized: "Signed in"))
                        .font(.body.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if name != nil, let email = app.user?.email {
                        Text(email).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Label(String(localized: "Personal"), systemImage: "person")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var macsSection: some View {
        Section {
            ForEach(app.hosts) { host in
                Button {
                    guard host.id != app.connection?.host.id else { return }
                    Haptics.selection()
                    app.connect(host)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer")
                            .frame(width: 28)
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Circle().fill(statusColor(host)).frame(width: 7, height: 7)
                                Text(statusText(host)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if host.id == app.connection?.host.id {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.primary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(host.id == app.connection?.host.id ? .isSelected : [])
                .accessibilityIdentifier("settings.host")
                .swipeActions {
                    Button(role: .destructive) { pendingUnpair = host } label: {
                        Label(String(localized: "Unpair"), systemImage: "minus.circle")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { pendingUnpair = host } label: {
                        Label(String(localized: "Unpair \(host.name)"), systemImage: "minus.circle")
                    }
                }
            }
            Button { showPairing = true } label: {
                Label(String(localized: "Add a Mac"), systemImage: "plus")
            }
            .accessibilityIdentifier("settings.addMac")
            if let current = app.connection?.host, app.hosts.count == 1 {
                Button(role: .destructive) { pendingUnpair = current } label: {
                    Label(String(localized: "Unpair This Mac"), systemImage: "minus.circle")
                        .foregroundStyle(Theme.danger)
                }
            }
        } header: {
            Text(String(localized: "Macs"))
        } footer: {
            if let path = app.connection?.path, !path.isEmpty {
                Text(path == "relay"
                    ? String(localized: "Connected through an encrypted relay.")
                    : String(localized: "Connected directly to your Mac, end-to-end encrypted."))
            } else if app.hosts.count > 1 {
                Text(String(localized: "Swipe a Mac to unpair it."))
            }
        }
    }

    private var terminalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(String(localized: "Font size"), systemImage: "textformat.size")
                    Spacer()
                    Text("\(Int(fontSize)) pt").foregroundStyle(.secondary).monospacedDigit()
                }
                TerminalFontPreview(size: fontSize)
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $fontSize, in: 9...18, step: 1) {
                        Text(String(localized: "Font size"))
                    } onEditingChanged: { _ in Haptics.selection() }
                    .accessibilityValue(String(localized: "\(Int(fontSize)) points"))
                    .accessibilityIdentifier("settings.fontSize")
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .onChange(of: fontSize) { Haptics.selection() }
            Toggle(isOn: $showComposer) {
                Label(String(localized: "Composer bar"), systemImage: "keyboard")
            }
            .tint(Theme.switchOn)
            Toggle(isOn: $dismissAfterSend) {
                Label(String(localized: "Dismiss keyboard after sending"), systemImage: "keyboard.chevron.compact.down")
            }
            .tint(Theme.switchOn)
            .disabled(!showComposer)
            Toggle(isOn: $haptics) {
                Label(String(localized: "Haptic feedback"), systemImage: "iphone.radiowaves.left.and.right")
            }
            .tint(Theme.switchOn)
        } header: {
            Text(String(localized: "Terminal"))
        }
    }

    private var notificationsSection: some View {
        Section {
            Button {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            } label: {
                HStack {
                    Label(String(localized: "Notifications"), systemImage: "bell.badge").foregroundStyle(.primary)
                    Spacer()
                    Text(notificationText).foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint(String(localized: "Opens iOS Settings"))
            .accessibilityIdentifier("settings.notifications")
        } header: {
            Text(String(localized: "Notifications"))
        } footer: {
            Text(String(localized: "Get alerts when an agent asks a question, needs permission or finishes."))
        }
    }

    private var appearanceSection: some View {
        Section(String(localized: "Appearance")) {
            AppearancePicker(selection: $appearance)
                .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
        }
    }

    private var securitySection: some View {
        Section {
            Toggle(isOn: Binding(get: { requireUnlock }, set: { setRequireUnlock($0) })) {
                Label(String(localized: "Require \(AppLock.biometryName)"), systemImage: AppLock.biometrySymbol)
            }
            .tint(Theme.switchOn)
            .accessibilityIdentifier("settings.requireFaceID")
        } header: {
            Text(String(localized: "Security"))
        } footer: {
            if let lockError {
                Text(lockError).foregroundStyle(Theme.danger)
            } else {
                Text(String(localized: "Require \(AppLock.biometryName) or your passcode to open cmux. The app is hidden in the app switcher."))
            }
        }
    }

    private var aboutSection: some View {
        Section(String(localized: "About")) {
            LabeledContent {
                Text(versionNumber).monospacedDigit()
            } label: {
                Label(String(localized: "Version"), systemImage: "info.circle")
            }
            NavigationLink {
                LicensesScreen()
            } label: {
                Label(String(localized: "Acknowledgements"), systemImage: "doc.text")
            }
            Link(destination: LegalLinks.privacy) {
                linkRow(String(localized: "Privacy Policy"), systemImage: "hand.raised")
            }
            Link(destination: LegalLinks.terms) {
                linkRow(String(localized: "Terms of Use"), systemImage: "doc.plaintext")
            }
        }
    }

    private func linkRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    // MARK: Helpers

    private func setRequireUnlock(_ on: Bool) {
        lockError = nil
        guard on else { requireUnlock = false; return }
        // Confirm the owner can authenticate before locking the app behind it.
        Task {
            do {
                try await AppLock.authenticate(reason: String(localized: "Turn on \(AppLock.biometryName) for cmux"))
                requireUnlock = true
                Haptics.success()
            } catch {
                lockError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
                requireUnlock = false
            }
        }
    }

    private func loadNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private var notificationText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: String(localized: "On")
        case .denied: String(localized: "Off")
        case .notDetermined: String(localized: "Not set")
        default: ""
        }
    }

    private var initials: String {
        let source = app.user?.name ?? app.user?.email ?? "?"
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        let letters = parts.prefix(source.contains(" ") ? 2 : 1).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private func statusColor(_ host: APIClient.Host) -> Color {
        if host.id == app.connection?.host.id {
            switch app.connection?.phase {
            case .connected: return Theme.success
            case .connecting, .reconnecting: return Theme.attention
            default: return Color.secondary
            }
        }
        return host.online == true ? Theme.success : Color.secondary
    }

    private func statusText(_ host: APIClient.Host) -> String {
        if host.id == app.connection?.host.id {
            switch app.connection?.phase {
            case .connected: return String(localized: "Connected")
            case .connecting: return String(localized: "Connecting…")
            case .reconnecting: return String(localized: "Reconnecting…")
            default: break
            }
        }
        if host.online == true { return String(localized: "Online") }
        if let seen = host.lastSeen {
            let date = Date(timeIntervalSince1970: seen > 1e12 ? seen / 1000 : seen)
            return String(localized: "Last seen \(date.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Offline")
    }

    private var versionNumber: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var versionText: String { "cmux \(versionNumber)" }
}

/// A terminal-colored sample that follows the font size slider live.
struct TerminalFontPreview: View {
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "~/repo main $ claude").foregroundStyle(Color(uiColor: Theme.terminalForeground))
            Text(verbatim: "> Fix the failing test in Parser.swift").foregroundStyle(Color(uiColor: Theme.terminalForeground).opacity(0.7))
        }
        .font(.system(size: size, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: Theme.terminalBackground)))
        .animation(.snappy(duration: 0.15), value: size)
        .accessibilityHidden(true)
    }
}

/// Claude-style appearance tiles: Light, Dark, System.
struct AppearancePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            tile("light", String(localized: "Light"))
            tile("dark", String(localized: "Dark"))
            tile("system", String(localized: "System"))
        }
    }

    private func tile(_ value: String, _ title: String) -> some View {
        let selected = selection == value
        return Button {
            Haptics.selection()
            withAnimation(.smooth(duration: 0.25)) { selection = value }
        } label: {
            VStack(spacing: 8) {
                AppearanceSwatch(kind: value)
                    .frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.primary : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                Text(title)
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appearance.\(value)")
    }
}

private struct AppearanceSwatch: View {
    let kind: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch kind {
                case "light": page(light: true)
                case "dark": page(light: false)
                default:
                    page(light: true)
                    page(light: false).mask(DiagonalHalf())
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func page(light: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            (light ? Color.white : Color(white: 0.1))
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(light ? Color(white: 0.3) : Color(white: 0.8)).frame(width: 30, height: 4)
                Capsule().fill(light ? Color(white: 0.7) : Color(white: 0.45)).frame(width: 20, height: 4)
            }
            .padding(10)
            Circle().fill(Theme.attention).frame(width: 8, height: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(10)
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

/// Third-party software shipped in the app.
struct LicensesScreen: View {
    private struct Entry: Identifiable {
        let name: String
        let license: String
        let url: URL
        var id: String { name }
    }

    private let entries = [
        Entry(name: "Ghostty", license: "MIT License", url: URL(string: "https://github.com/ghostty-org/ghostty/blob/main/LICENSE")!),
        Entry(name: "WebRTC", license: "BSD 3-Clause License", url: URL(string: "https://webrtc.googlesource.com/src/+/main/LICENSE")!),
        Entry(name: "WebRTC (stasel/WebRTC)", license: "BSD 3-Clause License", url: URL(string: "https://github.com/stasel/WebRTC/blob/latest/LICENSE")!),
    ]

    var body: some View {
        List(entries) { entry in
            Link(destination: entry.url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).foregroundStyle(.primary)
                    Text(entry.license).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(String(localized: "Acknowledgements"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
