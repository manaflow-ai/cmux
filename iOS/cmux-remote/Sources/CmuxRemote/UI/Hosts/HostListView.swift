import SwiftUI
import CmuxKit

struct HostListView: View {
    @EnvironmentObject var hostStore: HostStore
    @EnvironmentObject var connection: ConnectionManager
    @State private var showAdd = false
    @State private var editingHost: CmuxHost?

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.string("hosts.section.saved_macs", defaultValue: "Saved Macs")) {
                    ForEach(hostStore.hosts) { host in
                        Button {
                            Task {
                                hostStore.setActive(host.id)
                                await connection.connect(to: host)
                            }
                        } label: {
                            HostRow(host: host, isActive: host.id == hostStore.activeHostID)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                hostStore.remove(host.id)
                            } label: {
                                Label(L10n.string("common.delete", defaultValue: "Delete"), systemImage: "trash")
                            }
                            Button {
                                editingHost = host
                            } label: {
                                Label(L10n.string("common.edit", defaultValue: "Edit"), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("hosts.title", defaultValue: "Hosts"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Label(L10n.string("common.add", defaultValue: "Add"), systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) { HostAddView() }
            .sheet(item: $editingHost) { host in HostAddView(host: host) }
        }
    }
}

private struct HostRow: View {
    let host: CmuxHost
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(isActive ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(host.label).font(.headline)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if host.serverFingerprintPin != nil {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "lock.open")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
