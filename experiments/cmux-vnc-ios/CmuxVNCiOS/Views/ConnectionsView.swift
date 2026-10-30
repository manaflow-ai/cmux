import CmuxScreenKit
import CmuxScreenKitUI
import CmuxVNC
import CmuxVNCWebRTC
import SwiftUI

/// The start screen: the built-in demo desktop and saved computers.
struct ConnectionsView: View {
    @Environment(HostStore.self) private var store
    @State private var editing: SavedHost?
    @State private var session: ScreenSession?
    @State private var pairingLink: PairingLink?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        open(ScreenSession(demoPreferences: ScreenPreferences()))
                    } label: {
                        HostRow(title: "Demo desktop", subtitle: "A desktop drawn by this app, over a real VNC connection",
                                symbol: "sparkles.rectangle.stack")
                    }
                } footer: {
                    Text("Try the gestures here first: drag to paint, type to echo text.")
                }
                Section("Computers") {
                    if store.hosts.isEmpty {
                        ContentUnavailableView {
                            Label("No computers yet", systemImage: "display")
                        } description: {
                            Text("Add a Mac with Screen Sharing on, or any VNC server on your network or tailnet.")
                        } actions: {
                            Button("Add Computer") { editing = SavedHost(name: "", address: "", username: "") }
                        }
                    }
                    ForEach(store.hosts) { host in
                        Button {
                            connect(host)
                        } label: {
                            HostRow(title: host.name.isEmpty ? host.address : host.name,
                                    subtitle: host.subtitle, symbol: host.pairing != nil ? "antenna.radiowaves.left.and.right" : "desktopcomputer")
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.remove(host) }
                            Button("Edit") { editing = host }.tint(.gray)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = host }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.remove(host) }
                        }
                    }
                }
            }
            // The bundle's display name: "cmux VNC", or "cmux VNC Rust" for the Rust-host build.
            .navigationTitle(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "cmux VNC")
            .toolbar {
                Menu("Add", systemImage: "plus") {
                    Button("Pair a Mac over WebRTC", systemImage: "qrcode.viewfinder") { pairingLink = PairingLink(value: "") }
                    Button("Add by Address", systemImage: "network") { editing = SavedHost(name: "", address: "", username: "") }
                }
            }
            .sheet(item: $pairingLink) { link in
                PairView(link: link.value)
            }
            .onOpenURL { url in
                if VNCPairing(link: url) != nil { pairingLink = PairingLink(value: url.absoluteString) }
            }
            .sheet(item: $editing) { host in
                HostEditorView(host: host)
            }
            .fullScreenCover(item: $session) { session in
                ScreenSessionView(session: session) {
                    if let id = session.hostID { store.setOptions(session.preferences, for: id) }
                    self.session = nil
                }
            }
            .task {
                let autopilot = Autopilot()
                // `-openSaved <name>`: a saved computer, with its stored sign-in.
                if session == nil, let name = autopilot.value("-openSaved"), let host = store.hosts.first(where: { $0.name == name }) {
                    connect(host)
                    if autopilot.arguments.contains("-perfScript"), let opened = session { await autopilot.playPerfScript(on: opened) }
                    return
                }
                guard session == nil, let automatic = autopilot.session() else { return }
                open(automatic)
                if autopilot.arguments.contains("-perfScript") {
                    await autopilot.playPerfScript(on: automatic)
                } else if autopilot.playsScript {
                    await autopilot.play(on: automatic)
                }
            }
        }
    }

    private func connect(_ host: SavedHost) {
        if let pairing = host.pairing {
            let password = store.password(for: host)
            let session = ScreenSession(title: host.name, pairing: pairing,
                                        credentials: VNCCredentials(username: host.username, password: password), preferences: host.options)
            session.hostID = host.id
            open(session)
            return
        }
        guard let parsed = VNCEndpoint.parse(host.address) else { return }
        let password = store.password(for: host) ?? parsed.credentials.password
        let username = host.username.isEmpty ? parsed.credentials.username : host.username
        open(ScreenSession(title: host.name.isEmpty ? parsed.endpoint.label : host.name, endpoint: parsed.endpoint,
                           credentials: VNCCredentials(username: username, password: password), preferences: host.options))
    }

    private func open(_ session: ScreenSession) {
        session.perf = ScreenPerfLog()
        self.session = session
        session.connect()
    }
}

private struct HostRow: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A pairing link to show in `PairView` (sheet item).
struct PairingLink: Identifiable {
    let id = UUID()
    var value: String
}

