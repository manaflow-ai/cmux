import AppKit
import CmuxLiteCore
import GhosttyTerminal

@MainActor
final class CmuxTerminalHostViewController: NSViewController, TerminalSurfaceGridResizeDelegate {
    private let frontend: CmuxFrontendSession
    private let ghosttyViewConfiguration: CmuxGhosttyViewConfiguration
    private let ghosttyConfigPath: String?
    private var terminalView: TerminalView?
    private var terminalSession: InMemoryTerminalSession?
    private var terminalController: TerminalController?
    private var pendingChunks: [Data] = []
    private var ready = false
    private var colors: CmuxTerminalColors?
    private var attachedSurface: UInt64?
    private var applyingReplay = false
    private var hasAppliedReplay = false
    private var pendingInitialClaim = false
    private var lastMeasurement: CmuxTerminalMeasurement?
    private var active = false

    init(
        frontend: CmuxFrontendSession,
        ghosttyViewConfiguration: CmuxGhosttyViewConfiguration,
        ghosttyConfigPath: String?
    ) {
        self.frontend = frontend
        self.ghosttyViewConfiguration = ghosttyViewConfiguration
        self.ghosttyConfigPath = ghosttyConfigPath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = CmuxPalette.tui.background.cgColor
        self.view = view
    }

    func consume(_ event: CmuxAttachEvent) {
        switch event {
        case let .initialReplay(surface, columns: _, rows: _, bytes, colors):
            self.colors = colors
            if attachedSurface != surface {
                replaceTerminal(for: surface)
            } else {
                _ = terminalController?.setTerminalConfiguration(
                    effectiveTerminalConfiguration
                )
            }
            applyReplay(bytes, claimAfterReplay: true)
        case let .resizedReplay(surface, columns: _, rows: _, bytes):
            guard attachedSurface == surface else { return }
            applyReplay(bytes, claimAfterReplay: false)
        case let .output(surface, bytes):
            guard attachedSurface == surface else { return }
            if ready {
                terminalSession?.receive(bytes)
            } else {
                pendingChunks.append(bytes)
            }
        case let .colorsChanged(surface, colors):
            guard surface == nil || surface == attachedSurface else { return }
            self.colors = colors
            _ = terminalController?.setTerminalConfiguration(effectiveTerminalConfiguration)
        case let .detached(surface):
            guard attachedSurface == surface else { return }
        case .other:
            break
        }
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active {
            focusTerminal()
        }
    }

    func focusTerminal() {
        guard let terminalView, let window = view.window else { return }
        window.makeFirstResponder(terminalView)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        guard let measurement = measurement(for: size) else { return }
        let containerChanged = lastMeasurement.map {
            $0.widthPixels != measurement.widthPixels
                || $0.heightPixels != measurement.heightPixels
        } ?? false
        lastMeasurement = measurement

        if !ready {
            ready = true
            let chunks = pendingChunks
            pendingChunks.removeAll(keepingCapacity: true)
            applyingReplay = true
            for chunk in chunks {
                terminalSession?.receive(chunk)
            }
            applyingReplay = false
        }

        let claim = pendingInitialClaim
            || (hasAppliedReplay && !applyingReplay && containerChanged)
        if pendingInitialClaim {
            pendingInitialClaim = false
        }
        submit(measurement, claim: claim && !applyingReplay)
    }

    private func replaceTerminal(for surface: UInt64) {
        terminalView?.removeFromSuperview()
        terminalView = nil
        terminalSession = nil
        terminalController = nil

        attachedSurface = surface
        pendingChunks.removeAll(keepingCapacity: true)
        ready = false
        applyingReplay = false
        hasAppliedReplay = false
        pendingInitialClaim = false
        lastMeasurement = nil

        let frontend = frontend
        let session = InMemoryTerminalSession(
            write: { data in
                Task { await frontend.sendInput(data, surface: surface) }
            },
            // AppTerminalView reports the same metrics through its main-actor
            // delegate. Keeping one path lets replay reconstruction suppress
            // resize echoes while real container changes still claim sizing.
            resize: { _ in }
        )
        let configSource: TerminalController.ConfigSource = if let ghosttyConfigPath {
            .file(ghosttyConfigPath)
        } else {
            .none
        }
        let controller = TerminalController(
            configSource: configSource,
            theme: TerminalTheme(),
            terminalConfiguration: effectiveTerminalConfiguration
        )
        let terminal = TerminalView(frame: view.bounds)
        terminal.delegate = self
        terminal.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: ghosttyViewConfiguration.fontSize
        )
        terminal.controller = controller
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityLabel(
            String(
                localized: "terminal.accessibility_label",
                defaultValue: "Remote terminal",
                bundle: .module
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
        if active {
            view.window?.makeFirstResponder(terminal)
        }
    }

    private var effectiveTerminalConfiguration: TerminalConfiguration {
        let base = ghosttyViewConfiguration.ghosttyConfiguration
        return colors?.ghosttyConfiguration(startingFrom: base) ?? base
    }

    private func applyReplay(_ replay: Data, claimAfterReplay: Bool) {
        guard terminalSession != nil else { return }
        pendingInitialClaim = pendingInitialClaim || claimAfterReplay
        hasAppliedReplay = true

        guard ready else {
            pendingChunks.append(replay)
            return
        }

        applyingReplay = true
        terminalView?.fitToSize()
        terminalSession?.receive(replay)
        applyingReplay = false

        if claimAfterReplay, let lastMeasurement {
            pendingInitialClaim = false
            submit(lastMeasurement, claim: true)
        }
    }

    private func measurement(for size: TerminalGridMetrics) -> CmuxTerminalMeasurement? {
        guard let terminalView,
              size.cellWidthPixels > 0,
              size.cellHeightPixels > 0,
              terminalView.bounds.width > 0,
              terminalView.bounds.height > 0,
              abs(terminalView.frame.width - view.bounds.width) < 0.5,
              abs(terminalView.frame.height - view.bounds.height) < 0.5
        else { return nil }

        let backingBounds = terminalView.convertToBacking(terminalView.bounds)
        return CmuxTerminalMeasurement(
            widthPixels: backingBounds.width,
            heightPixels: backingBounds.height,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        )
    }

    private func submit(_ measurement: CmuxTerminalMeasurement, claim: Bool) {
        guard let attachedSurface else { return }
        let frontend = frontend
        Task {
            if claim {
                await frontend.scheduleResize(for: measurement, surface: attachedSurface)
            } else {
                await frontend.recordTerminalMeasurement(measurement, surface: attachedSurface)
            }
        }
    }
}
