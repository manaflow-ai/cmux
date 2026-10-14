#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// One of the account's devices as Settings → Connection lists it. A phone
/// registers two service devices (link and presence); `ids` holds both, so
/// removing the phone removes them together.
public struct SettingsDevice: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable { case mac, phone }

    public var id: String { ids.first ?? name }
    public var ids: [String]
    public var kind: Kind
    public var name: String
    /// Live presence for a Mac; nil for a phone.
    public var online: Bool?
    public var lastSeenAt: Date?
    public var isThisDevice: Bool
    /// A phone with an APNs token registered.
    public var receivesNotifications: Bool

    public init(ids: [String], kind: Kind, name: String, online: Bool?, lastSeenAt: Date?, isThisDevice: Bool, receivesNotifications: Bool) {
        self.ids = ids
        self.kind = kind
        self.name = name
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.isThisDevice = isThisDevice
        self.receivesNotifications = receivesNotifications
    }
}

/// The live service behind Settings → Connection and account deletion (the
/// shell supplies it; mock mode has none).
@MainActor
public protocol SettingsDeviceDirectory: AnyObject {
    func devices() async throws -> [SettingsDevice]
    func remove(_ device: SettingsDevice) async throws
    /// Whether the service has a TURN relay (nil: not known yet).
    var relayAvailable: Bool? { get }
    /// Account deletion, first step: the service forgets this account.
    func deleteAccountData() async throws
}

/// Settings → Connection → Paired Macs: the account's Macs and phones from
/// the service, with real presence; stale ones can be removed.
struct PairedMacsPage: View {
    let store: AppStore
    let directory: (any SettingsDeviceDirectory)?
    @State private var devices: [SettingsDevice]?
    @State private var loadError: String?
    @State private var pendingRemoval: SettingsDevice?
    @State private var removalError: ServiceFailureMessage?
    /// Rows whose removal is in flight (shown dimmed, not removable twice).
    @State private var removing: Set<String> = []

