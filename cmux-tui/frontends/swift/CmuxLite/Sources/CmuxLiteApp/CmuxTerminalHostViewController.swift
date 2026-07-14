import AppKit
import CmuxLiteCore
import GhosttyTerminal
import QuartzCore

@MainActor
final class CmuxTerminalHostViewController: NSViewController,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceTitleDelegate
{
    private let frontend: CmuxFrontendSession
    private let ghosttyViewConfiguration: CmuxGhosttyViewConfiguration
    private var terminalView: TerminalView?
    private var terminalSession: InMemoryTerminalSession?
    private var terminalController: TerminalController?
    private var pendingChunks: [CmuxTerminalChunk] = []
    private var activeChunk: CmuxTerminalChunk?
    private var activeSteps: ArraySlice<CmuxTerminalIngestionStep> = []
    private var waitingBarrierTitle: String?
    private var nextBarrierID: UInt64 = 1
    private var drainingChunks = false
    private var ready = false
    private var colors: CmuxTerminalColors?
    private var attachedSurface: UInt64?
    private var applyingReplay = false
    private var hasAppliedReplay = false
    private var pendingInitialClaim = false
    private var lastMeasurement: CmuxTerminalMeasurement?
    private var lastGridMetrics: TerminalGridMetrics?
    private var sharedGrid: CmuxSurfaceSize?
    private var mirrorGrid: CmuxSurfaceSize?
    private var waitingForInitialOutput = true
    private var initialPresentationTask: Task<Void, Never>?
    private var lastRenderingDiagnostic: String?
    private var active = false
    private let foreignSizeHint = NSTextField(labelWithString: "")
    private let resizePolicy = CmuxResizePolicy()

    init(
        frontend: CmuxFrontendSession,
        ghosttyViewConfiguration: CmuxGhosttyViewConfiguration
    ) {
        self.frontend = frontend
        self.ghosttyViewConfiguration = ghosttyViewConfiguration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let view = CmuxTerminalGridContainerView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.onLayout = { [weak self] in
            self?.containerDidLayout()
        }
        view.onBackingPropertiesChanged = { [weak self] in
            self?.containerBackingPropertiesDidChange()
        }
        self.view = view
        configureForeignSizeHint()
        updateTerminalBackground()
    }

