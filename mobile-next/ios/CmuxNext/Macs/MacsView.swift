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
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: paired == nil ? "laptopcomputer.and.iphone" : "checkmark.circle.fill")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(paired == nil ? Color.primary : CmuxTheme.success)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.top, 30)
                if let paired {
                    Text("\(paired.name) is paired").font(.title2.weight(.semibold))
                    Text("It connects as soon as it's online.").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        Text("Add a Mac").font(.title2.weight(.semibold))
                        Text("On your Mac, run **cnm-host pair** and enter the code it shows.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    TextField("ABC 123", text: $code)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .frame(height: 64)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
                        .onChange(of: code) { _, value in
                            let cleaned = String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                            let spaced = cleaned.count > 3 ? cleaned.prefix(3) + " " + cleaned.dropFirst(3) : Substring(cleaned)
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
                    enabled: paired != nil || code.filter { $0 != " " }.count == 6,
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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { paired = host }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = (error as? BackendError)?.code == "invalid_pairing_code"
                    ? String(localized: "That code didn't match. Check the Mac and try again.")
                    : error.localizedDescription
            }
        }
    }
}
