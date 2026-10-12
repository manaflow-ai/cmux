import CNMBackend
import CNMHost
import CNMHostRuntime
import ServiceManagement
import SwiftUI

/// Menu bar app: pairs this Mac with the iPhone app and keeps it reachable.
@main
struct CmuxNextHostApp: App {
    @State private var runtime = HostRuntime(
        environment: HostEnvironment(),
        backend: BackendClient(),
        name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    )

    var body: some Scene {
        MenuBarExtra {
            HostMenu(runtime: runtime)
        } label: {
            Image(systemName: runtime.phones > 0 ? "iphone.radiowaves.left.and.right" : "iphone")
        }
        .menuBarExtraStyle(.window)
    }
}

struct HostMenu: View {
    let runtime: HostRuntime
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
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
                    Button("Unpair") { runtime.unpair(); runtime.start() }
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
