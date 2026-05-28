import SwiftUI
import SwiftTerm
import UIKit
import CmuxKit

/// SwiftUI wrapper around SwiftTerm's UIKit `TerminalView`.
///
/// The wrapper has three responsibilities:
///   1. Feed initial scrollback + periodic snapshots from `cmux read-screen`
///      into the emulator. cmux does not currently expose a streaming PTY
///      tail, so the refresh cadence is driven by surface/pane events from
///      the live event stream plus a foreground idle poll.
///   2. Forward user-typed bytes into `cmux send` and special keys into
///      `cmux send-key`.
///   3. Resize the remote surface to match the iOS terminal view's cell
///      dimensions on geometry changes.
struct TerminalSurfaceView: UIViewControllerRepresentable {
    let surface: CmuxSurface
    let workspace: CmuxWorkspace?
    let isActive: Bool

    func makeUIViewController(context: Context) -> TerminalSurfaceViewController {
        let controller = TerminalSurfaceViewController(surface: surface, workspace: workspace)
        controller.setPollingActive(isActive)
        return controller
    }

    func updateUIViewController(_ controller: TerminalSurfaceViewController, context: Context) {
        controller.surface = surface
        controller.workspace = workspace
        controller.setPollingActive(isActive)
        controller.refreshIfNeeded()
    }
}

final class TerminalSurfaceViewController: UIViewController, @preconcurrency TerminalViewDelegate {
    var surface: CmuxSurface
    var workspace: CmuxWorkspace?

    private let terminal = TerminalView()
    private let modifiers = TerminalModifierState()
    private var accessoryHost: TerminalAccessoryHost?
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: Date = .distantPast
    private var lastRenderedScreen: String = ""
    private var isPollingActive = false
    private let log = CmuxLog.make("terminal.surface")

    init(surface: CmuxSurface, workspace: CmuxWorkspace?) {
        self.surface = surface
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = terminal
        terminal.terminalDelegate = self
        terminal.optionAsMetaKey = true
        try? terminal.setUseMetal(true)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        // Suppress iOS smart-* substitutions that otherwise replace
        // straight quotes with curly quotes, break Markdown-style dashes,
        // etc. — all of which would corrupt shell input.
        terminal.autocorrectionType = .no
        terminal.autocapitalizationType = .none
        terminal.smartQuotesType = .no
        terminal.smartDashesType = .no
        terminal.smartInsertDeleteType = .no
        terminal.spellCheckingType = .no
        installAccessoryBar()
        _ = terminal.becomeFirstResponder()
    }

    private func installAccessoryBar() {
        let host = TerminalAccessoryHost(
            terminalContainer: terminal,
            modifiers: modifiers,
            onKey: { [weak self] key in self?.handleAccessory(key: key) },
            onSpecialCharacter: { [weak self] ch in self?.sendCharacter(ch) },
            onPasteRequest: { [weak self] in self?.handlePaste() },
            onDismissKeyboard: { [weak self] in _ = self?.terminal.resignFirstResponder() }
        )
        accessoryHost = host
        terminal.inputAccessoryView = host.inputAccessoryView
    }

    private func handleAccessory(key: AccessoryKey) {
        switch key {
        case .named(let name):
            forwardKey(name: name)
        case .raw(let bytes):
            forwardText(bytes)
        }
        modifiers.consume()
    }

    private func sendCharacter(_ ch: String) {
        let payload: String
        if let first = ch.first {
            payload = ModifierEncoder.encode(
                character: first,
                ctrl: modifiers.ctrl != .off,
                alt: modifiers.alt != .off
            )
        } else {
            payload = ch
        }
        forwardText(payload)
        modifiers.consume()
    }

