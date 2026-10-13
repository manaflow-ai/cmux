import SwiftUI

/// Paired Macs, their link state, pairing another Mac, and the phone's key.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var confirmUnpair: HostConnection?

    var body: some View {
        NavigationStack {
            List {
                Section("Macs") {
                    ForEach(model.connections) { connection in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Circle().fill(connection.phase.dotColor).frame(width: 8, height: 8)
                                Text(connection.host.hostName).font(.body.weight(.medium))
                            }
                            Text(detail(connection))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Unpair", role: .destructive) { confirmUnpair = connection }
                        }
                    }
                    Button {
                        scanning = true
                    } label: {
                        Label("Pair another Mac", systemImage: "qrcode.viewfinder")
                    }
                }
                Section {
                    LabeledContent("Transport", value: "WireGuard (in app)")
                    LabeledContent("This iPhone's key", value: model.identityFingerprint)
                        .monospacedDigit()
                } header: {
                    Text("Security")
                } footer: {
                    Text("Traffic to your Mac is end-to-end encrypted with WireGuard inside this app. No VPN profile is installed.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .confirmationDialog("Unpair this Mac?", isPresented: Binding(get: { confirmUnpair != nil }, set: { if !$0 { confirmUnpair = nil } }),
                                presenting: confirmUnpair) { connection in
                Button("Unpair \(connection.host.hostName)", role: .destructive) { model.unpair(connection) }
            } message: { _ in
                Text("You'll need to scan a new code on the Mac to connect again.")
            }
            .fullScreenCover(isPresented: $scanning) {
                ScannerView { link in
                    scanning = false
                    dismiss()
                    model.pair(link: link)
                }
            }
        }
    }

    private func detail(_ connection: HostConnection) -> String {
        switch connection.phase {
        case .connected:
            return "Connected via \(connection.endpoint ?? "WireGuard")"
        case .connecting:
            return "Connecting…"
        case .failed(let message):
            return message
        case .idle:
            return "Paired \(connection.host.pairedAt.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}
