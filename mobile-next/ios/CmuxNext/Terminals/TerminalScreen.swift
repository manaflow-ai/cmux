import CNMProtocol
import SwiftUI
import UIKit

struct TerminalRoute: Hashable {
    let host: String
    let terminal: UInt32
}

/// Terminals on all connected Macs.
struct TerminalsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell
    @State private var creating = false

    var body: some View {
        @Bindable var shell = shell
        NavigationStack(path: $shell.terminalsPath) {
            List {
                ForEach(model.hosts) { host in
                    Section {
                        ForEach(host.terminals.sorted { $0.id > $1.id }) { terminal in
                            NavigationLink(value: TerminalRoute(host: host.id, terminal: terminal.id)) {
                                HStack(spacing: 12) {
                                    Image(systemName: "apple.terminal")
                                        .font(.system(size: 18))
                                        .foregroundStyle(terminal.running ? .primary : .tertiary)
                                        .frame(width: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(terminal.title).font(.system(size: 17)).lineLimit(1)
                                        Text((terminal.cwd as NSString).abbreviatingWithTildeInPath)
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if !terminal.running {
                                        Text("Exited").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { host.closeTerminal(terminal.id) } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                            }
                        }
                        Button {
                            newTerminal(on: host)
                        } label: {
                            Label("New terminal", systemImage: "plus")
                        }
                        .disabled(!host.status.isConnected || creating)
                        .accessibilityIdentifier("terminals.new")
                    } header: {
                        HStack {
                            Text(host.name)
                            Spacer()
                            ConnectionBadge(status: host.status)
                        }
                    }
                }
            }
            .overlay {
                if model.hosts.isEmpty, model.hostsLoaded { NoMacView() }
            }
            .navigationTitle("Terminals")
            .toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
            .navigationDestination(for: TerminalRoute.self) { route in
                if let host = model.host(route.host) {
                    TerminalScreen(host: host, terminalID: route.terminal)
                }
            }
        }
    }

    private func newTerminal(on host: HostConnection) {
        creating = true
        Task {
            defer { creating = false }
            if let info = try? await host.createTerminal(cwd: nil, cols: 80, rows: 30) {
                shell.terminalsPath.append(TerminalRoute(host: host.id, terminal: info.id))
            }
        }
    }
}

/// Opens a fresh terminal in a folder, full screen (from an agent chat).
struct TerminalLauncher: View {
    let host: HostConnection
    let cwd: String?
    @Environment(\.dismiss) private var dismiss
    @State private var terminalID: UInt32?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let terminalID {
                    TerminalScreen(host: host, terminalID: terminalID)
                } else if let error {
                    ContentUnavailableView("Couldn't open a terminal", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .task {
            do {
                terminalID = try await host.createTerminal(cwd: cwd, cols: 80, rows: 30).id
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct TerminalScreen: View {
    let host: HostConnection
    let terminalID: UInt32
    @State private var title: String?
    @State private var controlArmed = false
    @State private var controller = TerminalController()
    @State private var replacementID: UInt32?

    private var info: TerminalInfo? { host.terminals.first { $0.id == (replacementID ?? terminalID) } }
    @Environment(\.dismiss) private var dismiss

    /// The shell is gone: it exited, or the Mac's host restarted (shells end
    /// with it), so there is nothing to type into any more.
    private var ended: String? {
        guard host.status.isConnected else { return nil }
        guard let info else { return String(localized: "This terminal ended when cmux Host restarted on \(host.name).") }
        guard !info.running else { return nil }
        if let code = info.exitCode, code != 0 { return String(localized: "The shell exited with code \(code).") }
        return String(localized: "The shell exited.")
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurface(controller: controller)
                .id(ObjectIdentifier(controller))
                .ignoresSafeArea(.container, edges: .bottom)
            if controller.keyboardShown {
                KeyBar(controlArmed: controlArmed) { key in controller.press(key) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(hex: 0x1E1E1E))
        .overlay(alignment: .bottom) {
            if let ended {
                VStack(spacing: 12) {
                    Text(ended).font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    Button {
                        Task {
                            if let fresh = try? await host.createTerminal(cwd: info?.cwd, cols: 80, rows: 30) {
                                controller.stop()
                                controller = TerminalController()
                                controller.view.focusWhenShown = true
                                controller.onTitle = { title = $0 }
                                controller.onControl = { controlArmed = $0 }
                                replacementID = fresh.id
                                controller.start(host: host, terminal: fresh.id)
                            }
                        }
                    } label: {
                        Label("New terminal", systemImage: "plus").font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 18).frame(height: 44)
                            .background(.white, in: .capsule).foregroundStyle(.black)
                    }
                    .accessibilityIdentifier("terminal.new-after-end")
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial.opacity(0.9), in: .rect(cornerRadius: 22, style: .continuous))
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .environment(\.colorScheme, .dark)
            }
        }
        .animation(.snappy, value: ended)
        .navigationTitle(title ?? info?.title ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(hex: 0x1E1E1E), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    controller.toggleKeyboard()
                } label: {
                    Image(systemName: controller.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityIdentifier("terminal.keyboard")
            }
        }
        .onAppear {
            controller.onTitle = { title = $0 }
            controller.onControl = { controlArmed = $0 }
            controller.start(host: host, terminal: replacementID ?? terminalID)
        }
        .onDisappear { controller.stop() }
        .animation(.snappy(duration: 0.2), value: controller.keyboardShown)
    }
}

/// Owns the Ghostty view and wires it to the Mac's pty.
@MainActor
@Observable
final class TerminalController {
    let view = GhosttyTerminalView()
    var keyboardShown = false
    @ObservationIgnored var onTitle: ((String) -> Void)?
    @ObservationIgnored var onControl: ((Bool) -> Void)?
    @ObservationIgnored private weak var host: HostConnection?
    @ObservationIgnored private var terminal: UInt32 = 0
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start(host: HostConnection, terminal: UInt32) {
        self.host = host
        self.terminal = terminal
        view.onInput = { [weak host] data in host?.sendTerminalInput(terminal, data) }
        view.onTitle = { [weak self] title in self?.onTitle?(title) }
        view.onControlChanged = { [weak self] armed in self?.onControl?(armed) }
        view.onResize = { [weak self, weak host] cols, rows in
            guard let self, let host else { return }
            if self.attached { host.resizeTerminal(terminal, cols: cols, rows: rows) } else { self.attach(cols: cols, rows: rows) }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardShown = self?.view.isFirstResponder ?? false }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardShown = false }
        })
        if view.window != nil {
            let size = view.gridSize
            attach(cols: size.cols, rows: size.rows)
        }
    }

    private func attach(cols: Int, rows: Int) {
        guard !attached, let host else { return }
        attached = true
        Task {
            try? await host.attachTerminal(terminal, cols: cols, rows: rows) { [weak self] frame in
                guard let self else { return }
                switch frame.kind {
                case .output: self.view.feed(frame.payload)
                case .replayBegin: self.view.feed(Data("\u{1B}c".utf8))
                default: break
                }
            }
        }
    }

    func stop() {
        host?.detachTerminal(terminal)
        view.free()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    func toggleKeyboard() {
        if view.isFirstResponder { view.resignFirstResponder() } else { view.becomeFirstResponder() }
    }

    func press(_ key: KeyBar.Key) {
        switch key {
        case .escape: view.send(Data([0x1B]))
        case .tab: view.send(Data([0x09]))
        case .control: view.controlArmed.toggle()
        case .up: view.send(Data("\u{1B}[A".utf8))
        case .down: view.send(Data("\u{1B}[B".utf8))
        case .left: view.send(Data("\u{1B}[D".utf8))
        case .right: view.send(Data("\u{1B}[C".utf8))
        case .text(let text): view.insertText(text)
        case .paste: if let text = UIPasteboard.general.string { view.paste(text: text) }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
    }
}

struct TerminalSurface: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> GhosttyTerminalView { controller.view }
    func updateUIView(_ uiView: GhosttyTerminalView, context: Context) {}
}

/// Keys a phone keyboard lacks, above the keyboard (like T3 and Blink).
struct KeyBar: View {
    enum Key: Hashable {
        case escape, tab, control, up, down, left, right, paste
        case text(String)
    }

    let controlArmed: Bool
    let press: (Key) -> Void

    private let keys: [(Key, String)] = [
        (.escape, "esc"), (.tab, "tab"), (.control, "ctrl"),
        (.left, "←"), (.up, "↑"), (.down, "↓"), (.right, "→"),
        (.text("|"), "|"), (.text("~"), "~"), (.text("/"), "/"), (.text("-"), "-"), (.paste, "paste"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.1) { key, label in
                    Button { press(key) } label: {
                        Text(label)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(key == .control && controlArmed ? .black : .white)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 40, minHeight: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(key == .control && controlArmed ? Color.white : Color.white.opacity(0.14))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(hex: 0x2A2A2A))
    }
}

struct ConnectionBadge: View {
    let status: HostConnection.Status

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    private var color: Color {
        switch status {
        case .connected: CmuxTheme.success
        case .connecting: .orange
        case .failed: CmuxTheme.danger
        case .offline: Color(.tertiaryLabel)
        }
    }

    private var label: String {
        switch status {
        case .connected(let route): route.hasPrefix("relay") ? String(localized: "Connected · relay") : String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .failed: String(localized: "Can't connect")
        case .offline: String(localized: "Offline")
        }
    }
}