    var body: some View {
        List {
            if let relay = directory?.relayAvailable, !relay {
                Section {
                    Label("Relay (TURN) unavailable — connections outside your network may fail.", systemImage: "exclamationmark.triangle")
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.label2)
                }
            }
            Section {
                if macs.isEmpty {
                    Text(devices == nil && directory != nil ? "Loading…" : "No Macs yet. Open cmux on your Mac and sign in with this account.")
                        .font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
                ForEach(macs) { mac in
                    removableRow(mac)
                }
                .onDelete { offsets in pendingRemoval = offsets.first.map { macs[$0] } }
            } header: {
                Text("Macs")
            } footer: {
                if directory != nil { Text("Remove a Mac you no longer use. It comes back if cmux on that Mac signs in again.") }
            }
            if directory != nil {
                Section {
                    ForEach(phones) { phone in
                        removableRow(phone)
                    }
                    .onDelete { offsets in pendingRemoval = offsets.first.map { phones[$0] } }
                } header: {
                    Text("Phones")
                } footer: {
                    Text("Sign out to remove this iPhone.")
                }
            }
            if let loadError {
                Section { Text(loadError).font(theme.type.meta).foregroundStyle(theme.colors.danger) }
            }
        }
        .settingsPage("Paired Macs")
        .toolbar { if directory != nil { EditButton() } }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { device in
            Button("Remove", role: .destructive) { Task { await remove(device) } }
        } message: { device in
            Text(Self.removalExplanation(device, connected: isConnected(device)))
        }
        .alert("Couldn't remove", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError?.display ?? "")
        }
    }

    private var macs: [SettingsDevice] {
        guard directory != nil else {
            return (store.activeTeam?.macs ?? []).map {
                SettingsDevice(ids: [$0.id], kind: .mac, name: $0.name, online: $0.isOnline, lastSeenAt: $0.lastSeenAt, isThisDevice: false, receivesNotifications: false)
            }
        }
        // The service's list, with live presence from the store where this
        // phone follows the Mac (the list itself is as old as the page).
        let live = Dictionary(store.teams.flatMap(\.macs).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (devices ?? []).filter { $0.kind == .mac }.map { device in
            guard let mac = device.ids.lazy.compactMap({ live[$0] }).first else { return device }
            var next = device
            next.online = mac.isOnline
            next.lastSeenAt = mac.lastSeenAt ?? device.lastSeenAt
            return next
        }
    }

    private func canRemove(_ device: SettingsDevice) -> Bool {
        directory != nil && !device.isThisDevice && !removing.contains(device.id)
    }

    /// A row with its Remove paths: the trailing swipe, the context menu, and
    /// Edit's delete control (`onDelete`).
    @ViewBuilder private func removableRow(_ device: SettingsDevice) -> some View {
        row(device)
            .opacity(removing.contains(device.id) ? 0.5 : 1)
            .swipeActions(edge: .trailing) {
                if canRemove(device) {
                    Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = device }
                        // The app tints controls with the foreground color (white
                        // in dark mode), which made a blank white pill. Back to
                        // the system tint: red for the role.
                        .tint(nil)
                }
            }
            .contextMenu {
                if canRemove(device) {
                    Button(device.kind == .mac ? "Remove Mac" : "Remove iPhone", systemImage: "trash", role: .destructive) {
                        pendingRemoval = device
                    }
                }
            }
    }

    /// Whether this phone's link is on the Mac now (or dialing it).
    private func isConnected(_ device: SettingsDevice) -> Bool {
        device.kind == .mac && device.ids.contains { store.macConnection[$0] != nil }
    }

    /// The confirmation's message: what removal does, and how the device comes back.
    static func removalExplanation(_ device: SettingsDevice, connected: Bool) -> String {
        guard device.kind == .mac else {
            return "It stops receiving notifications from your Macs and leaves this list. It comes back when cmux on it signs in again."
        }
        var parts = ["\(device.name) leaves the Mac list on all your devices, and this iPhone forgets its saved workspaces."]
        if connected { parts.append("This iPhone disconnects from it now.") }
        if device.online == true {
            parts.append("It's online, so cmux on that Mac can add it back. To keep it off, turn off Settings → Mobile on that Mac.")
        } else {
            parts.append("To use it again, sign in to cmux on that Mac or turn on Settings → Mobile there.")
        }
        return parts.joined(separator: " ")
    }

    private var phones: [SettingsDevice] { (devices ?? []).filter { $0.kind == .phone } }

    @ViewBuilder private func row(_ device: SettingsDevice) -> some View {
        HStack(spacing: 14) {
            if device.kind == .mac {
                StatusDot(Self.dot(status(device)?.dot ?? (device.online == true ? .connected : .offline)))
                    .frame(width: theme.metrics.settingsIconFrame)
            } else {
                Image(systemName: "iphone").font(.system(size: 17)).frame(width: theme.metrics.settingsIconFrame)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(theme.type.rowTitle)
                Text(subtitle(device)).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                if device.kind == .mac, device.online == true,
                   let link = device.ids.lazy.compactMap({ store.macLinkStatus[$0] }).first {
                    Text(link).font(theme.type.meta).foregroundStyle(theme.colors.label2).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .deleteDisabled(!canRemove(device))
    }

    private func subtitle(_ device: SettingsDevice) -> String {
        if device.kind == .phone {
            let notifications = device.receivesNotifications ? "Notifications on" : "Notifications off"
            return device.isThisDevice ? "This iPhone · \(notifications)" : notifications
        }
        if device.online == true { return status(device)?.text ?? "Online" }
        guard let seen = device.lastSeenAt else { return "Offline" }
        return "Last seen \(seen.formatted(.relative(presentation: .named)))"
    }

    /// Presence plus this phone's own connection, for a Mac this phone knows:
    /// green "Online" only while connected.
    private func status(_ device: SettingsDevice) -> MacStatusLine? {
        guard device.kind == .mac, device.online == true else { return nil }
        let mac = MacDevice(id: device.ids.first(where: { store.macConnection[$0] != nil }) ?? device.ids.first ?? "",
                            name: device.name, isOnline: true, lastSeenAt: device.lastSeenAt)
        return store.macStatusLine(mac, presence: "Online")
    }

    static func dot(_ dot: MacStatusLine.Dot) -> StatusDot.State {
        switch dot {
        case .connected: .online
        case .connecting: .busy
        case .failed: .error
        case .offline: .offline
        }
    }

    private func load() async {
        guard let directory else { return }
        do {
            devices = try await directory.devices()
            loadError = nil
        } catch {
            loadError = "Couldn't load your devices. Pull to try again."
        }
    }

    private func remove(_ device: SettingsDevice) async {
        guard let directory, !removing.contains(device.id) else { return }
        removing.insert(device.id)
        defer { removing.remove(device.id) }
        do {
            try await directory.remove(device)
            devices?.removeAll { $0.id == device.id }
            theme.haptics.success()
        } catch let failure as ServiceFailureMessage {
            removalError = failure
            theme.haptics.error()
        } catch {
            removalError = ServiceFailureMessage(text: "Couldn't remove \(device.name): \(error.localizedDescription)")
            theme.haptics.error()
        }
    }
}
#endif
