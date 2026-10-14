#if os(iOS)
import CNBackend
import CNCore
import CNDesign
import SwiftUI
import UIKit

/// Host CLI steps plus the pairing-code field. Used by onboarding ("Connect
/// your Mac") and by Settings > Macs > Add Mac.
public struct PairMacForm: View {
    let hosts: HostsStore
    let apiBase: String
    let onPaired: (HostRecord) -> Void
    @State private var code = ""
    @State private var isPairing = false
    @State private var error: String?
    @FocusState private var codeFocused: Bool

    public init(hosts: HostsStore, apiBase: String, onPaired: @escaping (HostRecord) -> Void) {
        self.hosts = hosts
        self.apiBase = apiBase
        self.onPaired = onPaired
    }

    public static func commands(apiBase: String) -> [String] {
        ["cmux-next-host login --api \(apiBase)", "cmux-next-host run"]
    }

    public var body: some View {
        Section {
            ForEach(Array(Self.commands(apiBase: apiBase).enumerated()), id: \.offset) { index, command in
                CommandRow(step: index + 1, command: command)
            }
        } header: {
            Text("On your Mac")
        } footer: {
            Text("`login` prints a pairing code. Keep `run` going so this iPhone can reach the Mac.")
        }

        Section {
            TextField("Pairing code", text: $code)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .submitLabel(.go)
                .onSubmit { Task { await pair() } }
                .accessibilityIdentifier("pair.code")
            Button {
                Task { await pair() }
            } label: {
                HStack {
                    Text("Pair Mac")
                    Spacer()
                    if isPairing { ProgressView() }
                }
            }
            .disabled(normalized.isEmpty || isPairing)
            .accessibilityIdentifier("pair.submit")
        } header: {
            Text("Pairing code")
        } footer: {
            if let error {
                Text(error).foregroundStyle(.cn(\.danger))
            }
        }
    }

    private var normalized: String { code.uppercased().filter { !$0.isWhitespace } }

    private func pair() async {
        guard !normalized.isEmpty, !isPairing else { return }
        isPairing = true
        error = nil
        defer { isPairing = false }
        do {
            let host = try await hosts.approvePairing(userCode: normalized)
            code = ""
            onPaired(host)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct CommandRow: View {
    let step: Int
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(step)")
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(.cn(\.textSecondary))
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .tint(.cn(\.icon))
            .accessibilityLabel("Copy command")
        }
    }
}

/// Settings > Macs > Add Mac.
struct AddMacSheet: View {
    let hosts: HostsStore
    let apiBase: String
    let onPaired: (HostRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PairMacForm(hosts: hosts, apiBase: apiBase) { host in
                    onPaired(host)
                    dismiss()
                }
            }
            .navigationTitle("Add Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#endif
