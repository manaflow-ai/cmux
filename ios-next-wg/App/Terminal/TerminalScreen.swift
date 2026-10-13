import CmuxMobileSSH
import CmuxiOSTerminal
import SwiftUI
import UIKit

/// One remote terminal, drawn by Ghostty in mirror mode.
struct TerminalScreen: View {
    let connection: HostConnection
    let surface: Int
    @State private var session = TerminalSession()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TerminalHost(session: session)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { session.toggleKeyboard() } label: { Image(systemName: "keyboard") }
                        .accessibilityLabel("Keyboard")
                }
            }
            .overlay(alignment: .top) {
                if let banner = session.banner {
                    Text(banner)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: session.banner)
            .task(id: connection.phase == .connected) {
                if connection.phase == .connected, let control = connection.control {
                    session.start(control: control, surface: surface)
                }
            }
            .onDisappear { session.stop() }
    }

    private var title: String {
        connection.terminals.first { $0.surface == surface }?.displayTitle ?? String(localized: "Terminal")
    }

    /// A grid guess for a new terminal before its view exists: the phone's
    /// width at the default 13 pt cell (about 7.8 x 16 pt).
    @MainActor static func estimatedGrid() -> (cols: Int, rows: Int) {
        let bounds = UIScreen.main.bounds
        return (max(20, Int(bounds.width / 7.8)), max(10, Int((bounds.height - 140) / 16)))
    }
}

/// Owns the attachment for one screen: feeds the replay and output into
/// Ghostty, sends typed bytes, and follows the view's size.
@MainActor @Observable
final class TerminalSession {
    private(set) var banner: String?
    @ObservationIgnored weak var view: GhosttyTerminalView?
    @ObservationIgnored private var control: CmuxTUIControl?
    @ObservationIgnored private var surface: Int?
    @ObservationIgnored private var attachment: CmuxTUIAttachment?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var lastGrid: (cols: Int, rows: Int)?

    func start(control: CmuxTUIControl, surface: Int) {
        guard self.control !== control || attachment == nil else { return }
        stop()
        self.control = control
        self.surface = surface
        attachIfReady()
    }

    /// Called when the view has a size; attaches at the grid that fits it.
    func viewReady() {
        if attachment == nil { attachIfReady() } else { resizeIfNeeded() }
    }

    private func attachIfReady() {
        guard pump == nil, let control, let surface, let view else { return }
        let grid = view.fittingGrid
        guard grid.cols > 0, grid.rows > 0 else { return }
        lastGrid = grid
        banner = nil
        pump = Task { [weak self] in
            do {
                let attachment = try await control.attach(surface: surface, cols: grid.cols, rows: grid.rows)
                self?.attachment = attachment
                for await event in attachment.events {
                    self?.apply(event)
                }
                self?.banner = String(localized: "Disconnected")
            } catch {
                self?.banner = HostConnection.describe(error)
            }
            self?.pump = nil
            self?.attachment = nil
        }
        view.onInput = { [weak self] data in self?.send(data) }
        view.becomeFirstResponder()
    }

    private func apply(_ event: CmuxTUIAttachEvent) {
        guard let view else { return }
        switch event {
        case .vtState(let data, let cols, let rows), .resized(let cols, let rows, let data):
            generation += 1
            let generation = generation
            view.enqueueOutput { surface in
                surface.setGrid(cols: cols, rows: rows, generation: generation)
                // RIS: a clean terminal before the replay draws the screen.
                surface.feed(Data([0x1B, 0x63]))
                surface.feed(data)
            }
        case .output(let data):
            view.enqueueOutput { $0.feed(data) }
        case .exited:
            banner = String(localized: "The program exited")
        case .disconnected:
            banner = String(localized: "Disconnected")
        case .colors:
            break
        }
    }

    private func send(_ data: Data) {
        guard let attachment else { return }
        Task { try? await attachment.write(data) }
    }

    private func resizeIfNeeded() {
        guard let view, let attachment else { return }
        let grid = view.fittingGrid
        guard grid.cols > 0, grid.rows > 0, lastGrid.map({ $0 != grid }) ?? true else { return }
        lastGrid = grid
        Task { _ = try? await attachment.resize(cols: grid.cols, rows: grid.rows) }
    }

    func toggleKeyboard() {
        guard let view else { return }
        if view.isFirstResponder { view.resignFirstResponder() } else { view.becomeFirstResponder() }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        let attachment = attachment
        self.attachment = nil
        Task { try? await attachment?.detach() }
    }
}

/// Hosts the Ghostty view and reports size changes to the session.
struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> SizeReportingContainer {
        let container = SizeReportingContainer()
        let terminal = GhosttyTerminalView(frame: .zero)
        container.terminal = terminal
        session.view = terminal
        container.onLayout = { [weak session] in session?.viewReady() }
        return container
    }

    func updateUIView(_ uiView: SizeReportingContainer, context: Context) {}
}

final class SizeReportingContainer: UIView {
    var onLayout: (() -> Void)?
    var terminal: GhosttyTerminalView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let terminal else { return }
            terminal.translatesAutoresizingMaskIntoConstraints = false
            addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminal.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            ])
        }
    }
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let terminal, terminal.bounds.size != lastSize, terminal.bounds.width > 0 else { return }
        lastSize = terminal.bounds.size
        // The terminal sizes its surface in its own layout pass; report after it.
        terminal.layoutIfNeeded()
        onLayout?()
    }
}