    func consume(_ event: CmuxAttachEvent) {
        switch event {
        case let .initialReplay(surface, columns, rows, bytes, colors):
            self.colors = colors
            replaceTerminal(for: surface)
            updateTerminalBackground()
            applyReplay(
                bytes,
                grid: CmuxSurfaceSize(cols: columns, rows: rows),
                claimAfterReplay: true
            )
        case let .resizedReplay(surface, columns, rows, bytes):
            guard attachedSurface == surface else { return }
            replaceTerminal(for: surface)
            applyReplay(
                bytes,
                grid: CmuxSurfaceSize(cols: columns, rows: rows),
                claimAfterReplay: false
            )
        case let .output(surface, bytes):
            guard attachedSurface == surface else { return }
            initialPresentationTask?.cancel()
            pendingChunks.append(.output(
                bytes: bytes,
                waitForIngestion: waitingForInitialOutput
            ))
            drainPendingChunks()
        case let .colorsChanged(surface, colors):
            guard surface == nil || surface == attachedSurface else { return }
            self.colors = colors
            _ = terminalController?.setTerminalConfiguration(effectiveTerminalConfiguration)
            updateTerminalBackground()
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
        lastGridMetrics = size
        layoutTerminalGrid()
        updateTerminalMeasurement(using: size)
        verifyRenderingMetrics()
    }

    func terminalDidChangeTitle(_ title: String) {
        guard title == waitingBarrierTitle else { return }
        waitingBarrierTitle = nil
        drainPendingChunks()
    }

    private func updateTerminalMeasurement(using size: TerminalGridMetrics) {
        guard let measurement = measurement(for: size) else { return }
        guard !applyingReplay else {
            updateForeignSizeHint()
            return
        }
        let containerChanged = lastMeasurement != measurement
        lastMeasurement = measurement
        updateForeignSizeHint()

        if !ready {
            ready = true
            drainPendingChunks()
        }

        let claim = !applyingReplay
            && (pendingInitialClaim || (hasAppliedReplay && containerChanged))
        if claim && pendingInitialClaim {
            pendingInitialClaim = false
        }
        submit(measurement, claim: claim)
    }

    private func replaceTerminal(for surface: UInt64) {
        terminalView?.removeFromSuperview()
        terminalView = nil
        terminalSession = nil
        terminalController = nil

        attachedSurface = surface
        pendingChunks.removeAll(keepingCapacity: true)
        activeChunk = nil
        activeSteps = []
        waitingBarrierTitle = nil
        drainingChunks = false
        initialPresentationTask?.cancel()
        initialPresentationTask = nil
        ready = false
        applyingReplay = false
        hasAppliedReplay = false
        pendingInitialClaim = false
        lastMeasurement = nil
        lastGridMetrics = nil
        sharedGrid = nil
        mirrorGrid = nil
        waitingForInitialOutput = true
        lastRenderingDiagnostic = nil

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
        let controller = TerminalController(
            configSource: .none,
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
        terminal.autoresizingMask = []
        terminal.alphaValue = 0

        // Install ownership before attaching the view because surface creation can synchronously resize.
        terminalSession = session
        CmuxStateDump.register(self)
        terminalController = controller
        terminalView = terminal
        view.addSubview(terminal, positioned: .below, relativeTo: foreignSizeHint)
        layoutTerminalGrid()
        if active {
            view.window?.makeFirstResponder(terminal)
        }
    }

    private var effectiveTerminalConfiguration: TerminalConfiguration {
        let base = ghosttyViewConfiguration.ghosttyConfiguration
        return colors?.ghosttyConfiguration(startingFrom: base) ?? base
    }

    private func applyReplay(
        _ replay: Data,
        grid: CmuxSurfaceSize,
        claimAfterReplay: Bool
    ) {
        guard terminalSession != nil else { return }
        pendingInitialClaim = pendingInitialClaim || claimAfterReplay
        hasAppliedReplay = true
        let chunk = CmuxTerminalChunk.replay(
            bytes: replay,
            grid: grid,
            claimAfterReplay: claimAfterReplay
        )
        pendingChunks.append(chunk)
        updateSharedGrid(grid)
        drainPendingChunks()
    }

    private func drainPendingChunks() {
        guard ready, waitingBarrierTitle == nil, !drainingChunks else { return }
        drainingChunks = true
        defer { drainingChunks = false }

        while true {
            if activeSteps.isEmpty {
                if let activeChunk {
                    finishIngesting(activeChunk)
                }
                activeChunk = nil

                guard !pendingChunks.isEmpty else { return }
                let chunk = pendingChunks.removeFirst()
                activeChunk = chunk
                activeSteps = chunk.ingestionSteps[...]
                if chunk.replayGrid != nil {
                    applyingReplay = true
                }
            }

            guard let step = activeSteps.popFirst() else { continue }
            switch step {
            case .awaitCurrentBytes, .awaitReceivedBytes:
                beginParserBarrier()
                return
            case let .sizeForReplay(grid):
                sizeMirror(for: grid)
            case let .receive(bytes):
                terminalSession?.receive(bytes)
            case .fitToView:
                terminalView?.fitToSize()
            case .claimLocalGrid:
                applyingReplay = false
                guard let lastMeasurement else { continue }
                pendingInitialClaim = false
                submit(lastMeasurement, claim: true)
            }
        }
    }

    private func finishIngesting(_ chunk: CmuxTerminalChunk) {
        if chunk.replayGrid != nil {
            applyingReplay = false
            if currentViewport?.hasPresentableInitialOutput == true {
                presentTerminal()
            }
        } else if chunk.waitsForIngestion,
                  currentViewport?.hasPresentableInitialOutput == true
        {
            scheduleInitialPresentation()
        }
    }

    /// Verification-only snapshot for CmuxStateDump (SIGUSR1 harness).
    func verificationState() -> [String: Any]? {
        guard let text = terminalSession?.readViewportText() else { return nil }
        var state: [String: Any] = ["text": text]
        if let surface = attachedSurface { state["surface"] = surface }
        if let grid = sharedGrid {
            state["cols"] = grid.cols
            state["rows"] = grid.rows
        }
        return state
    }

    private var currentViewport: CmuxTerminalViewport? {
        terminalSession?.readViewportText().map(CmuxTerminalViewport.init)
    }

    private func scheduleInitialPresentation() {
        initialPresentationTask?.cancel()
        let surface = attachedSurface
        initialPresentationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let self,
                  self.attachedSurface == surface
            else { return }
            if let surface,
               await self.frontend.refreshStartupReplay(surface: surface)
            {
                return
            }
            self.presentTerminal()
        }
    }

    private func presentTerminal() {
        waitingForInitialOutput = false
        initialPresentationTask?.cancel()
        initialPresentationTask = nil
        terminalView?.alphaValue = 1
        terminalView?.fitToSize()
    }

    private func beginParserBarrier() {
        guard let terminalSession else { return }
        let title = "cmux-lite-replay-barrier-\(nextBarrierID)"
        nextBarrierID &+= 1
        waitingBarrierTitle = title
        terminalSession.receive("\u{1B}]2;\(title)\u{7}")
    }

    private func measurement(for size: TerminalGridMetrics) -> CmuxTerminalMeasurement? {
        guard size.cellWidthPixels > 0,
              size.cellHeightPixels > 0,
              view.bounds.width > 0,
              view.bounds.height > 0
        else { return nil }

        let backingBounds = view.convertToBacking(view.bounds)
        return CmuxTerminalMeasurement(
            widthPixels: backingBounds.width,
            heightPixels: backingBounds.height,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels,
            fittedGrid: terminalView?.frame == view.bounds
                ? CmuxSurfaceSize(cols: size.columns, rows: size.rows)
                : nil
        )
    }

    private func configureForeignSizeHint() {
        let palette = CmuxPalette.tui
        foreignSizeHint.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        foreignSizeHint.textColor = palette.dim
        foreignSizeHint.backgroundColor = CmuxTerminalBackgroundColor(
            colors: colors,
            configuration: ghosttyViewConfiguration
        ).color
        foreignSizeHint.drawsBackground = true
        foreignSizeHint.lineBreakMode = .byTruncatingTail
        foreignSizeHint.maximumNumberOfLines = 1
        foreignSizeHint.isHidden = true
        foreignSizeHint.wantsLayer = true
        foreignSizeHint.layer?.borderWidth = 1
        foreignSizeHint.layer?.borderColor = palette.border.cgColor
        foreignSizeHint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(foreignSizeHint)
        NSLayoutConstraint.activate([
            foreignSizeHint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            foreignSizeHint.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            foreignSizeHint.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -5),
        ])
    }

