#if os(macOS)
import ServiceManagement
import SwiftUI

public struct HostMenu: View {
    let runtime: HostRuntime
    public init(runtime: HostRuntime) { self.runtime = runtime }
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("cmux for iPhone").font(.headline)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            switch runtime.phase {
            case .pairing(let code):
                VStack(alignment: .leading, spacing: 6) {
                    Text("In cmux on your iPhone, open the menu → Macs → Add a Mac and enter:")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(code.count == 8 ? code.prefix(4) + "-" + code.dropFirst(4) : Substring(code))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.quaternary, in: .rect(cornerRadius: 10))
                }
            case .approving(_, let email):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair with \(email)?").font(.headline)
                    Text("This account will be able to open terminals and run agents on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Reject") { runtime.answerApproval(false) }
                        Spacer()
                        Button("Pair") { runtime.answerApproval(true) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.red)
            default:
                EmptyView()
            }
            Divider()
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            HStack {
                if runtime.identity != nil {
                    Button("Unpair") { Task { await runtime.unpair(); runtime.start() } }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
        .task { if runtime.phase == .idle { runtime.start() } }
    }

    private var statusLine: String {
        switch runtime.phase {
        case .idle: return "Starting…"
        case .pairing: return "Not paired yet"
        case .approving: return "Waiting for you to approve"
        case .failed: return "Can't reach the cmux service"
        case .serving:
            let account = runtime.identity?.userEmail ?? "your account"
            if runtime.phones > 0 { return "\(runtime.phones) iPhone connected · \(account)" }
            return runtime.signalingUp ? "Ready · \(account)" : "Connecting…"
        }
    }
}

public struct PairingWindow: View {
    let runtime: HostRuntime
    public init(runtime: HostRuntime) { self.runtime = runtime }
    @Environment(\.dismissWindow) private var dismissWindow

    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 44, weight: .light))
            Text("Pair this Mac with cmux on your iPhone").font(.title2.weight(.semibold))
            switch runtime.phase {
            case .pairing(let code):
                Text("On your iPhone, open the menu → Macs → Add a Mac and enter this code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(code.count == 8 ? code.prefix(4) + "-" + code.dropFirst(4) : Substring(code))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.quaternary, in: .rect(cornerRadius: 14))
                Text("The code changes every 10 minutes.").font(.caption).foregroundStyle(.tertiary)
            case .approving(_, let email):
                Text("**\(email)** wants to pair with this Mac. It will be able to open terminals and run agents here.")
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Reject") { runtime.answerApproval(false) }
                        .controlSize(.large)
                    Button("Pair") { runtime.answerApproval(true) }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            case .serving:
                Label("Paired with \(runtime.identity?.userEmail ?? "your account")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .idle:
                ProgressView()
            }
        }
        .padding(32)
        .frame(width: 460)
        .task { if runtime.phase == .idle { runtime.start() } }
        .onChange(of: runtime.phase) { _, phase in
            if case .serving = phase {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    dismissWindow(id: "pairing")
                }
            }
        }
    }
}


#endif
