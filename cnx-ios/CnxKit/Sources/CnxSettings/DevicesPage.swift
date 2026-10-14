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
    @State private var removalError: String?

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
                    row(mac)
                        .swipeActions(edge: .trailing) {
                            if directory != nil {
                                Button("Remove", role: .destructive) { pendingRemoval = mac }
                            }
                        }
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
                        row(phone)
                            .swipeActions(edge: .trailing) {
                                if !phone.isThisDevice {
                                    Button("Remove", role: .destructive) { pendingRemoval = phone }
                                }
                            }
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
            Text(device.kind == .mac
                 ? "This iPhone stops listing it. Links to it close."
                 : "It stops receiving notifications from your Macs.")
        }
        .alert("Couldn't remove", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
    }

    private var macs: [SettingsDevice] {
        guard directory != nil else {
            return (store.activeTeam?.macs ?? []).map {
                SettingsDevice(ids: [$0.id], kind: .mac, name: $0.name, online: $0.isOnline, lastSeenAt: $0.lastSeenAt, isThisDevice: false, receivesNotifications: false)
            }
        }
        return (devices ?? []).filter { $0.kind == .mac }
    }

    private var phones: [SettingsDevice] { (devices ?? []).filter { $0.kind == .phone } }

    @ViewBuilder private func row(_ device: SettingsDevice) -> some View {
        HStack(spacing: 14) {
            if device.kind == .mac {
                StatusDot(device.online == true ? .online : .offline)
                    .frame(width: theme.metrics.settingsIconFrame)
            } else {
                Image(systemName: "iphone").font(.system(size: 17)).frame(width: theme.metrics.settingsIconFrame)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(theme.type.rowTitle)
                Text(subtitle(device)).font(theme.type.meta).foregroundStyle(theme.colors.label2)
            }
        }
        .accessibilityElement(children: .combine)
        .deleteDisabled(device.isThisDevice || directory == nil)
    }

    private func subtitle(_ device: SettingsDevice) -> String {
        if device.kind == .phone {
            let notifications = device.receivesNotifications ? "Notifications on" : "Notifications off"
            return device.isThisDevice ? "This iPhone · \(notifications)" : notifications
        }
        if device.online == true { return "Online" }
        guard let seen = device.lastSeenAt else { return "Offline" }
        return "Last seen \(seen.formatted(.relative(presentation: .named)))"
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
        guard let directory else { return }
        do {
            try await directory.remove(device)
            devices?.removeAll { $0.id == device.id }
            theme.haptics.success()
        } catch {
            removalError = "Check your connection and try again."
        }
    }
}
#endif