    private func updateSharedGrid(_ grid: CmuxSurfaceSize) {
        sharedGrid = grid
        updateForeignSizeHint()
    }

    private func layoutTerminalGrid() {
        guard let terminalView else { return }
        guard let mirrorGrid,
              let metrics = lastGridMetrics,
              let frame = terminalFrame(for: mirrorGrid, metrics: metrics)
        else {
            terminalView.frame = view.bounds
            return
        }

        guard terminalView.frame != frame else { return }
        terminalView.frame = frame
    }

    private func sizeMirror(for grid: CmuxSurfaceSize) {
        guard let terminalView,
              let metrics = lastGridMetrics,
              let frame = terminalFrame(for: grid, metrics: metrics)
        else { return }

        mirrorGrid = grid
        terminalView.setFrameOrigin(frame.origin)
        terminalView.setFrameSize(frame.size)
    }

    private func terminalFrame(
        for grid: CmuxSurfaceSize,
        metrics: TerminalGridMetrics
    ) -> NSRect? {
        guard let geometry = CmuxTerminalGridGeometry(
            containerWidthPoints: view.bounds.width,
            containerHeightPoints: view.bounds.height,
            backingScale: backingScale,
            grid: grid,
            currentGrid: CmuxSurfaceSize(cols: metrics.columns, rows: metrics.rows),
            currentWidthPixels: metrics.widthPixels,
            currentHeightPixels: metrics.heightPixels,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels
        ) else { return nil }

        let frame = NSRect(
            x: view.bounds.minX + CGFloat(geometry.gridFrame.x),
            y: view.bounds.maxY - CGFloat(geometry.gridFrame.y) - CGFloat(geometry.gridFrame.height),
            width: CGFloat(geometry.gridFrame.width),
            height: CGFloat(geometry.gridFrame.height)
        )
        return frame
    }

