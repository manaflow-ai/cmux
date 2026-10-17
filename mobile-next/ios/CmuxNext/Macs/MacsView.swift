import CNMBackend
import SwiftUI

struct MacsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.hosts) { host in
                        HStack(spacing: 14) {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 22))
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(host.name).font(.system(size: 17, weight: .medium))
                                ConnectionBadge(status: host.status)
                                if case .failed(let reason) = host.status {
                                    Text(reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                            Spacer()
                            if case .failed = host.status {
                                Button("Retry") { host.connect() }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await model.removeHost(host) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("macs.row.\(host.id)")
                    }
                    Button {
                        shell.showAddMac = true
                    } label: {
                        Label("Add a Mac", systemImage: "plus")
                    }
                    .accessibilityIdentifier("macs.add")
                } footer: {
                    Text("Your iPhone connects to each Mac directly, peer to peer, and through a relay when it has to.")
                }
            }
            .navigationTitle("Macs")
            .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
            .refreshable { await model.reloadHosts() }
        }
    }
}

/// Enter the code `cnm-host pair` shows on the Mac.
struct AddMacView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var paired: BackendHost?
    /// Claimed; waiting for the Mac's owner to approve this account.
    @State private var awaiting: BackendHost?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: paired != nil ? "checkmark.circle.fill" : awaiting != nil ? "hand.raised" : "laptopcomputer.and.iphone")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(paired == nil ? Color.primary : CmuxTheme.success)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.top, 30)
                if let paired {
                    Text("\(paired.name) is paired").font(.title2.weight(.semibold))
                    Text("It connects as soon as it's online.").foregroundStyle(.secondary)
                } else if let awaiting {
                    Text("Approve on \(awaiting.name)").font(.title2.weight(.semibold))
                    Text("Your Mac is asking whether to pair with \(model.user?.email ?? "your account"). Click Pair there.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    ProgressView().padding(.top, 8)
                } else {
                    VStack(spacing: 8) {
                        Text("Add a Mac").font(.title2.weight(.semibold))
                        Text("Open **cmux Host** on your Mac (or run **cnm-host pair**) and enter the code it shows.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    TextField("ABCD-1234", text: $code)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .frame(height: 64)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
                        .onChange(of: code) { _, value in
                            let cleaned = String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                            let spaced = cleaned.count > 4 ? cleaned.prefix(4) + "-" + cleaned.dropFirst(4) : Substring(cleaned)
                            if String(spaced) != value { code = String(spaced) }
                            error = nil
                        }
                        .accessibilityIdentifier("addmac.code")
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(CmuxTheme.danger)
                    }
                }
                Spacer()
                PrimaryActionButton(
                    title: paired == nil ? "Pair" : "Done",
                    enabled: paired != nil || (awaiting == nil && code.filter { $0.isLetter || $0.isNumber }.count == 8),
                    busy: busy
                ) {
                    if paired != nil { dismiss() } else { pair() }
                }
                .accessibilityIdentifier("addmac.pair")
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }

    private func pair() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let host = try await model.pair(code: code)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { awaiting = host }
                // The Mac shows up in the account once its owner approves.
                for _ in 0..<150 {
                    await model.reloadHosts()
                    if model.hosts.contains(where: { $0.id == host.id }) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            awaiting = nil
                            paired = host
                        }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                awaiting = nil
                error = String(localized: "The Mac didn't approve in time. Try again.")
            } catch {
                switch (error as? BackendError)?.code {
                case "invalid_pairing_code": self.error = String(localized: "That code didn't match. Check the Mac and try again.")
                case "rate_limited": self.error = String(localized: "Too many tries. Wait a few minutes and try again.")
                default: self.error = error.localizedDescription
                }
            }
        }
    }
}
