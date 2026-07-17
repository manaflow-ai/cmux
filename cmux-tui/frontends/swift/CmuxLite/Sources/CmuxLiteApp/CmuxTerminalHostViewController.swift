import AppKit
import CmuxLiteCore

@MainActor
final class CmuxTerminalHostViewController: NSViewController {
    private let frontend: CmuxFrontendSession
    private let ghosttyViewConfiguration: CmuxGhosttyViewConfiguration
    private let renderView: CmuxRenderView
    private let backToLiveButton = NSButton()

    private var model: CmuxRenderModel?
    private var attachedSurface: UInt64?
    private var active = false
    private var lastMeasurement: CmuxTerminalMeasurement?
    private var history = CmuxScrollbackWindow(total: 0)
    private var historyActive = false
    private var historyOffset = 0
    private var historyLoading = false
    private var historyGeneration = 0
    private var historyTask: Task<Void, Never>?

    init(
        frontend: CmuxFrontendSession,
        ghosttyViewConfiguration: CmuxGhosttyViewConfiguration
    ) {
        self.frontend = frontend
        self.ghosttyViewConfiguration = ghosttyViewConfiguration
        renderView = CmuxRenderView(configuration: ghosttyViewConfiguration)
        super.init(nibName: nil, bundle: nil)
        renderView.onInput = { [weak self] action in self?.send(action) }
        renderView.onPaste = { [weak self] text in self?.sendPaste(text) }
        renderView.onScrollRows = { [weak self] rows in self?.scroll(rows: rows) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let container = CmuxTerminalGridContainerView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.onLayout = { [weak self] in self?.containerDidLayout() }
        container.onBackingPropertiesChanged = { [weak self] in self?.containerDidLayout() }
        view = container

        renderView.autoresizingMask = []
        container.addSubview(renderView)
        configureBackToLiveButton()
        updateBackground()
        CmuxStateDump.register(self)
    }

    func consume(_ event: CmuxAttachEvent) {
        loadViewIfNeeded()
        switch event {
        case let .renderState(snapshot):
            attachedSurface = snapshot.surface
            model = CmuxRenderModel.applySnapshot(snapshot)
            resetHistory(total: snapshot.scrollbackRows)
            if let model { renderView.update(model: model) }
            updateBackground()
            layoutRenderGrid()
            containerDidLayout()
        case let .renderDelta(delta):
            guard attachedSurface == delta.surface, let previous = model else { return }
            let next = previous.applyDelta(delta)
            model = next
            reconcileHistory(
                previousTotal: previous.scrollbackRows,
                nextTotal: next.scrollbackRows,
                resized: delta.size != nil
            )
            if historyActive {
                renderView.updateHistory(rows: history.rows, offset: historyOffset)
            } else {
                renderView.update(model: next)
            }
            updateBackground()
            if delta.size != nil {
                layoutRenderGrid()
            }
        case let .detached(surface):
            guard attachedSurface == surface else { return }
            historyTask?.cancel()
        case .other:
            break
        }
    }

    func setActive(_ active: Bool) {
        self.active = active
        renderView.setPaneActive(active)
        if active { focusTerminal() }
    }

    func focusTerminal() {
        guard let window = view.window else { return }
        window.makeFirstResponder(renderView)
    }

    /// Returns an exact model snapshot for the SIGUSR1 verification harness.
    func verificationState() -> [String: Any]? {
        guard let model else { return nil }
        return [
            "surface": model.surface,
            "cols": model.size.cols,
            "rows": model.size.rows,
            "text": model.text,
            "cursor": [
                "x": model.cursor.x,
                "y": model.cursor.y,
            ],
        ]
    }

    private func configureBackToLiveButton() {
        backToLiveButton.title = String(
            localized: "terminal.back_to_live",
            defaultValue: "Back to live",
            bundle: .module
        )
        backToLiveButton.target = self
        backToLiveButton.action = #selector(backToLivePressed(_:))
        backToLiveButton.bezelStyle = .rounded
        backToLiveButton.controlSize = .small
        backToLiveButton.wantsLayer = true
        backToLiveButton.isHidden = true
        view.addSubview(backToLiveButton, positioned: .above, relativeTo: renderView)
    }

    private func containerDidLayout() {
        layoutRenderGrid()
        layoutOverlayControls()
        guard let attachedSurface,
              model != nil,
              let measurement = terminalMeasurement(),
              measurement != lastMeasurement
        else { return }
        lastMeasurement = measurement
        let frontend = frontend
        Task {
            await frontend.scheduleResize(for: measurement, surface: attachedSurface)
        }
    }

    private func layoutRenderGrid() {
        guard let model else {
            renderView.frame = view.bounds
            return
        }
        let scale = backingScale
        guard let geometry = CmuxTerminalGridGeometry(
            containerWidthPoints: view.bounds.width,
            containerHeightPoints: view.bounds.height,
            backingScale: Double(scale),
            grid: model.size,
            cellWidthPixels: renderView.metrics.cellWidthPixels(backingScale: scale),
            cellHeightPixels: renderView.metrics.cellHeightPixels(backingScale: scale)
        ) else { return }
        renderView.frame = NSRect(
            x: view.bounds.minX,
            y: view.bounds.maxY - CGFloat(geometry.gridFrame.height),
            width: CGFloat(geometry.gridFrame.width),
            height: CGFloat(geometry.gridFrame.height)
        )
        renderView.needsDisplay = true
    }

    private func layoutOverlayControls() {
        if !backToLiveButton.isHidden {
            let fitting = backToLiveButton.fittingSize
            let size = NSSize(
                width: max(96, fitting.width + 12),
                height: max(24, fitting.height + 4)
            )
            backToLiveButton.frame = NSRect(
                x: max(4, view.bounds.maxX - size.width - 8),
                y: 8,
                width: size.width,
                height: size.height
            )
        }
    }

    private func terminalMeasurement() -> CmuxTerminalMeasurement? {
        let scale = backingScale
        let backingBounds = view.convertToBacking(view.bounds)
        guard backingBounds.width > 0, backingBounds.height > 0 else { return nil }
        return CmuxTerminalMeasurement(
            widthPixels: backingBounds.width,
            heightPixels: backingBounds.height,
            cellWidthPixels: renderView.metrics.cellWidthPixels(backingScale: scale),
            cellHeightPixels: renderView.metrics.cellHeightPixels(backingScale: scale)
        )
    }

    private func updateBackground() {
        let color = CmuxRenderColor(model?.defaultBackground)?.color
            ?? CmuxRenderColor(ghosttyViewConfiguration.background)?.color
            ?? .black
        view.layer?.backgroundColor = color.cgColor
    }

    private func send(_ action: CmuxTerminalKeyAction) {
        returnToLive()
        guard let attachedSurface else { return }
        let frontend = frontend
        Task {
            switch action {
            case let .text(text):
                try? await frontend.sendText(text, surface: attachedSurface)
            case let .key(key):
                try? await frontend.sendKey(key, surface: attachedSurface)
            }
        }
    }

    private func sendPaste(_ text: String) {
        returnToLive()
        guard let attachedSurface else { return }
        let frontend = frontend
        Task {
            try? await frontend.sendText(text, surface: attachedSurface, paste: true)
        }
    }

    private func scroll(rows: Int) {
        guard rows != 0, let model else { return }
        if !historyActive {
            guard rows > 0, model.scrollbackRows > 0 else { return }
            historyActive = true
            backToLiveButton.isHidden = false
            if history.rows.isEmpty {
                loadHistory(history.latestRequest, direction: nil)
            } else {
                historyOffset = max(0, history.rows.count - renderView.visibleRowCount)
                renderView.updateHistory(rows: history.rows, offset: historyOffset)
            }
            layoutOverlayControls()
            return
        }

        let maximum = max(0, history.rows.count - renderView.visibleRowCount)
        historyOffset = max(0, min(maximum, historyOffset - rows))
        renderView.updateHistory(rows: history.rows, offset: historyOffset)
        if historyOffset <= 2, rows > 0 {
            loadHistory(history.previousRequest, direction: .previous)
        } else if historyOffset >= max(0, maximum - 2), rows < 0 {
            loadHistory(history.nextRequest, direction: .next)
        }
    }

    private func loadHistory(
        _ request: CmuxScrollbackRequest?,
        direction: CmuxScrollbackDirection?
    ) {
        guard historyActive, !historyLoading, let request, let attachedSurface else { return }
        historyLoading = true
        let generation = historyGeneration
        let requestTotal = history.total
        let frontend = frontend
        historyTask = Task { [weak self] in
            do {
                var page = try await frontend.readScrollback(request, surface: attachedSurface)
                guard let self, self.historyActive, self.historyGeneration == generation else { return }
                if page.total < self.history.total, self.history.total > requestTotal {
                    page = CmuxReadScrollbackResponse(
                        rows: page.rows,
                        start: page.start,
                        total: self.history.total
                    )
                }
                let previous = self.history
                let merged = previous.merging(page)
                switch direction {
                case .previous:
                    self.historyOffset += previous.anchorDelta(to: merged, direction: .previous)
                case .next:
                    self.historyOffset += previous.anchorDelta(to: merged, direction: .next)
                        + Int(request.count)
                case nil:
                    self.historyOffset = max(0, merged.rows.count - self.renderView.visibleRowCount)
                }
                self.history = merged
                let maximum = max(0, merged.rows.count - self.renderView.visibleRowCount)
                self.historyOffset = max(0, min(maximum, self.historyOffset))
                self.renderView.updateHistory(rows: merged.rows, offset: self.historyOffset)
            } catch {
                if let self, self.historyGeneration == generation {
                    self.historyLoading = false
                }
                return
            }
            self?.historyLoading = false
        }
    }

    private func reconcileHistory(previousTotal: UInt32, nextTotal: UInt32, resized: Bool) {
        let reconciliation = history.reconciling(
            previousTotal: previousTotal,
            nextTotal: nextTotal,
            resized: resized
        )
        history = reconciliation.window
        guard reconciliation.invalidated else { return }
        historyGeneration &+= 1
        historyTask?.cancel()
        historyTask = nil
        historyLoading = false
        historyOffset = 0
        if historyActive { loadHistory(history.latestRequest, direction: nil) }
    }

    private func resetHistory(total: UInt32) {
        historyGeneration &+= 1
        historyTask?.cancel()
        historyTask = nil
        historyLoading = false
        history = CmuxScrollbackWindow(total: total)
        historyActive = false
        historyOffset = 0
        backToLiveButton.isHidden = true
        renderView.returnToLive()
    }

    private func returnToLive() {
        guard historyActive else { return }
        historyActive = false
        historyTask?.cancel()
        historyTask = nil
        historyLoading = false
        backToLiveButton.isHidden = true
        if let model { renderView.update(model: model) }
    }

    @objc
    private func backToLivePressed(_: NSButton) {
        returnToLive()
        focusTerminal()
    }

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? view.window?.screen?.backingScaleFactor ?? 2
    }
}