    private func updateForeignSizeHint() {
        guard let sharedGrid,
              let lastMeasurement,
              let localCapacity = resizePolicy.grid(for: lastMeasurement),
              sharedGrid.cols < localCapacity.cols || sharedGrid.rows < localCapacity.rows
        else {
            foreignSizeHint.isHidden = true
            return
        }

        foreignSizeHint.stringValue = String(
            format: String(
                localized: "terminal.foreign_size_hint",
                defaultValue: "sized by another client (%1$lldx%2$lld), type to take over",
                bundle: .module
            ),
            Int64(sharedGrid.cols),
            Int64(sharedGrid.rows)
        )
        foreignSizeHint.isHidden = false
    }

    private func updateTerminalBackground() {
        let background = CmuxTerminalBackgroundColor(
            colors: colors,
            configuration: ghosttyViewConfiguration
        ).color
        view.layer?.backgroundColor = background.cgColor
        foreignSizeHint.backgroundColor = background
    }

    private func containerDidLayout() {
        layoutTerminalGrid()
        if let lastGridMetrics {
            updateTerminalMeasurement(using: lastGridMetrics)
        }
        verifyRenderingMetrics()
    }

    private func containerBackingPropertiesDidChange() {
        layoutTerminalGrid()
        if let lastGridMetrics {
            updateTerminalMeasurement(using: lastGridMetrics)
        }
        verifyRenderingMetrics()
    }

    private var backingScale: Double {
        Double(view.window?.backingScaleFactor ?? view.window?.screen?.backingScaleFactor ?? 2)
    }

    private func verifyRenderingMetrics() {
        guard let terminalView,
              terminalView.bounds.width > 0,
              terminalView.bounds.height > 0,
              let layer = terminalView.layer
        else { return }

        let scale = backingScale
        let expectedDrawable = CGSize(
            width: terminalView.bounds.width * CGFloat(scale),
            height: terminalView.bounds.height * CGFloat(scale)
        )
        let scaleMatches = abs(layer.contentsScale - CGFloat(scale)) < 0.01
        assert(scaleMatches, "terminal layer contentsScale must match the window backing scale")

        let actualDrawable: CGSize?
        let drawableMatches: Bool
        if let metalLayer = layer as? CAMetalLayer {
            actualDrawable = metalLayer.drawableSize
            drawableMatches = abs(metalLayer.drawableSize.width - expectedDrawable.width) < 0.5
                && abs(metalLayer.drawableSize.height - expectedDrawable.height) < 0.5
            assert(drawableMatches, "terminal drawable must match bounds multiplied by backing scale")
        } else {
            actualDrawable = nil
            drawableMatches = true
        }

        guard ProcessInfo.processInfo.environment["CMUX_LITE_RENDER_DIAGNOSTICS"] == "1" else {
            return
        }
        let grid = sharedGrid.map { "\($0.cols)x\($0.rows)" } ?? "pending"
        let drawable = actualDrawable.map {
            String(format: "%.0fx%.0f", $0.width, $0.height)
        } ?? "iosurface"
        let diagnostic = String(
            format: "cmux-lite render scale=%.2f layerScale=%.2f expectedDrawable=%.0fx%.0f actualDrawable=%@ grid=%@ frame=%.2fx%.2f scaleOK=%@ drawableOK=%@\n",
            scale,
            layer.contentsScale,
            Double(expectedDrawable.width),
            Double(expectedDrawable.height),
            drawable,
            grid,
            Double(terminalView.frame.width),
            Double(terminalView.frame.height),
            scaleMatches.description,
            drawableMatches.description
        )
        guard diagnostic != lastRenderingDiagnostic else { return }
        lastRenderingDiagnostic = diagnostic
        FileHandle.standardError.write(Data(diagnostic.utf8))
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