    private func handlePaste() {
        guard let raw = UIPasteboard.general.string else { return }
        let sanitised = SmartPasteSanitiser.sanitise(raw)
        if sanitised.isMultiLine || sanitised.cleaned.count > 4096 {
            let alert = UIAlertController(
                title: L10n.format(
                    "terminal.paste.multiline.title",
                    defaultValue: "Paste %lld lines?",
                    Int64(sanitised.cleaned.split(separator: "\n").count)
                ),
                message: paste_preview(sanitised.cleaned),
                preferredStyle: .actionSheet
            )
            alert.addAction(UIAlertAction(title: L10n.string("terminal.paste.action.paste", defaultValue: "Paste"), style: .default) { [weak self] _ in
                self?.forwardText(sanitised.cleaned)
            })
            alert.addAction(UIAlertAction(title: L10n.string("terminal.paste.action.single_line", defaultValue: "Paste as single line"), style: .default) { [weak self] _ in
                let collapsed = sanitised.cleaned.replacingOccurrences(of: "\n", with: " ")
                self?.forwardText(collapsed)
            })
            alert.addAction(UIAlertAction(title: L10n.string("common.cancel", defaultValue: "Cancel"), style: .cancel))
            if let popover = alert.popoverPresentationController {
                popover.sourceView = terminal
                popover.sourceRect = CGRect(
                    x: terminal.bounds.midX,
                    y: terminal.bounds.maxY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = [.down, .up]
            }
            present(alert, animated: true)
            return
        }
        forwardText(sanitised.cleaned)
    }

    private func paste_preview(_ text: String) -> String {
        let lines = text.split(separator: "\n").prefix(6)
            .map { String($0) }
        let truncated = lines.joined(separator: "\n")
        return text.count > truncated.count ? truncated + "\n…" : truncated
    }

    private func forwardKey(name: String) {
        Task { [surface, workspace] in
            guard let client = await ConnectionManager.shared.client(for: "send-key") else { return }
            try? await client.sendKey(name, surfaceID: surface.id, workspaceID: workspace?.id)
        }
    }

    private func forwardText(_ text: String) {
        Task { [surface, workspace] in
            guard let client = await ConnectionManager.shared.client(for: "send") else { return }
            try? await client.sendText(text, surfaceID: surface.id, workspaceID: workspace?.id)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshIfNeeded()
        if isPollingActive { scheduleIdlePoll() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopIdlePoll()
    }

    func setPollingActive(_ active: Bool) {
        guard isPollingActive != active else { return }
        isPollingActive = active
        if active {
            refreshIfNeeded()
            if isViewLoaded, view.window != nil {
                scheduleIdlePoll()
            }
        } else {
            stopIdlePoll()
        }
    }

    func refreshIfNeeded() {
        guard canRefresh else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) > 0.25 else { return }
        lastRefresh = now
        Task { [weak self] in
            await self?.refresh()
        }
    }

    private func scheduleIdlePoll() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard self.canRefresh else { continue }
                await self.refresh()
            }
        }
    }

    private func stopIdlePoll() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    @MainActor
    private var canRefresh: Bool {
        isPollingActive && isViewLoaded && view.window != nil
    }

    private func refresh() async {
        guard canRefresh else { return }
        guard let client = await ConnectionManager.shared.client(for: "read-screen") else { return }
        do {
            let screen = try await client.readScreen(
                surfaceID: surface.id,
                workspaceID: workspace?.id,
                includeScrollback: false
            )
            if screen != lastRenderedScreen {
                let delta = computeDelta(previous: lastRenderedScreen, current: screen)
                lastRenderedScreen = screen
                await MainActor.run {
                    terminal.getTerminal().feed(text: delta)
                }
            }
        } catch {
            log.warning("read-screen failed: \(error.localizedDescription)")
        }
    }

    /// Naïve delta: if the previous snapshot is a prefix of the new screen we
    /// only feed the suffix; otherwise we clear + replay. cmux's
    /// `read-screen` returns the full visible viewport, so this avoids
    /// re-rendering identical scrollback every poll.
    private func computeDelta(previous: String, current: String) -> String {
        if previous.isEmpty {
            return current
        }
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        // Snapshot differs structurally — clear the screen and repaint.
        let clear = "\u{001B}[2J\u{001B}[H"
        return clear + current
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        // If a sticky Ctrl or Alt is armed/locked, apply it to the bytes
        // SwiftTerm just produced before forwarding.
        let ctrl = modifiers.ctrl != .off
        let alt = modifiers.alt != .off

        if bytes.count == 1, let mapped = Self.singleByteKeyName(bytes[0]) {
            forwardKey(name: mapped)
            // Return auto-releases armed modifiers but never the lock.
            if mapped == "enter" { modifiers.consume() }
            return
        }

        if (ctrl || alt), bytes.count == 1 {
            let scalar = UnicodeScalar(bytes[0])
            let encoded = ModifierEncoder.encode(character: Character(scalar), ctrl: ctrl, alt: alt)
            forwardText(encoded)
            modifiers.consume()
            return
        }

        if let text = String(bytes: bytes, encoding: .utf8) {
            forwardText(text)
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // PTY resize is mediated by cmux's `tmux-compat resize-pane` or v2
        // `surface.resize`; we forward best-effort and let cmux clamp.
        log.debug("size changed: \(newCols)x\(newRows)")
        // No public CLI for forced resize from outside yet — cmux's PTY
        // resize coordinator picks min(cols) across all attachments. We
        // simply re-render after the next refresh.
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // No-op — the surface title shown in the chip strip is authoritative.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // No-op — workspace.cwd from the snapshot is authoritative.
    }

    func scrolled(source: TerminalView, position: Double) {}

    func bell(source: TerminalView) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = s
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    private static func singleByteKeyName(_ byte: UInt8) -> String? {
        switch byte {
        case 0x03: return "ctrl-c"
        case 0x04: return "ctrl-d"
        case 0x0D: return "enter"
        case 0x08, 0x7F: return "backspace"
        case 0x09: return "tab"
        case 0x1B: return "escape"
        default: return nil
        }
    }
}
