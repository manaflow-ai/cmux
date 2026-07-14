import AppKit
import CmuxLiteCore
import GhosttyTerminal

@MainActor
final class CmuxTerminalHostViewController: NSViewController, TerminalSurfaceGridResizeDelegate {
    private let frontend: CmuxFrontendSession
    private var terminalView: TerminalView?
    private var terminalSession: InMemoryTerminalSession?
    private var terminalController: TerminalController?
    private var expectedColumns: UInt16?
    private var expectedRows: UInt16?
    private var pendingChunks: [Data] = []
    private var ready = false
    private var colors: CmuxTerminalColors?

    init(frontend: CmuxFrontendSession) {
        self.frontend = frontend
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        self.view = view
    }

    func consume(_ event: CmuxAttachEvent) {
        switch event {
        case let .initialReplay(surface: _, columns, rows, bytes, colors):
            self.colors = colors
            replaceTerminal(columns: columns, rows: rows, replay: bytes)
        case let .resizedReplay(surface: _, columns, rows, bytes):
            replaceTerminal(columns: columns, rows: rows, replay: bytes)
        case let .output(surface: _, bytes):
            if ready {
                terminalSession?.receive(bytes)
            } else {
                pendingChunks.append(bytes)
            }
        case let .colorsChanged(surface: _, colors):
            self.colors = colors
            _ = terminalController?.setTerminalConfiguration(colors.ghosttyConfiguration)
        case .detached, .other:
            break
        }
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        guard size.columns > 0, size.rows > 0 else { return }

        if size.columns == expectedColumns, size.rows == expectedRows, !ready {
            ready = true
            let chunks = pendingChunks
            pendingChunks.removeAll(keepingCapacity: true)
            for chunk in chunks {
                terminalSession?.receive(chunk)
            }
        }
    }

    private func replaceTerminal(columns: UInt16, rows: UInt16, replay: Data) {
        terminalView?.removeFromSuperview()
        terminalView = nil
        terminalSession = nil
        terminalController = nil

        expectedColumns = columns
        expectedRows = rows
        pendingChunks = [replay]
        ready = false

        let frontend = frontend
        let session = InMemoryTerminalSession(
            write: { data in
                Task { await frontend.sendInput(data) }
            },
            resize: { viewport in
                Task {
                    await frontend.scheduleResize(
                        columns: viewport.columns,
                        rows: viewport.rows
                    )
                }
            }
        )
        let controller = TerminalController(
            terminalConfiguration: colors?.ghosttyConfiguration ?? TerminalConfiguration()
        )
        let terminal = TerminalView(frame: view.bounds)
        terminal.delegate = self
        terminal.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: 13
        )
        terminal.controller = controller
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityLabel(
            String(
                localized: "terminal.accessibility_label",
                defaultValue: "Remote terminal"
            )
        )
        terminal.translatesAutoresizingMaskIntoConstraints = false

        // Install ownership before attaching the view because surface creation can synchronously resize.
        terminalSession = session
        terminalController = controller
        terminalView = terminal
        view.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: view.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.window?.makeFirstResponder(terminal)
    }
}
